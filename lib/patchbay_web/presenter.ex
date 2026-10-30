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

  @detail_limit 320
  @tool_detail_limit 160
  @trace_window_ms 180_000

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

  def trace_points(events), do: trace_points(events, DateTime.utc_now())

  def trace_points(events, now) do
    now_ms = at_ms(now)
    cutoff = now_ms - @trace_window_ms

    points =
      events
      |> Enum.map(fn event -> {at_ms(event_at(event)), event_type(event)} end)
      |> Enum.filter(fn {at, _type} -> at > cutoff and at <= now_ms end)
      |> Enum.sort_by(fn {at, _type} -> at end)
      |> Enum.map(fn {at, type} ->
        x = round((at - cutoff) * 76 / @trace_window_ms)
        {x, trace_height(type)}
      end)
      |> Enum.uniq_by(fn {x, _y} -> x end)

    case points do
      [] ->
        "0,16 76,16"

      points ->
        [{0, 16} | points]
        |> Kernel.++([{76, 16}])
        |> Enum.map_join(" ", fn {x, y} -> "#{x},#{y}" end)
    end
  end

  defp trace_height(type)
       when type in [
              :run_failed,
              :agent_failed,
              :agent_start_failed,
              :agent_stop_failed,
              :provider_error,
              :hook_failed
            ],
       do: 5

  defp trace_height(type) when type in [:tool_call, :tool_result, :model_tool_call], do: 8
  defp trace_height(type) when type in [:model_message, :user_message], do: 11
  defp trace_height(_type), do: 14

  defp event_at(%Event{at: at}), do: at
  defp event_at(%{at: at}), do: at
  defp event_at(_event), do: nil

  defp event_type(%Event{type: type}), do: type
  defp event_type(%{type: type}), do: type
  defp event_type(_event), do: nil

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
  def event_label(:provider_error), do: "PROVIDER ERROR"
  def event_label(:agent_failed), do: "AGENT FAILED"
  def event_label(:hook_started), do: "HOOK STARTED"
  def event_label(:hook_finished), do: "HOOK FINISHED"
  def event_label(:hook_failed), do: "HOOK FAILED"
  def event_label(type), do: type |> Atom.to_string() |> String.upcase()

  def activity_label(:idle), do: "IDLE"
  def activity_label(:thinking), do: "THINKING"
  def activity_label(:executing_tool), do: "TOOL"
  def activity_label(:waiting), do: "WAITING"
  def activity_label(_activity), do: "IDLE"

  def event_summary(event) do
    detail = event_detail(event)
    join([event_label(event.type), detail])
  end

  def event_detail(%Event{} = event) do
    data = event.data
    event_detail(event.type, data)
  end

  defp event_detail(:run_started, data), do: join([data_text(data, "kind", nil)])
  defp event_detail(:run_resumed, data), do: join([data_text(data, "kind", nil)])

  defp event_detail(:attempt_started, data) do
    join([
      "ORDINAL " <> full_text(data, "ordinal", "—"),
      "WORKER " <> full_text(data, "worker_id", "—")
    ])
  end

  defp event_detail(:instance_ready, data),
    do: "INSTANCE " <> full_text(data, "instance_id", "—")

  defp event_detail(:agent_started, data), do: "WORKER " <> full_text(data, "worker_id", "—")

  defp event_detail(:agent_start_failed, data) do
    join([
      "STAGE " <> full_text(data, "stage", "—"),
      full_text(data, "reason", "")
    ])
  end

  defp event_detail(:agent_stopped, data), do: "REASON " <> full_text(data, "reason", "—")
  defp event_detail(:agent_stop_failed, data), do: "REASON " <> full_text(data, "reason", "—")

  defp event_detail(:tool_call, data) do
    join([
      full_text(data, "tool_name", "tool"),
      full_text(data, "arguments", "")
    ])
  end

  defp event_detail(:tool_result, data) do
    join([
      full_text(data, "tool_name", "tool"),
      full_text(data, "status", "")
    ])
  end

  defp event_detail(:user_message, data), do: full_text(data, "content", "")

  defp event_detail(:model_message, data) do
    join([
      full_text(data, "content", ""),
      finish_reason(data),
      tool_count(data)
    ])
  end

  defp event_detail(:model_tool_call, data) do
    join([
      full_text(data, "tool_name", "tool"),
      full_text(data, "arguments", "")
    ])
  end

  defp event_detail(:context_compacted, data) do
    join([
      "REV " <> full_text(data, "revision", "—"),
      "DROPPED " <> full_text(data, "dropped_messages", "—"),
      "ARCHIVE " <> full_text(data, "archive_generation", "—")
    ])
  end

  defp event_detail(:agent_waiting, _data), do: "AWAITING INPUT"
  defp event_detail(:agent_woken, _data), do: "OPERATOR MESSAGE"
  defp event_detail(:run_completed, _data), do: "RESULT RECORDED"
  defp event_detail(:run_failed, data), do: full_text(data, "reason", "")

  defp event_detail(:provider_error, data) do
    join([
      "KIND " <> full_text(data, "kind", "—"),
      status_detail(data),
      retryable_detail(data),
      full_text(data, "message", "")
    ])
  end

  defp event_detail(:agent_failed, data) do
    join([
      "STAGE " <> full_text(data, "stage", "—"),
      full_text(data, "reason", full_text(data, "message", ""))
    ])
  end

  defp event_detail(:hook_started, data) do
    join([
      "PHASE " <> full_text(data, "phase", "—"),
      "HOOK " <> full_text(data, "hook", "—")
    ])
  end

  defp event_detail(:hook_finished, data) do
    join([
      "PHASE " <> full_text(data, "phase", "—"),
      "HOOK " <> full_text(data, "hook", "—"),
      full_text(data, "output", "")
    ])
  end

  defp event_detail(:hook_failed, data) do
    join([
      "PHASE " <> full_text(data, "phase", "—"),
      "HOOK " <> full_text(data, "hook", "—"),
      full_text(data, "reason", "")
    ])
  end

  defp event_detail(_type, data), do: data_detail(data)

  def event_preview(event) do
    detail = event_detail(event)

    case detail do
      "" -> ""
      detail -> truncate(detail, @detail_limit)
    end
  end

  def stream_items(events, history) do
    history_ids = MapSet.new(history, & &1.call_id)

    event_items =
      events
      |> Enum.reject(fn event ->
        event.type in [:tool_call, :tool_result] and
          MapSet.member?(history_ids, tool_event_id(event))
      end)
      |> Enum.map(&event_item/1)

    tool_items =
      Enum.map(history, fn record ->
        %{
          kind: :tool,
          at: at_ms(record.timestamp),
          time: event_time(record),
          name: record.tool_name,
          target: truncate(record.arguments, @tool_detail_limit),
          toolkit: record.toolkit_id,
          src: String.first(record.toolkit_id || ""),
          status: String.upcase(record.status),
          tone: tool_tone(record.status)
        }
      end)

    chat_items = Enum.filter(event_items, &(&1.kind == :chat))
    event_items = Enum.reject(event_items, &(&1.kind == :chat))

    recent = Enum.take(event_items ++ tool_items, -120)

    (chat_items ++ recent) |> Enum.sort_by(& &1.at)
  end

  defp event_item(%Event{type: :user_message} = event) do
    %{
      kind: :chat,
      role: :operator,
      type: "OPERATOR",
      at: at_ms(event.at),
      time: event_time(event),
      text: full_text(event.data, "content", ""),
      meta: nil
    }
  end

  defp event_item(%Event{type: :model_message} = event) do
    %{
      kind: :chat,
      role: :agent,
      type: "AGENT",
      at: at_ms(event.at),
      time: event_time(event),
      text: full_text(event.data, "content", ""),
      meta: join([finish_reason(event.data), tool_count(event.data)])
    }
  end

  defp event_item(%Event{} = event) do
    label = event_label(event.type)
    detail = event_detail(event)

    %{
      kind: :event,
      at: at_ms(event.at),
      time: event_time(event),
      type: "EVENT",
      label: label,
      detail: detail,
      preview: truncate(detail, @detail_limit),
      text: join([label, truncate(detail, @detail_limit)])
    }
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

  defp full_text(data, key, default) do
    case Map.get(data, key) do
      nil -> default
      value when is_binary(value) -> value
      value when is_number(value) -> to_string(value)
      value when is_atom(value) -> Atom.to_string(value)
      value -> inspect(value, limit: :infinity, printable_limit: :infinity)
    end
  end

  defp status_detail(data) do
    case Map.get(data, "status") do
      nil -> nil
      _status -> "STATUS " <> full_text(data, "status", "—")
    end
  end

  defp retryable_detail(data) do
    case Map.get(data, "retryable") do
      nil -> nil
      _retryable -> "RETRYABLE " <> full_text(data, "retryable", "—")
    end
  end

  defp data_detail(data) when data == %{}, do: ""

  defp data_detail(data) when is_map(data) do
    data
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map_join(" · ", fn {key, value} ->
      "#{key}: #{value_text(value)}"
    end)
  end

  defp data_detail(_data), do: ""

  defp value_text(value) when is_binary(value), do: value
  defp value_text(value) when is_number(value), do: to_string(value)
  defp value_text(value) when is_atom(value), do: Atom.to_string(value)
  defp value_text(value), do: inspect(value, limit: :infinity, printable_limit: :infinity)

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
