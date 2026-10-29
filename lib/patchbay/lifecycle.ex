defmodule Patchbay.Lifecycle.Instance do
  @moduledoc """
  One concrete incarnation of an agent: its manager-side resources, toolkits,
  and worker.
  """

  @type state :: :starting | :ready | :stopped

  @type t :: %__MODULE__{
          id: term(),
          agent_id: term(),
          run_id: term(),
          attempt_id: term(),
          state: state(),
          started_at: term(),
          stopped_at: term(),
          stop_reason: term(),
          metadata: map()
        }

  defstruct [
    :id,
    :agent_id,
    :run_id,
    :attempt_id,
    :started_at,
    :stopped_at,
    :stop_reason,
    state: :starting,
    metadata: %{}
  ]

  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, id} <- fetch(attrs, :id),
         {:ok, agent_id} <- fetch(attrs, :agent_id),
         {:ok, run_id} <- fetch(attrs, :run_id),
         {:ok, attempt_id} <- fetch(attrs, :attempt_id) do
      {:ok,
       %__MODULE__{
         id: id,
         agent_id: agent_id,
         run_id: run_id,
         attempt_id: attempt_id,
         started_at: Map.get(attrs, :started_at),
         metadata: Map.get(attrs, :metadata, %{})
       }}
    end
  end

  @spec ready(t()) :: {:ok, t()} | {:error, term()}
  def ready(%__MODULE__{state: :starting} = instance),
    do: {:ok, %__MODULE__{instance | state: :ready}}

  def ready(%__MODULE__{state: state}), do: {:error, {:invalid_instance_state, state}}

  @spec stop(t(), term(), term()) :: {:ok, t()} | {:error, term()}
  def stop(%__MODULE__{state: :stopped} = instance, _reason, _at), do: {:ok, instance}

  def stop(%__MODULE__{} = instance, reason, at) do
    {:ok,
     %__MODULE__{
       instance
       | state: :stopped,
         stop_reason: reason,
         stopped_at: at
     }}
  end

  defp fetch(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when not is_nil(value) -> {:ok, value}
      {:ok, nil} -> {:error, {:missing, key}}
      :error -> {:error, {:missing, key}}
    end
  end
end

defmodule Patchbay.Lifecycle do
  @moduledoc """
  Agent-level lifecycle over runs, attempts, instances, and context revisions.

  A run is logical work. An attempt is one instance's effort within a run.
  Interruption ends an attempt while keeping the run open for resume. Terminal
  results close the run; the next activation starts a new run.
  """

  alias Patchbay.Lifecycle.Instance
  alias Patchbay.Run
  alias Patchbay.Run.Attempt

  @type kind :: Run.kind()

  @type recovery :: :fresh | {:resume, Run.id()} | {:refuse, Run.id()}

  @type t :: %__MODULE__{
          agent_id: term(),
          kind: kind(),
          current_run_id: Run.id() | nil,
          runs: %{optional(Run.id()) => Run.t()},
          instances: %{optional(term()) => Instance.t()}
        }

  defstruct [
    :agent_id,
    :current_run_id,
    kind: :one_shot,
    runs: %{},
    instances: %{}
  ]

  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, agent_id} <- fetch(attrs, :agent_id),
         {:ok, kind} <- resolve_kind(attrs) do
      {:ok, %__MODULE__{agent_id: agent_id, kind: kind}}
    end
  end

  @spec perpetual?(t()) :: boolean()
  def perpetual?(%__MODULE__{kind: :perpetual}), do: true
  def perpetual?(%__MODULE__{}), do: false

  @spec open_run?(t()) :: boolean()
  def open_run?(state) do
    case current_run(state) do
      nil -> false
      run -> Run.open?(run)
    end
  end

  @spec current_run(t()) :: Run.t() | nil
  def current_run(%__MODULE__{current_run_id: nil}), do: nil

  def current_run(%__MODULE__{current_run_id: run_id, runs: runs}),
    do: Map.get(runs, run_id)

  @spec get_run(t(), Run.id()) :: Run.t() | nil
  def get_run(%__MODULE__{runs: runs}, run_id), do: Map.get(runs, run_id)

  @spec get_instance(t(), term()) :: Instance.t() | nil
  def get_instance(%__MODULE__{instances: instances}, instance_id),
    do: Map.get(instances, instance_id)

  @spec active_attempt(t()) :: Attempt.t() | nil
  def active_attempt(state) do
    case current_run(state) do
      nil -> nil
      run -> Run.active_attempt(run)
    end
  end

  @spec recovery(t()) :: recovery()
  def recovery(state) do
    case current_run(state) do
      nil ->
        :fresh

      %Run{status: :interrupted} = run ->
        {:resume, run.id}

      %Run{} = run ->
        cond do
          Run.terminal?(run) -> :fresh
          Run.active_attempt(run) != nil -> {:refuse, run.id}
          true -> {:resume, run.id}
        end
    end
  end

  @spec activate(t(), map()) :: {:ok, t()} | {:error, term()}
  def activate(state, attrs) when is_map(attrs) do
    case recovery(state) do
      :fresh ->
        with {:ok, state} <- start_run(state, attrs) do
          begin_attempt(state, attrs)
        end

      {:resume, _run_id} ->
        resume(state, attrs)

      {:refuse, run_id} ->
        {:error, {:run_active, run_id}}
    end
  end

  @spec start_run(t(), map()) :: {:ok, t()} | {:error, term()}
  def start_run(state, attrs) when is_map(attrs) do
    with :ok <- ensure_no_open_run(state),
         {:ok, run} <-
           Run.new(attrs |> Map.put(:agent_id, state.agent_id) |> Map.put(:kind, state.kind)) do
      {:ok, put_run(%__MODULE__{state | current_run_id: run.id}, run)}
    end
  end

  @spec start_new_run(t(), map()) :: {:ok, t()} | {:error, term()}
  def start_new_run(state, attrs) when is_map(attrs) do
    with {:ok, state} <- supersede_open_run(state, attrs),
         {:ok, state} <- start_run(state, attrs) do
      begin_attempt(state, attrs)
    end
  end

  @spec begin_attempt(t(), map()) :: {:ok, t()} | {:error, term()}
  def begin_attempt(state, attrs) when is_map(attrs) do
    with {:ok, run} <- fetch_current_run(state),
         {:ok, attempt_id} <- fetch(attrs, :attempt_id),
         {:ok, instance_id} <- fetch(attrs, :instance_id),
         {:ok, run} <- Run.begin_attempt(run, attrs |> Map.put(:id, attempt_id)),
         {:ok, instance} <-
           Instance.new(%{
             id: instance_id,
             agent_id: state.agent_id,
             run_id: run.id,
             attempt_id: attempt_id,
             started_at: Map.get(attrs, :started_at),
             metadata: Map.get(attrs, :metadata, %{})
           }) do
      {:ok,
       state
       |> put_run(run)
       |> put_instance(instance)}
    end
  end

  @spec start_attempt(t(), map()) :: {:ok, t()} | {:error, term()}
  def start_attempt(state, attrs), do: begin_attempt(state, attrs)

  @spec resume(t(), map()) :: {:ok, t()} | {:error, term()}
  def resume(state, attrs) do
    case current_run(state) do
      %Run{status: :interrupted} -> begin_attempt(state, attrs)
      %Run{status: :initializing, attempts: []} -> begin_attempt(state, attrs)
      %Run{status: status} -> {:error, {:not_interrupted, status}}
      nil -> {:error, :no_run}
    end
  end

  @spec ready(t(), term()) :: {:ok, t()} | {:error, term()}
  def ready(state, instance_id) do
    with {:ok, instance} <- fetch_instance(state, instance_id),
         {:ok, instance} <- Instance.ready(instance),
         {:ok, run} <- fetch_run(state, instance.run_id),
         {:ok, run} <- Run.mark_ready(run, instance.attempt_id) do
      {:ok,
       state
       |> put_run(run)
       |> put_instance(instance)}
    end
  end

  @spec wait(t(), term()) :: {:ok, t()} | {:error, term()}
  def wait(state, reason \\ nil) do
    with {:ok, run} <- fetch_current_run(state),
         {:ok, run} <- Run.wait(run, reason) do
      {:ok, put_run(state, run)}
    end
  end

  @spec wake(t()) :: {:ok, t()} | {:error, term()}
  def wake(state) do
    with {:ok, run} <- fetch_current_run(state),
         {:ok, run} <- Run.wake(run) do
      {:ok, put_run(state, run)}
    end
  end

  @spec interrupt(t(), term(), term()) :: {:ok, t()} | {:error, term()}
  def interrupt(state, reason \\ nil, at \\ nil) do
    with {:ok, run} <- fetch_current_run(state),
         attempt = Run.active_attempt(run),
         {:ok, run} <- Run.interrupt(run, reason, at) do
      {:ok,
       state
       |> put_run(run)
       |> stop_attempt_instance(attempt, reason, at)}
    end
  end

  @spec complete(t(), map(), term()) :: {:ok, t()} | {:error, term()}
  def complete(state, result, at \\ nil) do
    finish(state, &Run.complete(&1, result, at), :completed, at)
  end

  @spec fail(t(), term(), term()) :: {:ok, t()} | {:error, term()}
  def fail(state, reason, at \\ nil) do
    finish(state, &Run.fail(&1, reason, at), :failed, at, reason)
  end

  @spec cancel(t(), term(), term()) :: {:ok, t()} | {:error, term()}
  def cancel(state, reason, at \\ nil) do
    finish(state, &Run.cancel(&1, reason, at), :cancelled, at, reason)
  end

  @spec fold_context(t(), map()) :: {:ok, t()} | {:error, term()}
  def fold_context(state, attrs) when is_map(attrs) do
    with {:ok, run} <- fetch_current_run(state),
         {:ok, run} <- Run.fold_context(run, attrs) do
      {:ok, put_run(state, run)}
    end
  end

  defp finish(state, transition, stop_reason, at, instance_reason \\ nil) do
    with {:ok, run} <- fetch_current_run(state),
         attempt = Run.active_attempt(run),
         {:ok, run} <- transition.(run) do
      {:ok,
       state
       |> put_run(run)
       |> stop_attempt_instance(attempt, instance_reason || stop_reason, at)}
    end
  end

  defp stop_attempt_instance(state, nil, _reason, _at), do: state

  defp stop_attempt_instance(state, %Attempt{instance_id: instance_id}, reason, at) do
    with {:ok, instance} <- Map.fetch(state.instances, instance_id),
         {:ok, instance} <- Instance.stop(instance, reason, at) do
      put_instance(state, instance)
    else
      :error -> state
      {:error, _reason} -> state
    end
  end

  defp ensure_no_open_run(state) do
    case current_run(state) do
      nil -> :ok
      %Run{} = run -> if Run.open?(run), do: {:error, {:run_open, run.id}}, else: :ok
    end
  end

  defp supersede_open_run(state, attrs) do
    if open_run?(state) do
      cancel(state, :superseded, Map.get(attrs, :at))
    else
      {:ok, state}
    end
  end

  defp fetch_current_run(state) do
    case current_run(state) do
      nil -> {:error, :no_run}
      run -> {:ok, run}
    end
  end

  defp fetch_run(state, run_id) do
    case Map.fetch(state.runs, run_id) do
      {:ok, run} -> {:ok, run}
      :error -> {:error, {:unknown_run, run_id}}
    end
  end

  defp fetch_instance(state, instance_id) do
    case Map.fetch(state.instances, instance_id) do
      {:ok, instance} -> {:ok, instance}
      :error -> {:error, {:unknown_instance, instance_id}}
    end
  end

  defp put_run(state, run), do: %__MODULE__{state | runs: Map.put(state.runs, run.id, run)}

  defp put_instance(state, instance),
    do: %__MODULE__{state | instances: Map.put(state.instances, instance.id, instance)}

  defp resolve_kind(attrs) do
    case Map.fetch(attrs, :kind) do
      {:ok, kind} ->
        if Run.valid_kind?(kind), do: {:ok, kind}, else: {:error, {:invalid_kind, kind}}

      :error ->
        if Map.get(attrs, :perpetual, false), do: {:ok, :perpetual}, else: {:ok, :one_shot}
    end
  end

  defp fetch(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when not is_nil(value) -> {:ok, value}
      {:ok, nil} -> {:error, {:missing, key}}
      :error -> {:error, {:missing, key}}
    end
  end
end
