defmodule PatchbayWeb.Presenter do
  @moduledoc false

  alias Patchbay.Event
  alias Patchbay.ToolHistory

  @filters [
    {"all", "ALL"},
    {"live", "LIVE"},
    {"wait", "WAIT"},
    {"idle", "IDLE"},
    {"fail", "FAIL"}
  ]

  def filters, do: @filters

  def status_label(:running), do: "RUNNING"
  def status_label(:starting), do: "STARTING"
  def status_label(:stopping), do: "STOPPING"
  def status_label(:failed), do: "FAILED"
  def status_label(:stopped), do: "IDLE"
  def status_label(_status), do: "UNKNOWN"

  def status_lamp(:running), do: "live"
  def status_lamp(:starting), do: "warn"
  def status_lamp(:stopping), do: "warn"
  def status_lamp(:failed), do: "fail"
  def status_lamp(_status), do: "idle"

  def lifecycle_label(:one_shot), do: "ONE-SHOT"
  def lifecycle_label(:scheduled), do: "SCHEDULED"
  def lifecycle_label(:perpetual), do: "PERPETUAL"
  def lifecycle_label(kind) when is_binary(kind), do: lifecycle_label(lifecycle_atom(kind))
  def lifecycle_label(_kind), do: "UNKNOWN"

  def agent_sub(summary, definition) do
    kind = summary[:lifecycle_kind]

    case kind do
      :scheduled ->
        schedule =
          case definition do
            %{lifecycle: %{schedule: schedule}} when is_binary(schedule) -> schedule
            _definition -> nil
          end

        join([lifecycle_label(kind), schedule])

      _kind ->
        case summary[:attempt_ordinal] do
          nil -> lifecycle_label(kind)
          ordinal -> "#{lifecycle_label(kind)} · ATT #{ordinal}"
        end
    end
  end

  def match_filter?("all", _agent), do: true
  def match_filter?("live", %{status: :running}), do: true
  def match_filter?("wait", %{status: status}) when status in [:starting, :stopping], do: true
  def match_filter?("idle", %{status: :stopped}), do: true
  def match_filter?("fail", %{status: :failed}), do: true
  def match_filter?(_filter, _agent), do: false

  def filter_count(agents, filter), do: Enum.count(agents, &match_filter?(filter, &1))

  def last_action([]), do: {"—", nil}

  def last_action(events) do
    event = List.last(events)

    label =
      case event.type do
        :tool_call -> data_text(event.data, "tool_name", "tool")
        :tool_result -> data_text(event.data, "tool_name", "tool")
        type -> type |> Atom.to_string() |> String.upcase()
      end

    tone =
      case event.type do
        :agent_start_failed -> "err"
        :agent_stop_failed -> "err"
        :tool_result -> if data_text(event.data, "status", "") == "error", do: "err", else: "now"
        _type -> "now"
      end

    {label, tone}
  end

  def trace_class(:running), do: "trace-live"
  def trace_class(:starting), do: "trace-warn"
  def trace_class(:stopping), do: "trace-warn"
  def trace_class(:failed), do: "trace-fail"
  def trace_class(_status), do: "trace-idle"

  def trace_points([]), do: "0,16 76,16"

  def trace_points(events) do
    events = Enum.take(events, -20)
    total = length(events)
    last = max(total - 1, 1)

    events
    |> Enum.with_index()
    |> Enum.map_join(" ", fn {_event, index} ->
      x = round(index * 76 / last)
      y = 15 - round(index * 11 / last)
      "#{x},#{y}"
    end)
  end

  def context_count(nil), do: {0, "no definition loaded"}

  def context_count(%{context: nil}), do: {0, "no context policy"}

  def context_count(%{context: context}) do
    values = [
      {"between-runs", context.between_runs},
      {"prior-runs", context.prior_runs},
      {"restore-interrupted", context.restore_interrupted}
    ]

    count = Enum.count(values, fn {_key, value} -> is_binary(value) end)
    title = Enum.map_join(values, " · ", fn {key, value} -> "#{key}: #{value || "—"}" end)
    {count, title}
  end

  def budget_label(nil), do: "—"
  def budget_label(%{budgets: %{tokens: nil}}), do: "—"
  def budget_label(%{budgets: %{tokens: tokens}}) when is_integer(tokens), do: compact(tokens)
  def budget_label(_definition), do: "—"

  def short_run_id(nil), do: "—"

  def short_run_id(run_id) when is_binary(run_id) do
    if String.length(run_id) <= 5, do: "#" <> run_id, else: "#" <> String.slice(run_id, -4, 4)
  end

  def run_state(nil), do: "—"
  def run_state(status) when is_atom(status), do: status |> Atom.to_string() |> String.upcase()
  def run_state(status) when is_binary(status), do: String.upcase(status)

  def elapsed(%{started_at: nil}, _now), do: "—"

  def elapsed(summary, now) do
    with {:ok, started, _offset} <- DateTime.from_iso8601(summary.started_at) do
      ended =
        case summary.stopped_at do
          nil -> now
          value -> parse_datetime(value, now)
        end

      format_seconds(max(DateTime.diff(ended, started), 0))
    else
      _error -> "—"
    end
  end

  def state_sub(%{status: status} = summary, now) when status in [:running, :starting] do
    elapsed(summary, now)
  end

  def state_sub(%{stopped_at: stopped_at}, _now) when is_binary(stopped_at) do
    "SINCE " <> clock(stopped_at)
  end

  def state_sub(_summary, _now), do: "—"

  def event_time(%Event{at: at}), do: clock(at)
  def event_time(%ToolHistory{timestamp: timestamp}), do: clock(timestamp)

  def event_label(:run_started), do: "RUN STARTED"
  def event_label(:run_resumed), do: "RUN RESUMED"
  def event_label(:attempt_started), do: "ATTEMPT STARTED"
  def event_label(:instance_ready), do: "INSTANCE READY"
  def event_label(:agent_started), do: "AGENT STARTED"
  def event_label(:agent_start_failed), do: "START FAILED"
  def event_label(:agent_stopped), do: "AGENT STOPPED"
  def event_label(:agent_stop_failed), do: "STOP FAILED"
  def event_label(:tool_call), do: "TOOL CALL"
  def event_label(:tool_result), do: "TOOL RESULT"
  def event_label(:user_message), do: "OPERATOR"
  def event_label(:model_message), do: "AGENT"
  def event_label(:model_tool_call), do: "MODEL TOOL CALL"
  def event_label(:context_compacted), do: "CONTEXT COMPACTED"
  def event_label(:agent_waiting), do: "WAITING"
  def event_label(:agent_woken), do: "WOKEN"
  def event_label(:run_completed), do: "RUN COMPLETED"
  def event_label(:run_failed), do: "RUN FAILED"
  def event_label(type), do: type |> Atom.to_string() |> String.upcase()

  def activity_label(:idle), do: "IDLE"
  def activity_label(:thinking), do: "THINKING"
  def activity_label(:executing_tool), do: "TOOL"
  def activity_label(:waiting), do: "WAITING"
  def activity_label(_activity), do: "IDLE"

  def event_summary(event) do
    data = event.data

    detail =
      case event.type do
        :run_started ->
          join([data_text(data, "kind", nil)])

        :run_resumed ->
          join([data_text(data, "kind", nil)])

        :attempt_started ->
          join([
            "ORDINAL " <> data_text(data, "ordinal", "—"),
            "WORKER " <> data_text(data, "worker_id", "—")
          ])

        :instance_ready ->
          "INSTANCE " <> data_text(data, "instance_id", "—")

        :agent_started ->
          "WORKER " <> data_text(data, "worker_id", "—")

        :agent_start_failed ->
          join([
            "STAGE " <> data_text(data, "stage", "—"),
            data_text(data, "reason", "")
          ])

        :agent_stopped ->
          "REASON " <> data_text(data, "reason", "—")

        :agent_stop_failed ->
          "REASON " <> data_text(data, "reason", "—")

        :tool_call ->
          join([
            data_text(data, "tool_name", "tool"),
            data_text(data, "arguments", "")
          ])

        :tool_result ->
          join([
            data_text(data, "tool_name", "tool"),
            data_text(data, "status", "")
          ])

        :user_message ->
          truncate(data_text(data, "content", ""), 180)

        :model_message ->
          join([
            truncate(data_text(data, "content", ""), 180),
            finish_reason(data),
            tool_count(data)
          ])

        :model_tool_call ->
          join([
            data_text(data, "tool_name", "tool"),
            data_text(data, "arguments", "")
          ])

        :context_compacted ->
          join([
            "REV " <> data_text(data, "revision", "—"),
            "DROPPED " <> data_text(data, "dropped_messages", "—"),
            "ARCHIVE " <> data_text(data, "archive_generation", "—")
          ])

        :agent_waiting ->
          "AWAITING INPUT"

        :agent_woken ->
          "OPERATOR MESSAGE"

        :run_completed ->
          "RESULT RECORDED"

        :run_failed ->
          data_text(data, "reason", "")

        _type ->
          ""
      end

    join([event_label(event.type), detail])
  end

  def stream_items(events, history) do
    history_ids = MapSet.new(history, & &1.call_id)

    event_items =
      events
      |> Enum.reject(fn event ->
        event.type in [:tool_call, :tool_result] and
          MapSet.member?(history_ids, tool_event_id(event))
      end)
      |> Enum.map(fn event ->
        %{kind: :event, at: at_ms(event.at), time: event_time(event), text: event_summary(event)}
      end)

    tool_items =
      Enum.map(history, fn record ->
        %{
          kind: :tool,
          at: at_ms(record.timestamp),
          time: event_time(record),
          name: record.tool_name,
          target: truncate(record.arguments, 74),
          toolkit: record.toolkit_id,
          src: String.first(record.toolkit_id || ""),
          status: String.upcase(record.status),
          tone: tool_tone(record.status)
        }
      end)

    (event_items ++ tool_items) |> Enum.sort_by(& &1.at) |> Enum.take(-120)
  end

  def definition_map(nil), do: %{}

  def definition_map(definition) do
    definition
    |> to_plain()
    |> Map.update("prompts", [], fn prompts ->
      Enum.map(prompts, &Map.drop(&1, ["content"]))
    end)
  end

  @secret_segments ~w(secret secrets token tokens password passwords passwd passphrase credential credentials authorization auth bearer key keys apikey)
  @reference_scheme ~r/\A(env|secret|secrets|ref|file|vault|sops|op|keyring|credential):\/?\/?\S+\z/i
  @variable_reference ~r/\A\$[A-Za-z_][A-Za-z0-9_]*\z/
  @quoted_literal ~r/\A("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')(.*)\z/s
  @assignment ~r/\A(\s*(?:#\s*)?)([A-Za-z0-9_.\-]+|"[^"]+"|'[^']+')(\s*=\s*)(.*)\z/
  @inline_assignment ~r/([A-Za-z0-9_.\-]+)(\s*=\s*)("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|[^,}\s\]]+)/

  def redact_source(nil), do: ""

  def redact_source(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> redact_source_lines(nil)
    |> Enum.join("\n")
  end

  def redact_definition(%{__struct__: _module} = value),
    do: value |> Map.from_struct() |> redact_definition()

  def redact_definition(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {key, redact_field(key, nested)} end)
  end

  def redact_definition(value) when is_list(value), do: Enum.map(value, &redact_definition/1)

  def redact_definition(value) when is_tuple(value) do
    value |> Tuple.to_list() |> Enum.map(&redact_definition/1) |> List.to_tuple()
  end

  def redact_definition(value), do: value

  defp redact_source_lines(lines, state) do
    {lines, _state} = Enum.map_reduce(lines, state, &redact_source_line/2)
    lines
  end

  defp redact_source_line(line, {:multiline, delimiter}) do
    if String.contains?(line, delimiter) do
      {"", nil}
    else
      {"", {:multiline, delimiter}}
    end
  end

  defp redact_source_line(line, nil) do
    case Regex.run(@assignment, line) do
      [_, prefix, key, equals, value] ->
        if secret_key?(key) do
          {redacted_assignment(prefix, key, equals, value), multiline_state(value)}
        else
          {redact_inline_assignments(line), nil}
        end

      _no_match ->
        {redact_inline_assignments(line), nil}
    end
  end

  defp redact_inline_assignments(line) do
    Regex.replace(@inline_assignment, line, fn full, key, equals, value ->
      if secret_key?(key) and not reference_value?(value) do
        key <> equals <> "\"[REDACTED]\""
      else
        full
      end
    end)
  end

  defp redacted_assignment(prefix, key, equals, value) do
    prefix <> key <> equals <> redacted_source_value(value)
  end

  defp redacted_source_value(value) do
    trimmed = String.trim_leading(value)

    cond do
      multiline_opening?(value) -> "\"[REDACTED]\""
      String.starts_with?(trimmed, "{") -> redact_inline_assignments(value)
      reference_value?(value) -> value
      true -> "\"[REDACTED]\"" <> trailing_comment(value)
    end
  end

  defp multiline_state(value) do
    case String.trim_leading(value) do
      "\"\"\"" <> rest ->
        if String.contains?(rest, "\"\"\""), do: nil, else: {:multiline, "\"\"\""}

      "'''" <> rest ->
        if String.contains?(rest, "'''"), do: nil, else: {:multiline, "'''"}

      _value ->
        nil
    end
  end

  defp multiline_opening?(value) do
    trimmed = String.trim_leading(value)
    String.starts_with?(trimmed, "\"\"\"") or String.starts_with?(trimmed, "'''")
  end

  defp trailing_comment(value) do
    case Regex.run(@quoted_literal, String.trim_leading(value)) do
      [_, _literal, rest] -> keep_comment(rest)
      _no_match -> value |> String.split(" #", parts: 2) |> comment_tail()
    end
  end

  defp comment_tail([_value, comment]), do: " #" <> comment
  defp comment_tail(_parts), do: ""

  defp keep_comment(rest) do
    case String.trim_leading(rest) do
      "#" -> rest
      _other -> ""
    end
  end

  defp redact_field(_key, value) when value in [nil, ""], do: value

  defp redact_field(key, value) do
    if secret_key?(key) do
      if reference_value?(value), do: value, else: "[REDACTED]"
    else
      redact_definition(value)
    end
  end

  defp secret_key?(key) do
    segments =
      key
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.split("_", trim: true)

    Enum.any?(segments, &(&1 in @secret_segments))
  end

  defp reference_value?(value) when is_binary(value) do
    value = value |> literal_contents() |> String.trim()

    cond do
      value == "" -> false
      String.contains?(value, "${") -> true
      Regex.match?(@variable_reference, value) -> true
      Regex.match?(@reference_scheme, value) -> true
      true -> false
    end
  end

  defp reference_value?(_value), do: false

  defp literal_contents("\"\"\"" <> rest) do
    rest |> String.trim_trailing("\"") |> String.trim_trailing("\"") |> String.trim_trailing("\"")
  end

  defp literal_contents("'''" <> rest) do
    rest |> String.trim_trailing("'") |> String.trim_trailing("'") |> String.trim_trailing("'")
  end

  defp literal_contents("\"" <> rest), do: String.trim_trailing(rest, "\"")
  defp literal_contents("'" <> rest), do: String.trim_trailing(rest, "'")
  defp literal_contents(value), do: value

  def to_plain(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def to_plain(%{__struct__: _module} = value), do: value |> Map.from_struct() |> to_plain()

  def to_plain(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), to_plain(nested)} end)
  end

  def to_plain(value) when is_list(value), do: Enum.map(value, &to_plain/1)
  def to_plain(value) when is_tuple(value), do: value |> Tuple.to_list() |> to_plain()
  def to_plain(value), do: value

  def failure_text(%{errors: errors}) do
    Enum.map_join(errors, "\n", fn issue ->
      "#{format_path(issue.path)}: #{issue.message}"
    end)
  end

  def error_detail(term) when is_binary(term), do: term
  def error_detail(term), do: inspect(term, limit: 8, printable_limit: 400)

  defp tool_event_id(%Event{type: :tool_call} = event), do: event.id

  defp tool_event_id(%Event{data: data}), do: data_text(data, "call_event_id", "")

  defp tool_tone("ok"), do: "is-ok"
  defp tool_tone("error"), do: "is-err"
  defp tool_tone(_status), do: ""

  defp at_ms(%DateTime{} = value), do: DateTime.to_unix(value, :millisecond)

  defp at_ms(value) when is_binary(value) do
    case Integer.parse(value) do
      {milliseconds, ""} ->
        milliseconds

      _other ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :millisecond)
          _error -> 0
        end
    end
  end

  defp at_ms(_value), do: 0

  defp data_text(data, key, default) do
    case Map.get(data, key) do
      nil -> default
      value when is_binary(value) -> value
      value when is_number(value) -> to_string(value)
      value when is_atom(value) -> Atom.to_string(value)
      value -> inspect(value, limit: 6, printable_limit: 300)
    end
  end

  defp finish_reason(data) do
    case data_text(data, "finish_reason", nil) do
      nil -> nil
      finish -> "FINISH " <> finish
    end
  end

  defp tool_count(data) do
    case Map.get(data, "tool_call_count") do
      count when is_integer(count) and count > 0 -> "TOOLS " <> Integer.to_string(count)
      _count -> nil
    end
  end

  defp clock(value) when is_binary(value) do
    case Integer.parse(value) do
      {milliseconds, ""} ->
        case DateTime.from_unix(milliseconds, :millisecond) do
          {:ok, datetime} -> Calendar.strftime(datetime, "%H:%M:%S")
          _error -> "—"
        end

      _other ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> Calendar.strftime(datetime, "%H:%M:%S")
          _error -> "—"
        end
    end
  end

  defp clock(_value), do: "—"

  defp parse_datetime(value, default) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _error -> default
    end
  end

  defp format_seconds(total) do
    hours = div(total, 3600)
    minutes = total |> rem(3600) |> div(60)
    seconds = rem(total, 60)

    Enum.map_join([hours, minutes, seconds], ":", fn part ->
      part |> Integer.to_string() |> String.pad_leading(2, "0")
    end)
  end

  defp compact(number) when number >= 1_000_000, do: "#{Float.round(number / 1_000_000, 1)}M"
  defp compact(number) when number >= 1_000, do: "#{div(number, 1_000)}K"
  defp compact(number), do: Integer.to_string(number)

  defp truncate(nil, _limit), do: "—"

  defp truncate(value, limit) do
    value = to_string(value)

    if String.length(value) > limit do
      String.slice(value, 0, limit) <> "…"
    else
      value
    end
  end

  defp join(values) do
    values
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp lifecycle_atom(kind) do
    case kind do
      "one_shot" -> :one_shot
      "scheduled" -> :scheduled
      "perpetual" -> :perpetual
      _other -> nil
    end
  end

  defp format_path([]), do: "<definition>"

  defp format_path([first | rest]) do
    Enum.reduce(rest, to_string(first), fn
      index, acc when is_integer(index) -> "#{acc}[#{index}]"
      segment, acc -> "#{acc}.#{segment}"
    end)
  end
end
