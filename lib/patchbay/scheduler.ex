defmodule Patchbay.Scheduler do
  @moduledoc """
  Durable scheduler for definitions with a `scheduled` lifecycle.

  The scheduler reads definitions from a definition source, tracks the next
  occurrence of each five-field cron schedule, and starts due agents through
  the runtime. Only `scheduled` lifecycles are considered; one-shot and
  perpetual definitions are ignored.

  Per-agent `last_fire` and `next_fire` values are kept in `scheduler.json`
  under the configured state directory. The file is replaced atomically after
  each tick and before each dispatch; an occurrence claimed before dispatch is
  kept claimed when the start fails, so a restart does not repeat side effects.
  """

  use GenServer

  require Logger

  alias Patchbay.Config
  alias Patchbay.Scheduler.Cron

  @default_interval 30_000
  @state_file "scheduler.json"
  @active_statuses [:starting, :running, :stopping]
  @max_catch_up 100

  @type server :: GenServer.server()
  @type entry :: %{
          schedule: String.t(),
          last_fire: non_neg_integer() | nil,
          next_fire: non_neg_integer() | nil
        }
  @type report :: %{
          fired: [map()],
          skipped: [map()],
          failed: [map()],
          invalid: [map()],
          error: term() | nil,
          persisted: :ok | :unchanged | {:error, term()}
        }

  @doc false
  def start_link(opts \\ []) do
    {name, init_opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.get(opts, :name, __MODULE__)},
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @doc """
  Processes all due schedules now and returns a report.
  """
  @spec tick(server()) :: report()
  def tick(server \\ __MODULE__), do: GenServer.call(server, :tick, :infinity)

  @doc """
  Returns the currently tracked entries keyed by agent ID.
  """
  @spec entries(server()) :: %{optional(String.t()) => entry()}
  def entries(server \\ __MODULE__), do: GenServer.call(server, :entries)

  @doc """
  Returns the persisted next fire time for an agent.
  """
  @spec next_fire(server(), String.t()) :: {:ok, non_neg_integer() | nil} | {:error, :not_found}
  def next_fire(server \\ __MODULE__, id) when is_binary(id), do: lookup(server, id, :next_fire)

  @doc """
  Returns the persisted last fire time for an agent.
  """
  @spec last_fire(server(), String.t()) :: {:ok, non_neg_integer() | nil} | {:error, :not_found}
  def last_fire(server \\ __MODULE__, id) when is_binary(id), do: lookup(server, id, :last_fire)

  @doc """
  Returns the report from the most recent tick.
  """
  @spec last_report(server()) :: report() | nil
  def last_report(server \\ __MODULE__), do: GenServer.call(server, :last_report)

  defp lookup(server, id, key) do
    case GenServer.call(server, {:entry, id}) do
      {:ok, entry} -> {:ok, Map.get(entry, key)}
      {:error, :not_found} = error -> error
    end
  end

  @impl true
  def init(opts) do
    with {:ok, state_dir} <- resolve_state_dir(opts),
         :ok <- File.mkdir_p(state_dir) do
      clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)

      state = %{
        definitions: source(Keyword.get(opts, :definitions), Patchbay.DefinitionRegistry),
        runtime: source(Keyword.get(opts, :runtime), Patchbay.Runtime),
        state_dir: state_dir,
        state_file: Path.join(state_dir, @state_file),
        clock: clock,
        tick_interval: tick_interval(opts),
        timer_ref: nil,
        start_opts: Keyword.get(opts, :start_opts, []),
        entries: load_entries(Path.join(state_dir, @state_file)),
        last_report: nil
      }

      {entries, invalid} =
        case fetch_definitions(state) do
          {:ok, definitions} ->
            reconcile(state.entries, definitions, now_datetime(clock))

          {:error, reason} ->
            Logger.warning("scheduler could not load definitions at startup: #{inspect(reason)}")
            {state.entries, []}
        end

      state = %{state | entries: entries}
      log_invalid(invalid)
      persist_state(state)

      {:ok, schedule_tick(state)}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:tick, _from, state) do
    {report, state} = run_tick(state)
    {:reply, report, state}
  end

  def handle_call(:entries, _from, state), do: {:reply, state.entries, state}

  def handle_call({:entry, id}, _from, state) do
    case Map.fetch(state.entries, id) do
      {:ok, entry} -> {:reply, {:ok, entry}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:last_report, _from, state), do: {:reply, state.last_report, state}

  @impl true
  def handle_info(:tick, state) do
    {report, state} = run_tick(%{state | timer_ref: nil})
    {:noreply, schedule_tick(%{state | last_report: report})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp run_tick(state) do
    now = now_datetime(state.clock)

    case fetch_definitions(state) do
      {:ok, definitions} ->
        definitions_by_id = Map.new(definitions, &{&1.id, &1})
        {entries, invalid} = reconcile(state.entries, definitions, now)
        now_unix = DateTime.to_unix(now, :second)

        {entries, report, state} =
          entries
          |> Enum.sort_by(fn {id, _entry} -> id end)
          |> Enum.reduce({entries, empty_report(), %{state | entries: entries}}, fn
            {id, _entry}, {entries, report, state} ->
              case Map.fetch(definitions_by_id, id) do
                {:ok, definition} ->
                  entry = Map.fetch!(state.entries, id)
                  {entry, result, state} = process_entry(entry, definition, state, now, now_unix)
                  entries = Map.put(entries, id, entry)
                  {entries, merge_report(report, result), %{state | entries: entries}}

                :error ->
                  {entries, report, state}
              end
          end)

        state = %{state | entries: entries}
        persisted = persist_state(state)

        report = %{
          report
          | invalid: invalid,
            persisted: persisted
        }

        {report, %{state | last_report: report}}

      {:error, reason} ->
        report = %{empty_report() | error: reason, persisted: :unchanged}
        {report, %{state | last_report: report}}
    end
  end

  defp process_entry(entry, definition, state, now, now_unix) do
    if is_integer(entry.next_fire) and entry.next_fire <= now_unix do
      case Cron.parse(entry.schedule) do
        {:ok, cron} ->
          next_fire = next_fire_unix(cron, now)
          attempts = due_attempts(cron, entry.next_fire, now, now_unix, definition)
          initial = %{entry | next_fire: next_fire}

          if attempts == [] do
            skipped = %{
              empty_result()
              | skipped: [%{agent_id: definition.id, reason: :catch_up}]
            }

            {initial, skipped, state}
          else
            Enum.reduce(attempts, {initial, empty_result(), state}, fn
              _occurrence, {entry, result, state} ->
                {_fired?, attempt_result, state, entry} =
                  attempt(definition, state, entry, now_unix)

                {entry, merge_result(result, attempt_result), state}
            end)
          end

        {:error, reason} ->
          {entry, %{empty_result() | invalid: [%{agent_id: definition.id, reason: reason}]},
           state}
      end
    else
      {entry, empty_result(), state}
    end
  end

  defp due_attempts(cron, next_fire, now, now_unix, definition) do
    due = DateTime.from_unix!(next_fire)

    case Cron.next_after(cron, due) do
      {:ok, following} ->
        if DateTime.to_unix(following, :second) > now_unix do
          [due]
        else
          case definition.lifecycle.catch_up || :none do
            :none -> []
            :once -> [due]
            :all -> occurrences(cron, due, now)
          end
        end

      {:error, _reason} ->
        [due]
    end
  end

  defp occurrences(cron, cursor, now, acc \\ []) do
    cond do
      length(acc) >= @max_catch_up ->
        Enum.reverse(acc)

      DateTime.compare(cursor, now) == :gt ->
        Enum.reverse(acc)

      true ->
        case Cron.next_after(cron, cursor) do
          {:ok, following} -> occurrences(cron, following, now, [cursor | acc])
          {:error, _reason} -> Enum.reverse([cursor | acc])
        end
    end
  end

  defp attempt(definition, state, entry, now_unix) do
    if active?(state, definition.id) do
      {false, %{empty_result() | skipped: [%{agent_id: definition.id, reason: :overlap}]}, state,
       entry}
    else
      claimed = %{entry | last_fire: now_unix}

      case persist_claim(state, definition.id, claimed) do
        {:ok, state} ->
          case start_agent(state, definition.id) do
            {:ok, _summary} ->
              {true, %{empty_result() | fired: [%{agent_id: definition.id, at: now_unix}]}, state,
               claimed}

            {:error, {:not_startable, status}} ->
              {false,
               %{
                 empty_result()
                 | skipped: [%{agent_id: definition.id, reason: {:overlap, status}}]
               }, state, claimed}

            {:error, reason} ->
              {false, %{empty_result() | failed: [%{agent_id: definition.id, reason: reason}]},
               state, claimed}
          end

        {:error, reason, state} ->
          {false,
           %{
             empty_result()
             | failed: [%{agent_id: definition.id, reason: {:persist_failed, reason}}]
           }, state, entry}
      end
    end
  end

  defp persist_claim(state, id, entry) do
    claimed = %{state | entries: Map.put(state.entries, id, entry)}

    case persist_state(claimed) do
      :ok -> {:ok, claimed}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp active?(state, id) do
    case runtime_call(state, :get_agent, [id]) do
      {:ok, {:ok, %{status: status}}} when status in @active_statuses -> true
      _other -> false
    end
  end

  defp start_agent(state, id) do
    case runtime_call(state, :start_agent, [id, state.start_opts]) do
      {:ok, {:ok, summary}} -> {:ok, summary}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp runtime_call(state, function, args) do
    {module, server} = state.runtime

    try do
      {:ok, apply(module, function, [server | args])}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp fetch_definitions(state) do
    {module, server} = state.definitions

    result =
      try do
        cond do
          Code.ensure_loaded?(module) and function_exported?(module, :definitions, 1) ->
            apply(module, :definitions, [server])

          Code.ensure_loaded?(module) and function_exported?(module, :list, 1) ->
            apply(module, :list, [server])

          true ->
            {:error, {:invalid_definition_source, module}}
        end
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    normalize_definitions(result)
  end

  defp normalize_definitions({:ok, definitions}) when is_list(definitions) do
    {:ok, Enum.map(definitions, &definition_of/1)}
  end

  defp normalize_definitions(definitions) when is_list(definitions) do
    {:ok, Enum.map(definitions, &definition_of/1)}
  end

  defp normalize_definitions({:error, reason}), do: {:error, reason}
  defp normalize_definitions(other), do: {:error, {:invalid_definitions, other}}

  defp definition_of(%{definition: %{} = definition}), do: definition
  defp definition_of(definition), do: definition

  defp reconcile(existing, definitions, now) do
    {entries, invalid} =
      Enum.reduce(definitions, {%{}, []}, fn definition, {entries, invalid} ->
        if scheduled?(definition) do
          reconcile_definition(definition, existing, entries, invalid, now)
        else
          {entries, invalid}
        end
      end)

    {entries, Enum.reverse(invalid)}
  end

  defp scheduled?(%{id: id, lifecycle: %{kind: :scheduled, schedule: schedule}})
       when is_binary(id) and is_binary(schedule),
       do: true

  defp scheduled?(_definition), do: false

  defp reconcile_definition(definition, existing, entries, invalid, now) do
    id = definition.id
    schedule = definition.lifecycle.schedule

    case Cron.parse(schedule) do
      {:ok, cron} ->
        case next_fire_unix(cron, now) do
          next_fire when is_integer(next_fire) ->
            entry = reconcile_entry(Map.get(existing, id), schedule, next_fire)
            {Map.put(entries, id, entry), invalid}

          _other ->
            {entries, [%{agent_id: id, reason: :no_occurrence} | invalid]}
        end

      {:error, reason} ->
        {entries, [%{agent_id: id, reason: {:invalid_schedule, reason}} | invalid]}
    end
  end

  defp reconcile_entry(%{schedule: schedule, next_fire: next_fire} = entry, schedule, _new_next)
       when is_integer(next_fire),
       do: entry

  defp reconcile_entry(existing, schedule, next_fire) do
    %{
      schedule: schedule,
      last_fire: existing && Map.get(existing, :last_fire),
      next_fire: next_fire
    }
  end

  defp next_fire_unix(cron, now) do
    case Cron.next_after(cron, now) do
      {:ok, datetime} -> DateTime.to_unix(datetime, :second)
      {:error, _reason} -> nil
    end
  end

  defp merge_report(report, result) do
    %{
      report
      | fired: report.fired ++ result.fired,
        skipped: report.skipped ++ result.skipped,
        failed: report.failed ++ result.failed,
        invalid: report.invalid ++ result.invalid
    }
  end

  defp merge_result(result, other) do
    %{
      fired: result.fired ++ other.fired,
      skipped: result.skipped ++ other.skipped,
      failed: result.failed ++ other.failed,
      invalid: result.invalid ++ other.invalid
    }
  end

  defp empty_result, do: %{fired: [], skipped: [], failed: [], invalid: []}

  defp empty_report do
    %{fired: [], skipped: [], failed: [], invalid: [], error: nil, persisted: :ok}
  end

  defp schedule_tick(%{tick_interval: interval} = state)
       when is_integer(interval) and interval > 0 do
    %{state | timer_ref: Process.send_after(self(), :tick, interval)}
  end

  defp schedule_tick(state), do: state

  defp tick_interval(opts) do
    if Keyword.get(opts, :auto_tick, true) do
      case Keyword.get(opts, :tick_interval, @default_interval) do
        interval when is_integer(interval) and interval > 0 -> interval
        _other -> nil
      end
    else
      nil
    end
  end

  defp source(nil, default), do: source(default, default)
  defp source({module, server}, _default), do: {module, server}
  defp source(module, _default) when is_atom(module), do: {module, module}
  defp source(other, _default), do: raise(ArgumentError, "invalid source: #{inspect(other)}")

  defp resolve_state_dir(opts) do
    config = Config.load(Keyword.take(opts, [:state_dir, :env]))

    if is_binary(config.state_dir) and config.state_dir != "" do
      {:ok, Path.expand(config.state_dir)}
    else
      {:error, {:invalid_state_dir, config.state_dir}}
    end
  end

  defp now_datetime(clock) do
    case clock.() do
      %DateTime{} = datetime ->
        datetime

      unix when is_integer(unix) and unix >= 0 ->
        DateTime.from_unix!(unix)

      other ->
        raise ArgumentError,
              "clock must return a DateTime or Unix seconds, got: #{inspect(other)}"
    end
  end

  defp load_entries(path) do
    case File.read(path) do
      {:ok, body} ->
        decode_entries(body, path)

      {:error, :enoent} ->
        %{}

      {:error, reason} ->
        Logger.warning("scheduler could not read #{path}: #{inspect(reason)}")
        %{}
    end
  end

  defp decode_entries(body, path) do
    case Jason.decode(body) do
      {:ok, %{"entries" => entries}} when is_map(entries) ->
        Enum.reduce(entries, %{}, fn {id, raw}, acc ->
          case normalize_entry(raw) do
            {:ok, entry} -> Map.put(acc, id, entry)
            :error -> acc
          end
        end)

      {:ok, _other} ->
        Logger.warning("scheduler ignored an unrecognized state file at #{path}")
        %{}

      {:error, reason} ->
        Logger.warning("scheduler ignored invalid JSON at #{path}: #{inspect(reason)}")
        %{}
    end
  end

  defp normalize_entry(%{"schedule" => schedule, "next_fire" => next_fire} = raw)
       when is_binary(schedule) and is_integer(next_fire) do
    case Map.get(raw, "last_fire") do
      nil ->
        {:ok, %{schedule: schedule, last_fire: nil, next_fire: next_fire}}

      last_fire when is_integer(last_fire) ->
        {:ok, %{schedule: schedule, last_fire: last_fire, next_fire: next_fire}}

      _other ->
        :error
    end
  end

  defp normalize_entry(_raw), do: :error

  defp persist_state(state) do
    payload = %{
      "version" => 1,
      "entries" => Map.new(state.entries, fn {id, entry} -> {id, serialize_entry(entry)} end)
    }

    temporary = state.state_file <> ".tmp"

    with :ok <- File.mkdir_p(state.state_dir),
         {:ok, body} <- Jason.encode(payload),
         :ok <- File.write(temporary, body),
         :ok <- File.rename(temporary, state.state_file) do
      :ok
    else
      {:error, reason} = error ->
        Logger.warning("scheduler could not persist #{state.state_file}: #{inspect(reason)}")
        error
    end
  end

  defp serialize_entry(entry) do
    %{
      "schedule" => entry.schedule,
      "last_fire" => entry.last_fire,
      "next_fire" => entry.next_fire
    }
  end

  defp log_invalid([]), do: :ok

  defp log_invalid(invalid) do
    Enum.each(invalid, fn %{agent_id: id, reason: reason} ->
      Logger.warning("scheduler ignored #{id}: #{inspect(reason)}")
    end)
  end
end
