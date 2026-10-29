defmodule Patchbay.Run.Context do
  @moduledoc """
  One working-context generation within a run.

  Folding seals the current revision and opens the next revision without
  changing the run's identity or attempts.
  """

  @type fold_reason :: :compaction | :manual_fold

  @type sealed_revision :: %{
          revision: pos_integer(),
          reason: fold_reason(),
          at: term(),
          archive: term()
        }

  @type t :: %__MODULE__{
          revision: pos_integer(),
          sealed: [sealed_revision()],
          folds: non_neg_integer()
        }

  @reason_values [:compaction, :manual_fold]

  defstruct revision: 1, sealed: [], folds: 0

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec current_revision(t()) :: pos_integer()
  def current_revision(%__MODULE__{revision: revision}), do: revision

  @spec sealed_revisions(t()) :: [sealed_revision()]
  def sealed_revisions(%__MODULE__{sealed: sealed}), do: sealed

  @spec fold(t(), map()) :: {:ok, t()} | {:error, term()}
  def fold(%__MODULE__{} = context, attrs) when is_map(attrs) do
    with {:ok, reason} <- fetch_reason(attrs) do
      sealed = %{
        revision: context.revision,
        reason: reason,
        at: Map.get(attrs, :at),
        archive: Map.get(attrs, :archive)
      }

      {:ok,
       %__MODULE__{
         context
         | revision: context.revision + 1,
           sealed: context.sealed ++ [sealed],
           folds: context.folds + 1
       }}
    end
  end

  @spec valid_reason?(term()) :: boolean()
  def valid_reason?(reason), do: reason in @reason_values

  defp fetch_reason(attrs) do
    case Map.get(attrs, :reason, :compaction) do
      reason when reason in @reason_values -> {:ok, reason}
      reason -> {:error, {:invalid_reason, reason}}
    end
  end
end

defmodule Patchbay.Run.Attempt do
  @moduledoc """
  One agent instance's effort to advance a run.

  An interruption ends an attempt. Resuming or restarting a run creates a new
  attempt; it does not create a new run.
  """

  @type status :: :active | :interrupted | :completed | :failed | :cancelled

  @type t :: %__MODULE__{
          id: term(),
          run_id: term(),
          instance_id: term(),
          ordinal: pos_integer(),
          status: status(),
          started_at: term(),
          ended_at: term(),
          reason: term()
        }

  @terminal_statuses [:interrupted, :completed, :failed, :cancelled]

  defstruct [
    :id,
    :run_id,
    :instance_id,
    :started_at,
    :ended_at,
    :reason,
    ordinal: 1,
    status: :active
  ]

  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, id} <- fetch(attrs, :id),
         {:ok, run_id} <- fetch(attrs, :run_id),
         {:ok, instance_id} <- fetch(attrs, :instance_id) do
      {:ok,
       %__MODULE__{
         id: id,
         run_id: run_id,
         instance_id: instance_id,
         ordinal: Map.get(attrs, :ordinal, 1),
         started_at: Map.get(attrs, :started_at)
       }}
    end
  end

  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{status: :active}), do: true
  def active?(%__MODULE__{}), do: false

  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{status: status}), do: status in @terminal_statuses

  @spec interrupt(t(), term(), term()) :: {:ok, t()} | {:error, term()}
  def interrupt(%__MODULE__{} = attempt, reason \\ nil, at \\ nil),
    do: finish(attempt, :interrupted, reason, at)

  @spec complete(t(), term()) :: {:ok, t()} | {:error, term()}
  def complete(%__MODULE__{} = attempt, at \\ nil),
    do: finish(attempt, :completed, nil, at)

  @spec fail(t(), term(), term()) :: {:ok, t()} | {:error, term()}
  def fail(%__MODULE__{} = attempt, reason \\ nil, at \\ nil),
    do: finish(attempt, :failed, reason, at)

  @spec cancel(t(), term(), term()) :: {:ok, t()} | {:error, term()}
  def cancel(%__MODULE__{} = attempt, reason \\ nil, at \\ nil),
    do: finish(attempt, :cancelled, reason, at)

  @spec finish(t(), status(), term(), term()) :: {:ok, t()} | {:error, term()}
  def finish(%__MODULE__{status: :active} = attempt, status, reason, at)
      when status in @terminal_statuses do
    {:ok, %__MODULE__{attempt | status: status, reason: reason, ended_at: at}}
  end

  def finish(%__MODULE__{}, _status, _reason, _at), do: {:error, :inactive_attempt}

  defp fetch(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when not is_nil(value) -> {:ok, value}
      {:ok, nil} -> {:error, {:missing, key}}
      :error -> {:error, {:missing, key}}
    end
  end
end

defmodule Patchbay.Run do
  @moduledoc """
  Logical unit of work from initialization through a terminal result.

  A run can span several attempts when work is interrupted and resumed.
  Context folding and compaction change the context revision inside the run.
  """

  alias Patchbay.Run.{Attempt, Context}

  @type id :: term()
  @type kind :: :one_shot | :scheduled | :perpetual
  @type status ::
          :initializing
          | :running
          | :waiting
          | :interrupted
          | :completed
          | :failed
          | :cancelled
  @type terminal_status :: :completed | :failed | :cancelled

  @type t :: %__MODULE__{
          id: id(),
          agent_id: term(),
          definition_revision: term(),
          toolkit_ids: [term()],
          kind: kind(),
          status: status(),
          attempts: [Attempt.t()],
          context: Context.t(),
          result: map() | nil,
          failure: term(),
          cancellation: term(),
          wait_reason: term(),
          started_at: term(),
          ended_at: term(),
          metadata: map()
        }

  @kinds [:one_shot, :scheduled, :perpetual]
  @open_statuses [:initializing, :running, :waiting, :interrupted]

  defstruct [
    :id,
    :agent_id,
    :definition_revision,
    :started_at,
    :ended_at,
    :result,
    :failure,
    :cancellation,
    :wait_reason,
    kind: :one_shot,
    status: :initializing,
    attempts: [],
    context: %Context{},
    toolkit_ids: [],
    metadata: %{}
  ]

  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, id} <- fetch(attrs, :id),
         {:ok, agent_id} <- fetch(attrs, :agent_id),
         {:ok, kind} <- resolve_kind(attrs) do
      {:ok,
       %__MODULE__{
         id: id,
         agent_id: agent_id,
         definition_revision: Map.get(attrs, :definition_revision),
         toolkit_ids: Map.get(attrs, :toolkit_ids, []),
         kind: kind,
         context: Map.get(attrs, :context, Context.new()),
         started_at: Map.get(attrs, :started_at),
         metadata: Map.get(attrs, :metadata, %{})
       }}
    end
  end

  @spec valid_kind?(term()) :: boolean()
  def valid_kind?(kind), do: kind in @kinds

  @spec kind(t()) :: kind()
  def kind(%__MODULE__{kind: kind}), do: kind

  @spec perpetual?(t()) :: boolean()
  def perpetual?(%__MODULE__{kind: :perpetual}), do: true
  def perpetual?(%__MODULE__{}), do: false

  @spec open?(t()) :: boolean()
  def open?(%__MODULE__{status: status}), do: status in @open_statuses

  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{status: status}), do: status in [:completed, :failed, :cancelled]

  @spec begin_attempt(t(), map()) :: {:ok, t()} | {:error, term()}
  def begin_attempt(%__MODULE__{} = run, attrs) when is_map(attrs) do
    cond do
      terminal?(run) -> {:error, :terminal}
      active_attempt(run) != nil -> {:error, :attempt_active}
      run.status == :running -> {:error, {:invalid_status, run.status}}
      true -> add_attempt(run, attrs)
    end
  end

  @spec start_attempt(t(), map()) :: {:ok, t()} | {:error, term()}
  def start_attempt(%__MODULE__{} = run, attrs), do: begin_attempt(run, attrs)

  @spec resume(t(), map()) :: {:ok, t()} | {:error, term()}
  def resume(%__MODULE__{status: :interrupted} = run, attrs), do: begin_attempt(run, attrs)
  def resume(%__MODULE__{status: status}, _attrs), do: {:error, {:not_interrupted, status}}

  @spec mark_ready(t(), term()) :: {:ok, t()} | {:error, term()}
  def mark_ready(%__MODULE__{} = run, attempt_id) do
    case active_attempt(run) do
      %Attempt{id: ^attempt_id} -> {:ok, %__MODULE__{run | status: :running}}
      %Attempt{id: other} -> {:error, {:attempt_mismatch, other}}
      nil -> {:error, :no_active_attempt}
    end
  end

  @spec wait(t(), term()) :: {:ok, t()} | {:error, term()}
  def wait(%__MODULE__{} = run, reason \\ nil) do
    with :ok <- ensure_running(run, :wait),
         {:ok, _attempt} <- fetch_active_attempt(run) do
      {:ok, %__MODULE__{run | status: :waiting, wait_reason: reason}}
    end
  end

  @spec wake(t()) :: {:ok, t()} | {:error, term()}
  def wake(%__MODULE__{status: :waiting} = run) do
    with {:ok, _attempt} <- fetch_active_attempt(run) do
      {:ok, %__MODULE__{run | status: :running, wait_reason: nil}}
    end
  end

  def wake(%__MODULE__{status: status}), do: {:error, {:invalid_status, status}}

  @spec interrupt(t(), term(), term()) :: {:ok, t()} | {:error, term()}
  def interrupt(%__MODULE__{} = run, reason \\ nil, at \\ nil) do
    with :ok <- ensure_open(run),
         {:ok, attempt} <- fetch_active_attempt(run),
         {:ok, attempt} <- Attempt.interrupt(attempt, reason, at) do
      {:ok,
       %__MODULE__{
         run
         | status: :interrupted,
           wait_reason: nil,
           attempts: replace_attempt(run.attempts, attempt)
       }}
    end
  end

  @spec complete(t(), map(), term()) :: {:ok, t()} | {:error, term()}
  def complete(%__MODULE__{} = run, result, at \\ nil) do
    with :ok <- ensure_open(run) do
      if is_map(result) do
        finish(run, :completed, at, %{result: result})
      else
        {:error, {:invalid_result, result}}
      end
    end
  end

  @spec fail(t(), term(), term()) :: {:ok, t()} | {:error, term()}
  def fail(%__MODULE__{} = run, reason, at \\ nil) do
    with :ok <- ensure_open(run) do
      finish(run, :failed, at, %{failure: reason})
    end
  end

  @spec cancel(t(), term(), term()) :: {:ok, t()} | {:error, term()}
  def cancel(%__MODULE__{} = run, reason, at \\ nil) do
    with :ok <- ensure_open(run) do
      finish(run, :cancelled, at, %{cancellation: reason})
    end
  end

  @spec fold_context(t(), map()) :: {:ok, t()} | {:error, term()}
  def fold_context(%__MODULE__{} = run, attrs) when is_map(attrs) do
    with :ok <- ensure_open(run),
         {:ok, context} <- Context.fold(run.context, attrs) do
      {:ok, %__MODULE__{run | context: context}}
    end
  end

  @spec context_revision(t()) :: pos_integer()
  def context_revision(%__MODULE__{context: context}), do: Context.current_revision(context)

  @spec active_attempt(t()) :: Attempt.t() | nil
  def active_attempt(%__MODULE__{attempts: attempts}) do
    Enum.find(attempts, &Attempt.active?/1)
  end

  @spec attempt_count(t()) :: non_neg_integer()
  def attempt_count(%__MODULE__{attempts: attempts}), do: length(attempts)

  @spec current_attempt(t()) :: Attempt.t() | nil
  def current_attempt(%__MODULE__{attempts: []}), do: nil
  def current_attempt(%__MODULE__{attempts: attempts}), do: List.last(attempts)

  defp add_attempt(run, attrs) do
    attempt_attrs =
      attrs
      |> Map.put(:run_id, run.id)
      |> Map.put(:ordinal, length(run.attempts) + 1)

    with {:ok, attempt} <- Attempt.new(attempt_attrs) do
      {:ok,
       %__MODULE__{
         run
         | attempts: run.attempts ++ [attempt],
           status: :initializing
       }}
    end
  end

  defp finish(run, status, at, values) do
    reason = Map.get(values, :failure) || Map.get(values, :cancellation)

    attempts =
      case active_attempt(run) do
        nil ->
          run.attempts

        attempt ->
          {:ok, attempt} = Attempt.finish(attempt, status, reason, at)
          replace_attempt(run.attempts, attempt)
      end

    {:ok,
     struct!(
       %__MODULE__{
         run
         | status: status,
           attempts: attempts,
           ended_at: at,
           wait_reason: nil
       },
       values
     )}
  end

  defp replace_attempt(attempts, replacement) do
    Enum.map(attempts, fn
      %Attempt{id: id} when id == replacement.id -> replacement
      attempt -> attempt
    end)
  end

  defp fetch_active_attempt(run) do
    case active_attempt(run) do
      nil -> {:error, :no_active_attempt}
      attempt -> {:ok, attempt}
    end
  end

  defp ensure_open(%__MODULE__{status: status}) when status in @open_statuses, do: :ok
  defp ensure_open(%__MODULE__{}), do: {:error, :terminal}

  defp ensure_running(%__MODULE__{status: :running}, _transition), do: :ok

  defp ensure_running(%__MODULE__{status: status}, transition),
    do: {:error, {:invalid_status, status, transition}}

  defp resolve_kind(attrs) do
    case Map.fetch(attrs, :kind) do
      {:ok, kind} when kind in @kinds ->
        {:ok, kind}

      {:ok, kind} ->
        {:error, {:invalid_kind, kind}}

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
