defmodule Patchbay.AgentRunner do
  @moduledoc """
  Minimal model loop for a running agent.

  A runner is started by `Patchbay.Runtime` as an unlinked process after the
  agent's worker is ready. Provider calls happen in that process, so the
  runtime GenServer stays responsive while a completion is in flight.

  The runtime owns the in-memory message list and durable events. This module
  builds the provider request from `Patchbay.Definition` prompts and toolkit
  declarations, calls the provider, and dispatches the model's tool calls back
  through `Patchbay.Runtime.execute_tool/5`.

  The runtime also checkpoints messages to `Patchbay.ContextStore`; a restored
  history contains only complete provider turns, so this loop never resumes
  midway through an assistant tool-call message.

  `complete_task` and `fail_task` are built-in model tools. They are not
  toolkit operations; this module validates `complete_task` arguments against
  the definition's declared results before asking the runtime to close the run.
  """

  alias Patchbay.Definition.Prompt
  alias Patchbay.Provider

  alias Patchbay.Provider.{
    Config,
    Error,
    JSON,
    Message,
    Request,
    Response,
    StreamEvent,
    Tool,
    ToolCall
  }

  alias Patchbay.Toolkit.Registry
  alias Patchbay.Toolkit.Variables

  @complete_task "complete_task"
  @fail_task "fail_task"

  @type context :: %{
          request: Request.t(),
          provider: module(),
          provider_opts: keyword(),
          definition: map()
        }

  @doc false
  @spec run(GenServer.server(), binary()) :: :ok
  def run(server, agent_id) do
    loop(server, agent_id, monitor_owner(server))
  end

  @doc "Builds system messages from the definition's enabled prompt files."
  @spec system_messages(map()) :: [Message.t()]
  def system_messages(definition) do
    prompts =
      definition
      |> Map.get(:prompts, [])
      |> Enum.reduce([], fn
        %Prompt{content: content, name: name}, acc when is_binary(content) ->
          [Message.system(content, name: name) | acc]

        _prompt, acc ->
          acc
      end)
      |> Enum.reverse()

    case prompts do
      [] -> [Message.system("You are agent #{Map.get(definition, :id, "unknown")}.")]
      messages -> messages
    end
  end

  @doc """
  Builds the provider tool list: implicit native toolkits (including the
  terminal tools), declared native toolkits, and declared fixed operations.
  """
  @spec tools(map()) :: [Tool.t()]
  def tools(definition) do
    context = %{definition: definition}
    implicit = implicit_tools(context)

    specs = implicit ++ declared_tool_specs(definition, context)

    specs
    |> Enum.map(fn spec -> Tool.new(spec.name, spec.description, spec.schema) end)
    |> Enum.reduce(%{}, fn tool, acc -> Map.put_new(acc, tool.name, tool) end)
    |> Map.values()
  end

  @doc """
  Validates `complete_task` arguments against declared results.

  The arguments may contain a `results` object or may be the result map
  itself. Every unconditionally required result must be present, unknown
  result ids are rejected, and values are checked against the declared form.
  A result whose `required-by` dependency is submitted must be submitted too,
  and a file result's extension must fall inside the declared `extensions`
  list when one is declared.
  """
  @spec validate_results(map(), map()) :: {:ok, map()} | {:error, term()}
  def validate_results(definition, arguments) when is_map(arguments) do
    declared = Map.get(definition, :results, [])

    with {:ok, given} <- result_map(arguments) do
      declared_ids = MapSet.new(declared, & &1.id)
      given_ids = MapSet.new(Map.keys(given))

      unknown =
        given_ids
        |> MapSet.difference(declared_ids)
        |> MapSet.to_list()
        |> Enum.sort()

      missing =
        declared
        |> Enum.filter(& &1.required)
        |> Enum.map(& &1.id)
        |> Enum.reject(&Map.has_key?(given, &1))
        |> Enum.sort()

      missing_dependents =
        declared
        |> Enum.filter(fn result ->
          is_binary(result.required_by) and Map.has_key?(given, result.required_by) and
            not Map.has_key?(given, result.id)
        end)
        |> Enum.map(&{&1.id, &1.required_by})
        |> Enum.sort()

      value_errors =
        declared
        |> Enum.reduce([], fn result, errors ->
          case Map.fetch(given, result.id) do
            {:ok, value} when not is_nil(value) ->
              case validate_value(result, value) do
                :ok -> errors
                {:error, detail} -> [{result.id, detail} | errors]
              end

            _missing_or_nil ->
              errors
          end
        end)
        |> Enum.reverse()

      cond do
        unknown != [] ->
          {:error, {:unknown_results, unknown}}

        missing_dependents != [] ->
          {:error, {:missing_dependent_results, missing_dependents}}

        missing != [] ->
          {:error, {:missing_required_results, missing}}

        value_errors != [] ->
          {:error, {:invalid_result_values, value_errors}}

        true ->
          {:ok, given}
      end
    end
  end

  def validate_results(_definition, arguments), do: {:error, {:invalid_results, arguments}}

  @doc """
  Checks that a provider module and its options are usable before an agent
  starts. Custom providers may expose `configured?/1`; otherwise they are
  assumed to carry their own configuration.
  """
  @spec validate_provider(module() | nil, keyword(), map()) :: :ok | {:error, term()}
  def validate_provider(nil, _opts, _definition) do
    {:error, {:provider_not_configured, :provider}}
  end

  def validate_provider(Patchbay.Provider.OpenAI, opts, definition) do
    validate_openai(opts, definition)
  end

  def validate_provider(provider, opts, _definition) when is_atom(provider) do
    _ = Code.ensure_loaded?(provider)

    cond do
      function_exported?(provider, :configured?, 1) ->
        case provider.configured?(opts) do
          :ok -> :ok
          true -> :ok
          false -> {:error, {:provider_not_configured, :configured}}
          {:error, reason} -> {:error, {:provider_not_configured, reason}}
          other -> {:error, {:provider_not_configured, other}}
        end

      function_exported?(provider, :complete, 2) ->
        :ok

      function_exported?(provider, :stream, 3) ->
        :ok

      true ->
        {:error, {:provider_not_configured, {:invalid_provider, provider}}}
    end
  end

  def validate_provider(provider, _opts, _definition) do
    {:error, {:provider_not_configured, {:invalid_provider, provider}}}
  end

  @doc "Returns true for a built-in terminal tool name."
  @spec terminal_tool?(term()) :: boolean()
  def terminal_tool?(name), do: name in [@complete_task, @fail_task]

  defp loop(server, agent_id, owner) do
    _ = call_runtime(fn -> Patchbay.Runtime.runner_compact(server, agent_id) end)

    case call_runtime(fn -> Patchbay.Runtime.runner_context(server, agent_id) end) do
      {:ok, context} ->
        case complete(context, server, agent_id) do
          {:ok, %Response{} = response} ->
            handle_response(server, agent_id, owner, context, response)

          {:error, error} ->
            _ =
              call_runtime(fn ->
                Patchbay.Runtime.runner_provider_error(server, agent_id, error)
              end)

            :ok
        end

      {:error, _reason} ->
        :ok
    end
  end

  defp call_runtime(fun) do
    try do
      fun.()
    catch
      :exit, reason -> {:error, {:runtime_unavailable, reason}}
    end
  end

  defp complete(context, server, agent_id) do
    provider_opts = Keyword.put_new(context.provider_opts, :provider, context.provider)

    try do
      result =
        if streaming?(context.provider) do
          Provider.stream(context.request, stream_callback(server, agent_id), provider_opts)
        else
          Provider.complete(context.request, provider_opts)
        end

      normalize_result(result)
    rescue
      error ->
        {:error, Error.new(:protocol, "provider raised: #{Exception.message(error)}")}
    catch
      kind, reason ->
        {:error, Error.new(:protocol, "provider failed: #{inspect({kind, reason})}")}
    end
  end

  defp streaming?(provider) when is_atom(provider) do
    Code.ensure_loaded?(provider) and function_exported?(provider, :stream, 3)
  end

  defp streaming?(_provider), do: false

  defp stream_callback(server, agent_id) do
    fn
      %StreamEvent{type: :text_delta, text: text} when is_binary(text) and text != "" ->
        try do
          case Patchbay.Runtime.runner_model_delta(server, agent_id, text) do
            :ok -> :ok
            {:error, reason} -> {:halt, reason}
          end
        catch
          :exit, reason -> {:halt, reason}
        end

      %StreamEvent{} ->
        :ok
    end
  end

  defp normalize_result({:ok, %Response{} = response}), do: {:ok, response}
  defp normalize_result({:error, %Error{} = error}), do: {:error, error}

  defp normalize_result(other) do
    {:error,
     Error.new(:protocol, "provider returned an invalid result",
       details: %{value: inspect(other)}
     )}
  end

  defp handle_response(server, agent_id, owner, context, response) do
    case call_runtime(fn -> Patchbay.Runtime.runner_record_model(server, agent_id, response) end) do
      {:ok, calls} ->
        if calls == [] do
          case call_runtime(fn -> Patchbay.Runtime.runner_wait(server, agent_id) end) do
            {:ok, :continue} -> loop(server, agent_id, owner)
            {:ok, :wait} -> wait_for_wake(server, agent_id, owner)
            _other -> :ok
          end
        else
          case execute_calls(server, agent_id, context.definition, calls) do
            :continue -> loop(server, agent_id, owner)
            :stop -> :ok
          end
        end

      {:error, _reason} ->
        :ok
    end
  end

  defp monitor_owner(server) when is_pid(server), do: Process.monitor(server)

  defp monitor_owner(server) when is_atom(server) do
    case Process.whereis(server) do
      pid when is_pid(pid) -> Process.monitor(pid)
      nil -> nil
    end
  end

  defp monitor_owner(_server), do: nil

  defp wait_for_wake(server, agent_id, owner) do
    receive do
      {:patchbay_runner_wake, ^agent_id} -> loop(server, agent_id, owner)
      {:DOWN, ^owner, :process, _pid, _reason} -> :ok
    end
  end

  defp execute_calls(server, agent_id, definition, calls) do
    if mixed_terminal_calls?(calls) do
      reject_mixed_terminal_calls(server, agent_id, calls)
      :continue
    else
      Enum.reduce_while(calls, :continue, fn call, _acc ->
        case execute_call(server, agent_id, definition, call) do
          :continue -> {:cont, :continue}
          :stop -> {:halt, :stop}
        end
      end)
    end
  end

  defp mixed_terminal_calls?(calls) do
    length(calls) > 1 and
      Enum.any?(calls, fn
        %ToolCall{name: name} -> terminal_tool?(name)
        _call -> false
      end)
  end

  defp reject_mixed_terminal_calls(server, agent_id, calls) do
    Enum.each(calls, fn
      %ToolCall{} = call ->
        _ =
          call_runtime(fn ->
            Patchbay.Runtime.runner_tool_result(
              server,
              agent_id,
              call,
              "error",
              "terminal tools must be called alone; no tool in this turn was executed"
            )
          end)

      call ->
        _ =
          call_runtime(fn ->
            Patchbay.Runtime.runner_tool_result(
              server,
              agent_id,
              %ToolCall{id: nil, name: "unknown", arguments: %{}},
              "error",
              "terminal tools must be called alone; invalid tool call: #{inspect(call)}"
            )
          end)
    end)
  end

  defp execute_call(server, agent_id, _definition, %ToolCall{name: name} = call)
       when not is_binary(name) do
    _ =
      call_runtime(fn ->
        Patchbay.Runtime.runner_tool_result(
          server,
          agent_id,
          call,
          "error",
          "tool call is missing a name"
        )
      end)

    :continue
  end

  defp execute_call(server, agent_id, definition, %ToolCall{name: name} = call) do
    case name do
      @complete_task ->
        complete_task(server, agent_id, definition, call)

      @fail_task ->
        fail_task(server, agent_id, call)

      _other ->
        fixed_operation(server, agent_id, call)
    end
  end

  defp execute_call(server, agent_id, _definition, call) do
    _ =
      call_runtime(fn ->
        Patchbay.Runtime.runner_tool_result(
          server,
          agent_id,
          %ToolCall{id: nil, name: "unknown", arguments: %{}},
          "error",
          "invalid tool call: #{inspect(call)}"
        )
      end)

    :continue
  end

  defp complete_task(server, agent_id, definition, call) do
    case validate_results(definition, call.arguments) do
      {:ok, results} ->
        _ =
          call_runtime(fn ->
            Patchbay.Runtime.runner_complete(server, agent_id, call, results)
          end)

        :stop

      {:error, reason} ->
        _ =
          call_runtime(fn ->
            Patchbay.Runtime.runner_tool_result(
              server,
              agent_id,
              call,
              "error",
              "complete_task rejected: #{format_reason(reason)}"
            )
          end)

        :continue
    end
  end

  defp fail_task(server, agent_id, call) do
    _ =
      call_runtime(fn ->
        Patchbay.Runtime.runner_fail(server, agent_id, call, fail_reason(call.arguments))
      end)

    :stop
  end

  defp fixed_operation(server, agent_id, call) do
    arguments = if is_map(call.arguments), do: call.arguments, else: %{}

    case call_runtime(fn ->
           Patchbay.Runtime.execute_tool(server, agent_id, call.name, arguments,
             tool_call_id: call.id
           )
         end) do
      {:ok, result} ->
        _ =
          call_runtime(fn ->
            Patchbay.Runtime.runner_tool_message(server, agent_id, call, result_text(result))
          end)

        :continue

      {:error, reason} ->
        _ =
          call_runtime(fn ->
            Patchbay.Runtime.runner_tool_result(
              server,
              agent_id,
              call,
              "error",
              format_reason(reason)
            )
          end)

        :continue
    end
  end

  defp result_text(%{output: output}) when is_binary(output) and output != "", do: output
  defp result_text(%{error: error}) when not is_nil(error), do: format_reason(error)
  defp result_text(result), do: encode_or_inspect(result)

  defp fail_reason(arguments) when is_map(arguments) do
    Map.get(arguments, "reason") || Map.get(arguments, :reason) || arguments
  end

  defp fail_reason(reason), do: reason

  defp result_map(arguments) do
    case Map.fetch(arguments, "results") do
      {:ok, results} when is_map(results) ->
        {:ok, stringify_keys(results)}

      :error ->
        case Map.fetch(arguments, :results) do
          {:ok, results} when is_map(results) -> {:ok, stringify_keys(results)}
          _other -> {:ok, stringify_keys(arguments)}
        end

      _other ->
        {:ok, stringify_keys(arguments)}
    end
  end

  defp validate_value(%{form: form}, value) when form in [:prose, :url] do
    if is_binary(value) and String.trim(value) != "" do
      :ok
    else
      {:error, :expected_non_empty_string}
    end
  end

  defp validate_value(%{form: :file, extensions: extensions}, value) do
    with true <- is_binary(value) and String.trim(value) != "",
         :ok <- validate_file_path(value),
         {:ok, _ext} <- lint_extension(value, extensions) do
      :ok
    else
      false -> {:error, :expected_non_empty_string}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_file_result}
    end
  end

  defp validate_value(%{form: :number}, value) when is_number(value), do: :ok
  defp validate_value(%{form: :number}, _value), do: {:error, :expected_number}

  defp validate_value(_result, _value), do: :ok

  defp validate_file_path(value) do
    if String.contains?(value, <<0>>) do
      {:error, :invalid_file_path}
    else
      case Path.basename(value) do
        name when name in ["", ".", ".."] -> {:error, :invalid_file_path}
        _name -> :ok
      end
    end
  end

  defp lint_extension(value, extensions) do
    Patchbay.ArtifactStore.lint_source(value, extensions)
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason, limit: 20, printable_limit: 2048)

  defp encode_or_inspect(value) do
    case JSON.encode(value) do
      {:ok, encoded} -> encoded
      {:error, _reason} -> inspect(value, limit: 20, printable_limit: 2048)
    end
  end

  defp validate_openai(opts, definition) do
    config = Keyword.get_lazy(opts, :config, fn -> Config.load(opts) end)

    cond do
      not match?(%Config{}, config) ->
        {:error, {:provider_not_configured, :invalid_config}}

      blank?(config.model) and blank?(model_name(definition)) ->
        {:error, {:provider_not_configured, :model}}

      default_openai_url?(config.base_url) and blank?(config.api_key) ->
        {:error, {:provider_not_configured, :api_key}}

      true ->
        :ok
    end
  end

  defp default_openai_url?(base_url) do
    String.trim_trailing(base_url || "", "/") == "https://api.openai.com/v1"
  end

  defp blank?(value), do: not (is_binary(value) and String.trim(value) != "")

  defp model_name(%{model: %{name: name}}), do: name
  defp model_name(_definition), do: nil

  defp implicit_tools(context) do
    definition = Map.get(context, :definition, %{})

    declared =
      Registry.implicit_tools(context, config_root: Map.get(definition, :config_root))

    names = MapSet.new(declared, & &1.name)

    fallback =
      Patchbay.Toolkit.Native.Terminal.tools(context)
      |> Enum.reject(&MapSet.member?(names, &1.name))

    (declared ++ fallback)
    |> Enum.reduce(%{}, fn tool, acc -> Map.put_new(acc, tool.name, tool) end)
    |> Map.values()
  end

  defp declared_tool_specs(definition, context) do
    definition
    |> Map.get(:toolkits, [])
    |> Enum.flat_map(fn toolkit ->
      native = Map.get(toolkit, :native)
      selection = Map.get(toolkit, :tools, [])

      native_tools =
        case native do
          nil -> []
          _native -> Registry.tools(native, context, selection)
        end

      fixed_tools =
        toolkit
        |> Map.get(:operations, [])
        |> Enum.map(fn operation ->
          %{
            name: Map.get(operation, :name),
            description:
              Map.get(operation, :description) ||
                "Runs the fixed operation #{Map.get(operation, :name)}.",
            schema: operation_schema(operation)
          }
        end)

      native_tools ++ fixed_tools
    end)
    |> Enum.reject(&is_nil(&1.name))
  end

  defp operation_schema(operation) do
    arguments = Map.get(operation, :arguments, %{})

    properties =
      Map.new(arguments, fn {name, argument} ->
        {name, argument_schema(argument)}
      end)

    required = required_arguments(operation, arguments)

    %{"type" => "object", "properties" => properties}
    |> put_required(required)
  end

  defp required_arguments(operation, arguments) do
    referenced =
      operation
      |> Map.get(:argv, [])
      |> List.wrap()
      |> Enum.flat_map(&Variables.references(&1).arguments)
      |> MapSet.new()

    arguments
    |> Enum.filter(fn {name, argument} ->
      case Map.get(argument, :required) do
        true -> true
        false -> false
        nil -> MapSet.member?(referenced, name)
      end
    end)
    |> Enum.map(fn {name, _argument} -> name end)
  end

  defp argument_schema(nil), do: %{"type" => "string"}

  defp argument_schema(%{type: :enum, values: values}) when is_list(values) do
    %{"type" => "string", "enum" => values}
  end

  defp argument_schema(%{type: type}) when type in [:number], do: %{"type" => "number"}
  defp argument_schema(%{type: type}) when type in [:integer], do: %{"type" => "integer"}
  defp argument_schema(%{type: type}) when type in [:boolean], do: %{"type" => "boolean"}

  defp argument_schema(%{type: type})
       when type in [:string, :path, :file, :directory],
       do: %{"type" => "string"}

  defp argument_schema(_argument), do: %{"type" => "string"}

  defp put_required(schema, []), do: schema
  defp put_required(schema, required), do: Map.put(schema, "required", required)
end
