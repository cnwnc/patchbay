defmodule Patchbay.AgentRunnerTest.Provider do
  @behaviour Patchbay.Provider

  alias Patchbay.Provider.{Error, Response}

  def start_link(responses) do
    Agent.start_link(fn -> %{responses: responses, requests: []} end)
  end

  def push(pid, %Response{} = response) do
    Agent.update(pid, &%{&1 | responses: &1.responses ++ [response]})
  end

  def requests(pid) do
    Agent.get(pid, &Enum.reverse(&1.requests))
  end

  @impl true
  def complete(request, opts) do
    fake = Keyword.fetch!(opts, :fake)

    Agent.get_and_update(fake, fn state ->
      state = %{state | requests: [request | state.requests]}

      case state.responses do
        [response | rest] ->
          {response, %{state | responses: rest}}

        [] ->
          {{:error, Error.new(:config, "fake provider has no scripted response")}, state}
      end
    end)
  end
end

defmodule Patchbay.AgentRunnerTest.StreamingProvider do
  @behaviour Patchbay.Provider

  alias Patchbay.AgentRunnerTest.Provider
  alias Patchbay.Provider.{Error, Response, StreamEvent}

  @impl true
  def complete(request, opts), do: Provider.complete(request, opts)

  @impl true
  def stream(request, on_event, opts) do
    case Provider.complete(request, opts) do
      {:ok, %Response{content: content} = response} ->
        content
        |> to_string()
        |> String.graphemes()
        |> Enum.reduce_while(:ok, fn grapheme, :ok ->
          case on_event.(%StreamEvent{type: :text_delta, text: grapheme}) do
            :ok -> {:cont, :ok}
            :halt -> {:halt, :halt}
            {:halt, reason} -> {:halt, {:halt, reason}}
            _other -> {:cont, :ok}
          end
        end)
        |> case do
          :ok ->
            _ = on_event.(%StreamEvent{type: :finish, finish_reason: response.finish_reason})
            {:ok, response}

          :halt ->
            {:error, Error.new(:cancelled, "stream cancelled")}

          {:halt, reason} ->
            {:error, Error.new(:cancelled, "stream cancelled", details: %{reason: reason})}
        end

      other ->
        other
    end
  end
end

defmodule Patchbay.AgentRunnerTest.BlockingProvider do
  @behaviour Patchbay.Provider

  alias Patchbay.AgentRunnerTest.Provider

  @impl true
  def complete(request, opts) do
    if summary_request?(request) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:summary_requested, self()})

      receive do
        :release -> Provider.complete(request, opts)
      end
    else
      Provider.complete(request, opts)
    end
  end

  defp summary_request?(%{messages: messages}) when is_list(messages) do
    Enum.any?(messages, fn
      %{role: :system, content: content} when is_binary(content) ->
        String.contains?(content, "compact conversation context")

      _message ->
        false
    end)
  end

  defp summary_request?(_request), do: false
end

defmodule Patchbay.AgentRunnerTest.Manager do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def calls(pid), do: GenServer.call(pid, :calls)

  def set_execute(pid, fun), do: GenServer.call(pid, {:set_execute, fun})
  def set_stop(pid, result), do: GenServer.call(pid, {:set_stop, result})

  @impl true
  def init(_opts) do
    {:ok, %{calls: [], execute_fun: nil, stop_result: {:ok, %{status: :stopping}}}}
  end

  @impl true
  def handle_call(:calls, _from, state), do: {:reply, Enum.reverse(state.calls), state}

  def handle_call({:set_execute, fun}, _from, state) when is_function(fun, 2) do
    {:reply, :ok, %{state | execute_fun: fun}}
  end

  def handle_call({:set_stop, result}, _from, state) do
    {:reply, :ok, %{state | stop_result: result}}
  end

  def handle_call({:start_worker, worker_id, opts}, _from, state) do
    {:reply, {:ok, %{worker_id: worker_id, status: :starting}},
     record(state, {:start_worker, worker_id, opts})}
  end

  def handle_call({:await_worker, worker_id, timeout}, _from, state) do
    {:reply, {:ok, %{status: :ready}}, record(state, {:await_worker, worker_id, timeout})}
  end

  def handle_call({:execute, worker_id, operation, arguments, timeout}, _from, state) do
    result =
      case state.execute_fun do
        fun when is_function(fun, 2) ->
          fun.(operation, arguments)

        nil ->
          {:ok, %{status: :ok, output: "echo:" <> Map.get(arguments, "text", ""), exit_status: 0}}
      end

    {:reply, result, record(state, {:execute, worker_id, operation, arguments, timeout})}
  end

  def handle_call({:stop_worker, worker_id, timeout}, _from, state) do
    {:reply, state.stop_result, record(state, {:stop_worker, worker_id, timeout})}
  end

  def handle_call({:transcript_path, worker_id}, _from, state) do
    {:reply, Path.join(System.tmp_dir!(), worker_id <> ".pbt"),
     record(state, {:transcript_path, worker_id})}
  end

  defp record(state, call), do: %{state | calls: [call | state.calls]}
end

defmodule Patchbay.AgentRunnerTest.WorkerClient do
  @behaviour Patchbay.Runtime.WorkerClient

  @impl true
  def start_worker(server, worker_id, opts),
    do: GenServer.call(server, {:start_worker, worker_id, opts})

  @impl true
  def await_worker(server, worker_id, timeout),
    do: GenServer.call(server, {:await_worker, worker_id, timeout})

  @impl true
  def execute(server, worker_id, operation, arguments, timeout),
    do: GenServer.call(server, {:execute, worker_id, operation, arguments, timeout})

  @impl true
  def stop_worker(server, worker_id, timeout),
    do: GenServer.call(server, {:stop_worker, worker_id, timeout})

  @impl true
  def transcript_path(server, worker_id),
    do: GenServer.call(server, {:transcript_path, worker_id})
end

defmodule Patchbay.AgentRunnerTest do
  use ExUnit.Case, async: false

  alias Patchbay.AgentRunnerTest.{
    BlockingProvider,
    Manager,
    Provider,
    StreamingProvider,
    WorkerClient
  }

  alias Patchbay.ContextStore
  alias Patchbay.Definition
  alias Patchbay.Definition.Prompt
  alias Patchbay.Lifecycle
  alias Patchbay.Provider.{Error, Message, Response, ToolCall}
  alias Patchbay.Runtime

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "patchbay-agent-runner-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    stub = start_supervised!({Manager, []})

    %{tmp: tmp, stub: stub}
  end

  test "a model turn executes a fixed tool and completes with validated results", context do
    definition = definition()

    fake =
      start_fake(context, [
        response("I will look.", [tool_call("call-1", "echo", %{"text" => "hi"})]),
        response(nil, [tool_call("call-2", "complete_task", %{"results" => %{"summary" => "ok"}})])
      ])

    runtime = start_runtime(context, definition, fake)

    assert {:ok, running} = Runtime.start_agent(runtime, "alpha")
    assert running.status == :running
    assert running.activity == :thinking

    assert eventually(fn -> completed?(runtime, "alpha") end)

    assert {:ok, agent} = Runtime.get_agent(runtime, "alpha")
    assert agent.status == :stopped
    assert agent.run_status == :completed
    assert agent.result == %{"summary" => "ok"}
    assert agent.activity == :idle

    assert {:ok, events} = Runtime.list_events(runtime, "alpha")
    types = Enum.map(events, & &1.type)

    assert :model_message in types
    assert :model_tool_call in types
    assert :tool_call in types
    assert :tool_result in types
    assert :run_completed in types
    assert Enum.count(events, &(&1.type == :model_tool_call)) == 2

    tool_calls = Manager.calls(context.stub)

    assert Enum.any?(
             tool_calls,
             &match?({:execute, "agent.alpha", "echo", %{"text" => "hi"}, _}, &1)
           )

    assert {:ok, [record]} = Runtime.tool_history(runtime, "alpha")
    assert record.tool_name == "echo"
    assert record.truncated_result == "echo:hi"

    assert {:ok, messages} = Runtime.messages(runtime, "alpha")
    assert Enum.any?(messages, &(&1.role == :system and &1.content =~ "test agent"))
    assert Enum.any?(messages, &(&1.role == :tool and &1.content == "echo:hi"))
    assert Enum.any?(messages, &(&1.role == :assistant and &1.content == "I will look."))

    requests = Provider.requests(fake)
    assert length(requests) == 2
    tool_names = Enum.map(hd(requests).tools, & &1.name)
    assert "echo" in tool_names
    assert "complete_task" in tool_names
    assert "fail_task" in tool_names

    second = Enum.at(requests, 1)
    assert Enum.any?(second.messages, &(&1.role == :tool and &1.tool_call_id == "call-1"))
    assert Enum.any?(second.messages, &(&1.role == :assistant and length(&1.tool_calls) == 1))
  end

  test "records an in-flight tool outcome before dispatching a tool", context do
    definition = definition()
    state_dir = Path.join(context.tmp, "state")
    parent = self()

    Manager.set_execute(context.stub, fn _operation, _arguments ->
      send(parent, {:before_execute, ContextStore.read(state_dir, "alpha")})

      {:ok, %{status: :ok, output: "echo:hi", exit_status: 0}}
    end)

    fake =
      start_fake(context, [
        response(nil, [tool_call("call-1", "echo", %{"text" => "hi"})]),
        response(nil, [tool_call("call-2", "complete_task", %{"results" => %{"summary" => "ok"}})])
      ])

    runtime = start_runtime(context, definition, fake)
    assert {:ok, _running} = Runtime.start_agent(runtime, "alpha")
    assert eventually(fn -> completed?(runtime, "alpha") end)

    assert_receive {:before_execute, {:ok, entries}}, 2_000
    before_messages = for {:message, %{message: message}} <- entries, do: message

    assert Enum.any?(
             before_messages,
             &(&1.role == :tool and &1.tool_call_id == "call-1" and
                 &1.content =~ "in_flight" and &1.content =~ "unknown")
           )

    assert {:ok, entries} = ContextStore.read(state_dir, "alpha")
    messages = for {:message, %{message: message}} <- entries, do: message
    sanitized = ContextStore.sanitize(messages)

    results =
      Enum.filter(sanitized, &(&1.role == :tool and &1.tool_call_id == "call-1"))

    assert [%Message{content: "echo:hi"}] = results

    assert {:ok, live_messages} = Runtime.messages(runtime, "alpha")

    assert Enum.count(live_messages, &(&1.role == :tool and &1.tool_call_id == "call-1")) == 1
  end

  test "an interrupted in-flight tool keeps an unknown outcome across a runtime restart",
       context do
    definition = definition(context: ~s(restore-interrupted = "checkpoint"))
    state_dir = Path.join(context.tmp, "state")

    first =
      start_fake(context, [
        response(nil, [
          tool_call("call-1", "echo", %{"text" => "danger"}),
          tool_call("call-2", "echo", %{"text" => "also-danger"})
        ])
      ])

    runtime = start_runtime(context, definition, first)
    Process.unlink(runtime)
    runtime_monitor = Process.monitor(runtime)

    Manager.set_execute(context.stub, fn _operation, _arguments ->
      Process.exit(runtime, :kill)
      {:ok, %{status: :ok, output: "ran", exit_status: 0}}
    end)

    assert {:ok, _running} = Runtime.start_agent(runtime, "alpha")
    assert_receive {:DOWN, ^runtime_monitor, :process, ^runtime, _reason}, 2_000

    assert {:ok, entries} = ContextStore.read(state_dir, "alpha")
    messages = for {:message, %{message: message}} <- entries, do: message

    for id <- ["call-1", "call-2"] do
      assert Enum.any?(
               messages,
               &(&1.role == :tool and &1.tool_call_id == id and &1.content =~ "in_flight")
             )
    end

    assert length(ContextStore.sanitize(messages)) == 3

    second =
      start_fake(context, [
        response(nil, [tool_call("call-3", "complete_task", %{"results" => %{"summary" => "ok"}})])
      ])

    restarted = start_runtime(context, definition, second)
    assert {:ok, _running} = Runtime.start_agent(restarted, "alpha")
    assert eventually(fn -> completed?(restarted, "alpha") end)

    request = hd(Provider.requests(second))

    for id <- ["call-1", "call-2"] do
      assert Enum.any?(
               request.messages,
               &(&1.role == :tool and &1.tool_call_id == id and &1.content =~ "in_flight")
             )
    end

    executes =
      context.stub
      |> Manager.calls()
      |> Enum.filter(&match?({:execute, _worker_id, _operation, _arguments, _timeout}, &1))

    assert length(executes) == 1
  end

  test "a failed stop leaves the runner available to continue the agent", context do
    definition = definition()

    fake =
      start_fake(context, [
        response("Waiting.", []),
        response(nil, [tool_call("call-1", "complete_task", %{"results" => %{"summary" => "ok"}})])
      ])

    runtime = start_runtime(context, definition, fake)
    assert {:ok, _running} = Runtime.start_agent(runtime, "alpha")
    assert {:ok, waiting} = Runtime.await_agent(runtime, "alpha", 2_000)
    assert waiting.activity == :waiting

    runner = runner_pid(runtime)
    Manager.set_stop(context.stub, {:error, :supervisor_unavailable})

    assert {:error, :supervisor_unavailable} = Runtime.stop_agent(runtime, "alpha")
    assert Process.alive?(runner)

    assert {:ok, running} = Runtime.get_agent(runtime, "alpha")
    assert running.status == :running
    assert running.activity == :waiting

    assert {:ok, sent} = Runtime.send_message(runtime, "alpha", "continue")
    assert sent.activity == :thinking
    assert eventually(fn -> completed?(runtime, "alpha") end)

    assert {:ok, agent} = Runtime.get_agent(runtime, "alpha")
    assert agent.run_status == :completed
  end

  test "mixed terminal tool calls are rejected before any tool executes", context do
    definition = definition()
    state_dir = Path.join(context.tmp, "state")

    fake =
      start_fake(context, [
        response(nil, [
          tool_call("call-1", "echo", %{"text" => "danger"}),
          tool_call("call-2", "complete_task", %{"results" => %{"summary" => "premature"}})
        ]),
        response(nil, [
          tool_call("call-3", "complete_task", %{"results" => %{"summary" => "done"}})
        ])
      ])

    runtime = start_runtime(context, definition, fake)
    assert {:ok, _running} = Runtime.start_agent(runtime, "alpha")
    assert eventually(fn -> completed?(runtime, "alpha") end)

    refute Enum.any?(
             Manager.calls(context.stub),
             &match?({:execute, _worker_id, _operation, _arguments, _timeout}, &1)
           )

    assert {:ok, []} = Runtime.tool_history(runtime, "alpha")

    assert {:ok, entries} = ContextStore.read(state_dir, "alpha")
    messages = for {:message, %{message: message}} <- entries, do: message
    sanitized = ContextStore.sanitize(messages)

    first_assistant =
      Enum.find(sanitized, &(&1.role == :assistant and length(&1.tool_calls) == 2))

    assert first_assistant
    call_ids = Enum.map(first_assistant.tool_calls, & &1.id)

    for id <- call_ids do
      assert Enum.any?(
               sanitized,
               &(&1.role == :tool and &1.tool_call_id == id and
                   &1.content =~ "terminal tools must be called alone")
             )
    end

    assert {:ok, agent} = Runtime.get_agent(runtime, "alpha")
    assert agent.result == %{"summary" => "done"}
  end

  test "complete_task rejects missing required results and leaves the run open", context do
    definition = definition()

    fake =
      start_fake(context, [
        response(nil, [tool_call("call-1", "complete_task", %{"results" => %{}})]),
        response(nil, [tool_call("call-2", "fail_task", %{"reason" => "no data"})])
      ])

    runtime = start_runtime(context, definition, fake)

    assert {:ok, _running} = Runtime.start_agent(runtime, "alpha")
    assert eventually(fn -> completed?(runtime, "alpha") end)

    assert {:ok, agent} = Runtime.get_agent(runtime, "alpha")
    assert agent.run_status == :failed
    assert agent.failure == "no data"
    assert agent.result == nil

    assert {:ok, events} = Runtime.list_events(runtime, "alpha")

    assert Enum.any?(events, fn event ->
             event.type == :tool_result and event.data["tool_name"] == "complete_task" and
               event.data["status"] == "error"
           end)

    assert Enum.any?(events, &(&1.type == :run_failed))

    assert {:ok, messages} = Runtime.messages(runtime, "alpha")

    assert Enum.any?(messages, fn message ->
             message.role == :tool and message.content =~ "missing_required_results"
           end)

    requests = Provider.requests(fake)
    assert length(requests) == 2
  end

  test "start_agent seeds an initial user message for the first turn", context do
    definition = definition()

    fake =
      start_fake(context, [
        response(nil, [
          tool_call("call-1", "complete_task", %{"results" => %{"summary" => "seeded"}})
        ])
      ])

    runtime = start_runtime(context, definition, fake)

    assert {:ok, running} = Runtime.start_agent(runtime, "alpha", message: "Begin")
    assert running.message_count == 2
    assert eventually(fn -> completed?(runtime, "alpha") end)

    request = hd(Provider.requests(fake))
    assert Enum.any?(request.messages, &(&1.role == :system))
    assert Enum.any?(request.messages, &(&1.role == :user and &1.content == "Begin"))

    assert {:ok, events} = Runtime.list_events(runtime, "alpha")
    assert Enum.any?(events, &(&1.type == :user_message))
  end

  test "stop_agent stops a waiting runner and cancels the run", context do
    definition = definition()
    fake = start_fake(context, [response("Waiting.", [])])

    runtime = start_runtime(context, definition, fake)

    assert {:ok, _running} = Runtime.start_agent(runtime, "alpha")
    assert {:ok, waiting} = Runtime.await_agent(runtime, "alpha", 2_000)
    assert waiting.activity == :waiting

    assert {:ok, running} = Runtime.activity(runtime, "alpha")
    assert running.activity == :waiting
    assert running.run_status == :waiting

    assert {:ok, stopped} = Runtime.stop_agent(runtime, "alpha")
    assert stopped.status == :stopped
    assert stopped.run_status == :cancelled

    assert {:error, {:not_running, :stopped}} =
             Runtime.send_message(runtime, "alpha", "too late")

    Process.sleep(100)
    assert length(Provider.requests(fake)) == 1
  end

  test "stopping the runtime terminates a waiting runner", context do
    definition = definition()
    fake = start_fake(context, [response("Waiting.", [])])

    runtime = start_runtime(context, definition, fake)

    assert {:ok, _running} = Runtime.start_agent(runtime, "alpha")
    assert {:ok, waiting} = Runtime.await_agent(runtime, "alpha", 2_000)
    assert waiting.activity == :waiting

    runner = runner_pid(runtime)
    assert Process.alive?(runner)

    assert :ok = GenServer.stop(runtime)
    assert eventually(fn -> not Process.alive?(runner) end)
  end

  test "a waiting runner exits when the runtime dies without terminating", context do
    definition = definition()
    fake = start_fake(context, [response("Waiting.", [])])

    runtime = start_runtime(context, definition, fake)

    assert {:ok, _running} = Runtime.start_agent(runtime, "alpha")
    assert {:ok, waiting} = Runtime.await_agent(runtime, "alpha", 2_000)
    assert waiting.activity == :waiting

    runner = runner_pid(runtime)
    runner_monitor = Process.monitor(runner)

    Process.unlink(runtime)
    Process.exit(runtime, :kill)

    assert_receive {:DOWN, ^runner_monitor, :process, ^runner, _reason}, 2_000
  end

  test "a missing provider configuration fails start with a clear error", context do
    definition = definition()

    {:ok, runtime} =
      Runtime.start_link(
        definitions: %{"alpha" => definition},
        state_dir: Path.join(context.tmp, "state"),
        workspace_dir: Path.join(context.tmp, "workspaces"),
        result_dir: Path.join(context.tmp, "results"),
        manager: context.stub,
        worker_client: WorkerClient,
        provider: Patchbay.Provider.OpenAI,
        provider_opts: [env: %{}, timeout: 1_000]
      )

    on_exit(fn -> if Process.alive?(runtime), do: GenServer.stop(runtime) end)

    assert {:error, {:provider_not_configured, :api_key}} =
             Runtime.start_agent(runtime, "alpha")

    assert Manager.calls(context.stub) == []

    assert {:ok, agent} = Runtime.get_agent(runtime, "alpha")
    assert agent.status == :stopped
    assert agent.message_count == 0
  end

  test "send_message wakes a waiting agent and is included in the next turn", context do
    definition = definition()

    fake =
      start_fake(context, [
        response("I need more detail.", []),
        response(nil, [
          tool_call("call-1", "complete_task", %{"results" => %{"summary" => "done"}})
        ])
      ])

    runtime = start_runtime(context, definition, fake)

    assert {:ok, _running} = Runtime.start_agent(runtime, "alpha")
    assert {:ok, waiting} = Runtime.await_agent(runtime, "alpha", 2_000)
    assert waiting.activity == :waiting
    assert waiting.run_status == :waiting

    assert {:ok, sent} = Runtime.send_message(runtime, "alpha", "More detail")
    assert sent.activity == :thinking

    assert eventually(fn -> completed?(runtime, "alpha") end)

    assert {:ok, events} = Runtime.list_events(runtime, "alpha")
    types = Enum.map(events, & &1.type)
    assert :agent_waiting in types
    assert :user_message in types
    assert :agent_woken in types
    assert :run_completed in types

    requests = Provider.requests(fake)
    assert length(requests) == 2
    second = Enum.at(requests, 1)
    assert Enum.any?(second.messages, &(&1.role == :user and &1.content == "More detail"))

    assert Enum.any?(
             second.messages,
             &(&1.role == :assistant and &1.content == "I need more detail.")
           )
  end

  test "provider errors fail the run instead of leaving it running", context do
    definition = definition()

    fake =
      start_fake(context, [
        {:error, Error.new(:transport, "network down", retryable: true)}
      ])

    runtime = start_runtime(context, definition, fake)

    assert {:ok, _running} = Runtime.start_agent(runtime, "alpha")
    assert eventually(fn -> completed?(runtime, "alpha") end)

    assert {:ok, agent} = Runtime.get_agent(runtime, "alpha")
    assert agent.run_status == :failed
    assert agent.last_error == {:provider_error, :transport, "network down"}
    assert agent.status == :stopped

    assert {:ok, events} = Runtime.list_events(runtime, "alpha")
    assert Enum.any?(events, &(&1.type == :provider_error))
    assert Enum.any?(events, &(&1.type == :run_failed))
  end

  test "send_message to an agent without a runner is rejected", context do
    definition = definition()

    {:ok, runtime} =
      Runtime.start_link(
        definitions: %{"alpha" => definition},
        state_dir: Path.join(context.tmp, "state"),
        workspace_dir: Path.join(context.tmp, "workspaces"),
        result_dir: Path.join(context.tmp, "results"),
        manager: context.stub,
        worker_client: WorkerClient
      )

    on_exit(fn -> if Process.alive?(runtime), do: GenServer.stop(runtime) end)

    assert {:ok, _running} = Runtime.start_agent(runtime, "alpha")
    assert {:error, :agent_runner_disabled} = Runtime.send_message(runtime, "alpha", "hello")
  end

  test "a restarted runtime restores a perpetual conversation", context do
    definition = definition(kind: "perpetual")
    first = start_fake(context, [response("Before restart.", [])])

    runtime = start_runtime(context, definition, first)
    assert {:ok, _running} = Runtime.start_agent(runtime, "alpha")
    assert {:ok, waiting} = Runtime.await_agent(runtime, "alpha", 2_000)
    assert waiting.activity == :waiting
    assert :ok = GenServer.stop(runtime)

    second =
      start_fake(context, [
        response(nil, [
          tool_call("call-1", "complete_task", %{"results" => %{"summary" => "ok"}})
        ])
      ])

    restarted = start_runtime(context, definition, second)
    assert {:ok, _running} = Runtime.start_agent(restarted, "alpha")
    assert eventually(fn -> completed?(restarted, "alpha") end)

    request = hd(Provider.requests(second))

    assert Enum.any?(
             request.messages,
             &(&1.role == :assistant and &1.content == "Before restart.")
           )
  end

  test "a restarted one-shot runtime starts without prior messages by default", context do
    definition = definition()
    first = start_fake(context, [response("Old conversation.", [])])

    runtime = start_runtime(context, definition, first)
    assert {:ok, _running} = Runtime.start_agent(runtime, "alpha")
    assert {:ok, waiting} = Runtime.await_agent(runtime, "alpha", 2_000)
    assert waiting.activity == :waiting
    assert :ok = GenServer.stop(runtime)

    second =
      start_fake(context, [
        response(nil, [
          tool_call("call-1", "complete_task", %{"results" => %{"summary" => "ok"}})
        ])
      ])

    restarted = start_runtime(context, definition, second)
    assert {:ok, _running} = Runtime.start_agent(restarted, "alpha")
    assert eventually(fn -> completed?(restarted, "alpha") end)

    request = hd(Provider.requests(second))
    refute Enum.any?(request.messages, &(&1.role == :assistant))
    refute Enum.any?(request.messages, &(&1.content == "Old conversation."))
  end

  test "restore-interrupted restores complete turns and drops an unfinished tool call", context do
    definition = definition(context: "restore-interrupted = \"checkpoint\"")
    state_dir = Path.join(context.tmp, "state")
    call = tool_call("call-1", "echo", %{"text" => "hi"})

    assert :ok = ContextStore.append_run(state_dir, "alpha", "run-old", :started)

    assert :ok =
             ContextStore.append_message(
               state_dir,
               "alpha",
               "run-old",
               "attempt-old",
               Message.user("Earlier question")
             )

    assert :ok =
             ContextStore.append_message(
               state_dir,
               "alpha",
               "run-old",
               "attempt-old",
               Message.assistant("Working", tool_calls: [call])
             )

    fake =
      start_fake(context, [
        response(nil, [
          tool_call("call-2", "complete_task", %{"results" => %{"summary" => "ok"}})
        ])
      ])

    runtime = start_runtime(context, definition, fake)
    assert {:ok, _running} = Runtime.start_agent(runtime, "alpha")
    assert eventually(fn -> completed?(runtime, "alpha") end)

    request = hd(Provider.requests(fake))
    assert Enum.any?(request.messages, &(&1.role == :user and &1.content == "Earlier question"))
    refute Enum.any?(request.messages, &(&1.role == :assistant and &1.content == "Working"))
  end

  test "prior-runs queryable restores a closed one-shot conversation", context do
    definition = definition(context: "prior-runs = \"queryable\"")
    state_dir = Path.join(context.tmp, "state")

    assert :ok = ContextStore.append_run(state_dir, "alpha", "run-old", :started)

    assert :ok =
             ContextStore.append_message(
               state_dir,
               "alpha",
               "run-old",
               nil,
               Message.user("Old question")
             )

    assert :ok =
             ContextStore.append_message(
               state_dir,
               "alpha",
               "run-old",
               nil,
               Message.assistant("Old answer")
             )

    assert :ok = ContextStore.append_run(state_dir, "alpha", "run-old", :completed)

    fake =
      start_fake(context, [
        response(nil, [
          tool_call("call-1", "complete_task", %{"results" => %{"summary" => "ok"}})
        ])
      ])

    runtime = start_runtime(context, definition, fake)
    assert {:ok, _running} = Runtime.start_agent(runtime, "alpha")
    assert eventually(fn -> completed?(runtime, "alpha") end)

    request = hd(Provider.requests(fake))
    assert Enum.any?(request.messages, &(&1.role == :user and &1.content == "Old question"))
    assert Enum.any?(request.messages, &(&1.role == :assistant and &1.content == "Old answer"))
  end

  test "streaming provider emits live text deltas and records one assistant message",
       context do
    definition = definition()

    fake = start_fake(context, [response("Hello there", [])])
    runtime = start_runtime(context, definition, fake, StreamingProvider)
    :ok = Runtime.subscribe(runtime)

    assert {:ok, _running} = Runtime.start_agent(runtime, "alpha")
    assert {:ok, waiting} = Runtime.await_agent(runtime, "alpha", 2_000)
    assert waiting.activity == :waiting

    deltas =
      Enum.reduce_while(1..String.length("Hello there"), "", fn _index, acc ->
        receive do
          {:patchbay_event, %{type: :model_delta, agent_id: "alpha", data: %{delta: delta}}} ->
            {:cont, acc <> delta}
        after
          2_000 -> {:halt, acc}
        end
      end)

    assert deltas == "Hello there"

    assert {:ok, agent} = Runtime.get_agent(runtime, "alpha")
    assert agent.stream_text == nil

    assert {:ok, messages} = Runtime.messages(runtime, "alpha")
    assistants = Enum.filter(messages, &(&1.role == :assistant))
    assert [%Message{content: "Hello there"}] = assistants
    refute Enum.any?(messages, &(&1.role == :assistant and &1.content == "H"))

    assert {:ok, events} = Runtime.list_events(runtime, "alpha")
    assert Enum.count(events, &(&1.type == :model_message)) == 1
    refute Enum.any?(events, &(&1.type == :model_delta))
  end

  test "compacts the current context before a provider turn", context do
    definition = definition(context: ~s(threshold = 1\ntarget = 0))
    state_dir = Path.join(context.tmp, "state")

    fake =
      start_fake(context, [
        response("first reply", []),
        response("compacted summary", []),
        response(nil, [tool_call("call-1", "complete_task", %{"results" => %{"summary" => "ok"}})])
      ])

    runtime = start_runtime(context, definition, fake, StreamingProvider)
    assert {:ok, _running} = Runtime.start_agent(runtime, "alpha", message: "hello")
    assert {:ok, waiting} = Runtime.await_agent(runtime, "alpha", 2_000)
    assert waiting.activity == :waiting

    assert {:ok, _running} = Runtime.send_message(runtime, "alpha", "again")
    assert eventually(fn -> completed?(runtime, "alpha") end, 5_000)

    assert [first_request, summary_request, turn_request] = Provider.requests(fake)

    refute Enum.any?(first_request.messages, &(&1.name == "context-summary"))
    assert Enum.any?(first_request.messages, &(&1.role == :user and &1.content == "hello"))

    assert Enum.any?(
             summary_request.messages,
             &(&1.role == :system and &1.content =~ "compact conversation context")
           )

    assert %Message{role: :system, content: "You are a test agent."} = hd(turn_request.messages)

    assert %Message{role: :user, name: "context-summary", content: "compacted summary"} =
             Enum.find(turn_request.messages, &(&1.name == "context-summary"))

    assert Enum.any?(turn_request.messages, &(&1.role == :system))
    assert Enum.any?(turn_request.messages, &(&1.role == :user and &1.content == "again"))
    refute Enum.any?(turn_request.messages, &(&1.role == :user and &1.content == "hello"))

    assert {:ok, events} = Runtime.list_events(runtime, "alpha")
    compacted = Enum.find(events, &(&1.type == :context_compacted))
    assert compacted
    assert compacted.data["revision"] == 2
    assert compacted.data["archive_generation"] =~ ".pbc.zst"
    assert File.exists?(compacted.data["archive_path"])

    agent = :sys.get_state(runtime).agents["alpha"]
    run = Lifecycle.current_run(agent.lifecycle)
    assert run.context.revision == 2
    assert [%{reason: :compaction, archive: archive}] = run.context.sealed
    assert archive == compacted.data["archive_generation"]

    assert {:ok, entries} = ContextStore.read(state_dir, "alpha")
    stored = for {:message, %{message: message}} <- entries, do: message
    assert hd(stored).name == "context-summary"
  end

  test "manual compact_agent compacts immediately", context do
    definition = definition(context: ~s(threshold = 1_000_000\ntarget = 0))

    fake =
      start_fake(context, [
        response("first reply", []),
        response("manual summary", [])
      ])

    runtime = start_runtime(context, definition, fake, StreamingProvider)
    assert {:ok, _running} = Runtime.start_agent(runtime, "alpha", message: "hello")
    assert {:ok, waiting} = Runtime.await_agent(runtime, "alpha", 2_000)
    assert waiting.activity == :waiting

    assert {:ok, _summary} = Runtime.compact_agent(runtime, "alpha", target: 0)

    assert {:ok, messages} = Runtime.messages(runtime, "alpha")

    assert %Message{role: :user, name: "context-summary", content: "manual summary"} =
             Enum.find(messages, &(&1.name == "context-summary"))

    assert {:ok, events} = Runtime.list_events(runtime, "alpha")
    compacted = Enum.find(events, &(&1.type == :context_compacted))
    assert compacted
    assert compacted.data["revision"] == 2

    agent = :sys.get_state(runtime).agents["alpha"]
    assert Lifecycle.current_run(agent.lifecycle).context.revision == 2
  end

  test "compaction runs off the runtime and serializes identical requests", context do
    definition = definition(context: ~s(threshold = 1_000_000\ntarget = 0))

    fake =
      start_fake(context, [
        response("first reply", []),
        response("single summary", [])
      ])

    runtime =
      start_runtime(context, definition, fake, BlockingProvider, test_pid: self())

    assert {:ok, _running} = Runtime.start_agent(runtime, "alpha", message: "hello")
    assert {:ok, waiting} = Runtime.await_agent(runtime, "alpha", 2_000)
    assert waiting.activity == :waiting

    first = Task.async(fn -> Runtime.compact_agent(runtime, "alpha", target: 0) end)
    assert_receive {:summary_requested, blocker}, 2_000

    probe = Task.async(fn -> Runtime.activity(runtime, "alpha") end)

    case Task.yield(probe, 1_000) do
      {:ok, {:ok, _activity}} ->
        :ok

      _other ->
        send(blocker, :release)
        flunk("compaction blocked the runtime GenServer")
    end

    second = Task.async(fn -> Runtime.compact_agent(runtime, "alpha", target: 0) end)
    Process.sleep(100)
    refute_receive {:summary_requested, _pid}, 300

    send(blocker, :release)

    assert {:ok, _summary} = Task.await(first, 5_000)
    assert {:ok, _summary} = Task.await(second, 5_000)

    assert {:ok, messages} = Runtime.messages(runtime, "alpha")

    assert %Message{role: :user, name: "context-summary", content: "single summary"} =
             Enum.find(messages, &(&1.name == "context-summary"))
  end

  test "stopping an agent cancels an in-flight compaction", context do
    definition = definition(context: ~s(threshold = 1_000_000\ntarget = 0))
    state_dir = Path.join(context.tmp, "state")

    fake = start_fake(context, [response("first reply", []), response("unused summary", [])])
    runtime = start_runtime(context, definition, fake, BlockingProvider, test_pid: self())

    assert {:ok, _running} = Runtime.start_agent(runtime, "alpha", message: "hello")
    assert {:ok, _waiting} = Runtime.await_agent(runtime, "alpha", 2_000)

    compacting = Task.async(fn -> Runtime.compact_agent(runtime, "alpha", target: 0) end)
    assert_receive {:summary_requested, _blocker}, 2_000

    assert {:ok, _stopped} = Runtime.stop_agent(runtime, "alpha")
    assert {:error, :compaction_cancelled} = Task.await(compacting, 5_000)

    assert {:ok, messages} = Runtime.messages(runtime, "alpha")
    refute Enum.any?(messages, &(&1.name == "context-summary"))
    refute File.exists?(ContextStore.archive_dir(state_dir, "alpha"))
  end

  test "compaction provider failure leaves the runtime context untouched", context do
    definition = definition(context: ~s(threshold = 1\ntarget = 0))
    state_dir = Path.join(context.tmp, "state")

    fake =
      start_fake(context, [
        response("first reply", []),
        {:error, Error.new(:api, "summary failed")}
      ])

    runtime = start_runtime(context, definition, fake, Provider)

    assert {:ok, _running} = Runtime.start_agent(runtime, "alpha", message: "hello")
    assert {:ok, waiting} = Runtime.await_agent(runtime, "alpha", 2_000)
    assert waiting.activity == :waiting

    assert {:ok, _running} = Runtime.send_message(runtime, "alpha", "again")
    assert eventually(fn -> completed?(runtime, "alpha") end, 5_000)

    assert {:ok, agent} = Runtime.get_agent(runtime, "alpha")
    assert agent.run_status == :failed

    assert {:ok, messages} = Runtime.messages(runtime, "alpha")

    assert [
             %Message{role: :system},
             %Message{role: :user, content: "hello"},
             %Message{role: :assistant, content: "first reply"},
             %Message{role: :user, content: "again"}
           ] = messages

    refute File.exists?(ContextStore.archive_dir(state_dir, "alpha"))

    assert {:ok, entries} = ContextStore.read(state_dir, "alpha")
    stored = for {:message, %{message: message}} <- entries, do: message
    assert length(stored) == 3
    refute Enum.any?(stored, &(&1.name == "context-summary"))

    assert {:ok, events} = Runtime.list_events(runtime, "alpha")
    refute Enum.any?(events, &(&1.type == :context_compacted))
  end

  defp start_runtime(context, definition, fake, provider \\ Provider, extra_opts \\ []) do
    {:ok, runtime} =
      Runtime.start_link(
        definitions: %{"alpha" => definition},
        state_dir: Path.join(context.tmp, "state"),
        workspace_dir: Path.join(context.tmp, "workspaces"),
        result_dir: Path.join(context.tmp, "results"),
        manager: context.stub,
        worker_client: WorkerClient,
        provider: provider,
        provider_opts: [fake: fake] ++ extra_opts
      )

    on_exit(fn ->
      if Process.alive?(runtime) do
        try do
          GenServer.stop(runtime)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    runtime
  end

  defp runner_pid(runtime) do
    runtime
    |> :sys.get_state()
    |> Map.fetch!(:agents)
    |> Map.fetch!("alpha")
    |> Map.fetch!(:runner_pid)
  end

  defp start_fake(context, responses) do
    {:ok, fake} = Provider.start_link(responses)
    on_exit(fn -> if Process.alive?(fake), do: Agent.stop(fake) end)
    _ = context
    fake
  end

  defp definition(opts \\ []) do
    kind = Keyword.get(opts, :kind, "one-shot")
    echo = System.find_executable("echo")

    context_section =
      case Keyword.get(opts, :context) do
        nil -> ""
        context -> "\n[context]\n" <> context <> "\n"
      end

    body = """
    format-version = 1
    id = "alpha"

    [model]
    name = "test-model"

    [lifecycle]
    kind = "#{kind}"
    #{context_section}
    [[results]]
    id = "summary"
    label = "Summary"
    form = "prose"

    [[toolkits]]
    toolkit = "shell"

    [[toolkits.operations]]
    name = "echo"
    executable = "#{echo}"
    argv = ["{text}"]

    [toolkits.operations.arguments.text]
    type = "string"
    """

    {:ok, definition} = Definition.parse(body)

    %{
      definition
      | prompts: [
          %Prompt{
            name: "system.md",
            path: "/tmp/system.md",
            content: "You are a test agent.",
            source: :agent
          }
        ]
    }
  end

  defp response(content, calls) do
    {:ok,
     %Response{
       content: content,
       tool_calls: calls,
       finish_reason: if(calls == [], do: :stop, else: :tool_calls)
     }}
  end

  defp tool_call(id, name, arguments) do
    ToolCall.new(id, name, arguments)
  end

  defp completed?(runtime, agent_id) do
    case Runtime.get_agent(runtime, agent_id) do
      {:ok, %{status: :stopped, run_status: status}} when status in [:completed, :failed] -> true
      _other -> false
    end
  end

  defp eventually(fun, timeout \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition was not met before timeout")
      else
        Process.sleep(20)
        do_eventually(fun, deadline)
      end
    end
  end
end
