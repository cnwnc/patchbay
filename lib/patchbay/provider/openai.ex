defmodule Patchbay.Provider.OpenAI do
  @moduledoc """
  OpenAI-compatible chat completions client.

  Both nonstreaming and streaming completions are supported. Requests are
  built from provider-neutral values, and responses are normalized back into
  `Patchbay.Provider.Response` and `Patchbay.Provider.Error` values.

  `stream/3` consumes server-sent events incrementally and reduces text and
  tool-call argument deltas into events for a callback while assembling the
  same `Patchbay.Provider.Response` that `complete/2` returns. Malformed SSE
  payloads are skipped; a stream with no valid payload becomes a `:protocol`
  error.

  The client never logs request headers, bodies, or configuration. Pass
  `:transport` to override `Patchbay.Provider.HTTP` and `:config` to supply
  settings without an environment lookup.
  """

  @behaviour Patchbay.Provider

  alias Patchbay.Provider.{
    Config,
    Error,
    JSON,
    Message,
    Request,
    Response,
    SSE,
    StreamEvent,
    Tool,
    ToolCall,
    Usage
  }

  alias Patchbay.Toolkit.Name

  @impl true
  def complete(%Request{} = request, opts \\ []) when is_list(opts) do
    config = Keyword.get_lazy(opts, :config, fn -> Config.load(opts) end)
    transport = Keyword.get(opts, :transport, Patchbay.Provider.HTTP)

    with {:ok, config} <- validate_config(config),
         {:ok, model} <- model_for(request, config),
         :ok <- validate_request(request),
         {:ok, body} <- encode_request(request, model),
         {:ok, status, _headers, response_body} <- post(transport, config, body) do
      handle_response(status, response_body)
    end
  end

  @doc """
  Streams a completion, calling `on_event` for each normalized delta.

  `on_event` is a 1-arity function receiving a
  `Patchbay.Provider.StreamEvent`. Return `:ok` to continue, `:halt`, or
  `{:halt, reason}` to cancel. A callback halt returns a `:cancelled` error
  carrying the partial response under `details.partial_response`.

  Options are the same as `complete/2`, plus:

    * `:inactivity_timeout` - milliseconds without a body fragment before the
      stream is aborted; defaults to the config timeout.
    * `:cancel` - zero-arity function polled between body fragments; a truthy
      result cancels the stream.
    * `:transport_options` - extra options merged into the transport call.
  """
  @impl true
  def stream(%Request{} = request, on_event, opts \\ []) when is_list(opts) do
    if is_function(on_event, 1) do
      do_stream(request, on_event, opts)
    else
      {:error, Error.new(:request, "stream callback must be a 1-arity function")}
    end
  end

  defp do_stream(request, on_event, opts) do
    config = Keyword.get_lazy(opts, :config, fn -> Config.load(opts) end)
    transport = Keyword.get(opts, :transport, Patchbay.Provider.HTTP)

    with {:ok, config} <- validate_config(config),
         {:ok, model} <- model_for(request, config),
         :ok <- validate_request(request),
         :ok <- validate_stream_transport(transport),
         {:ok, body} <- encode_request(request, model, true) do
      stream_with_transport(transport, config, body, on_event, opts)
    end
  end

  defp validate_stream_transport(transport) do
    if is_atom(transport) and Code.ensure_loaded?(transport) and
         function_exported?(transport, :stream, 6) do
      :ok
    else
      {:error, Error.new(:config, "transport does not support streaming")}
    end
  end

  defp stream_with_transport(transport, %Config{} = config, body, on_event, opts) do
    initial = new_stream_state(on_event)

    case transport.stream(
           Config.chat_completions_url(config),
           stream_headers(config),
           body,
           initial,
           &reduce_stream_event/2,
           stream_transport_options(config, opts)
         ) do
      {:ok, status, _headers, state} ->
        finish_stream(status, state)

      {:halted, state} ->
        halted_stream(state)

      {:error, reason, state} ->
        stream_transport_error(reason, state)

      _other ->
        {:error, Error.new(:transport, "transport returned an invalid stream result")}
    end
  end

  defp stream_headers(%Config{api_key: api_key}) do
    base = [{"content-type", "application/json"}, {"accept", "text/event-stream"}]

    case api_key do
      key when is_binary(key) and key != "" ->
        [{"authorization", "Bearer " <> key} | base]

      _ ->
        base
    end
  end

  defp stream_transport_options(%Config{timeout: timeout}, opts) do
    base = [
      timeout: timeout,
      inactivity_timeout: Keyword.get(opts, :inactivity_timeout, timeout)
    ]

    base
    |> maybe_put(:cancel, Keyword.get(opts, :cancel))
    |> Keyword.merge(Keyword.get(opts, :transport_options, []))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp new_stream_state(on_event) do
    %{
      on_event: on_event,
      sse: SSE.new(),
      status: nil,
      headers: [],
      error_body: "",
      id: nil,
      model: nil,
      content: "",
      has_content: false,
      tools: %{},
      finish_reason: nil,
      usage: nil,
      decoded: 0,
      malformed: 0,
      done: false,
      error: nil,
      halted: nil
    }
  end

  defp reduce_stream_event({:status, status, headers}, state) do
    {:cont, %{state | status: status, headers: headers}}
  end

  defp reduce_stream_event({:data, chunk}, %{status: status} = state)
       when is_integer(status) and status not in 200..299 do
    {:cont, %{state | error_body: state.error_body <> chunk}}
  end

  defp reduce_stream_event({:data, chunk}, state) do
    {payloads, sse} = SSE.push(state.sse, chunk)
    consume_stream_payloads(payloads, %{state | sse: sse})
  end

  defp reduce_stream_event(_event, state), do: {:cont, state}

  defp consume_stream_payloads([], state), do: {:cont, state}

  defp consume_stream_payloads([payload | rest], state) do
    case String.trim(payload) do
      "[DONE]" ->
        {:halt, %{state | done: true}}

      "" ->
        consume_stream_payloads(rest, state)

      data ->
        consume_stream_payload(data, rest, state)
    end
  end

  defp consume_stream_payload(payload, rest, state) do
    case JSON.decode(payload) do
      {:ok, %{"error" => error}} ->
        {:halt, %{state | error: error_object(error, nil, :api)}}

      {:ok, %{} = chunk} ->
        apply_stream_chunk(chunk, rest, state)

      _other ->
        consume_stream_payloads(rest, %{state | malformed: state.malformed + 1})
    end
  end

  defp apply_stream_chunk(chunk, rest, state) do
    state = %{
      state
      | decoded: state.decoded + 1,
        id: chunk["id"] || state.id,
        model: chunk["model"] || state.model
    }

    state =
      case decode_usage(chunk["usage"]) do
        nil -> state
        usage -> %{state | usage: usage}
      end

    case chunk["choices"] do
      [choice | _] when is_map(choice) ->
        case apply_stream_choice(choice, state) do
          {:cont, state} -> consume_stream_payloads(rest, state)
          {:halt, state} -> {:halt, state}
        end

      _other ->
        consume_stream_payloads(rest, state)
    end
  end

  defp apply_stream_choice(choice, state) do
    delta = if is_map(choice["delta"]), do: choice["delta"], else: %{}

    with {:cont, state} <- stream_content(delta["content"], state),
         {:cont, state} <- stream_tool_calls(delta["tool_calls"], state),
         {:cont, state} <- stream_finish(choice["finish_reason"], state) do
      {:cont, state}
    end
  end

  defp stream_content(content, state) do
    case normalize_content(content) do
      text when is_binary(text) and text != "" ->
        state = %{state | content: state.content <> text, has_content: true}

        case emit_stream_event(state, %StreamEvent{type: :text_delta, text: text}) do
          :ok -> {:cont, state}
          {:halt, state} -> {:halt, state}
        end

      _other ->
        {:cont, state}
    end
  end

  defp stream_tool_calls(calls, state) when is_list(calls) do
    Enum.reduce_while(calls, {:cont, state}, fn call, {:cont, acc} ->
      case stream_tool_call(call, acc) do
        {:cont, acc} -> {:cont, {:cont, acc}}
        {:halt, acc} -> {:halt, {:halt, acc}}
      end
    end)
  end

  defp stream_tool_calls(_calls, state), do: {:cont, state}

  defp stream_tool_call(%{} = call, state) do
    index = stream_tool_index(call["index"])
    function = if is_map(call["function"]), do: call["function"], else: %{}
    id = stream_tool_id(call["id"])
    name = binary_value(function["name"])
    arguments = binary_value(function["arguments"])

    entry = Map.get(state.tools, index, %{id: nil, name: "", arguments: ""})

    entry = %{
      id: entry.id || id,
      name: entry.name <> (name || ""),
      arguments: entry.arguments <> (arguments || "")
    }

    state = %{state | tools: Map.put(state.tools, index, entry)}

    if id || name || arguments do
      event = %StreamEvent{
        type: :tool_call_delta,
        index: index,
        id: id,
        name: name,
        arguments: arguments
      }

      case emit_stream_event(state, event) do
        :ok -> {:cont, state}
        {:halt, state} -> {:halt, state}
      end
    else
      {:cont, state}
    end
  end

  defp stream_tool_call(_call, state), do: {:cont, state}

  defp stream_tool_index(index) when is_integer(index) and index >= 0, do: index
  defp stream_tool_index(_index), do: 0

  defp stream_finish(nil, state), do: {:cont, state}

  defp stream_finish(reason, state) do
    finish_reason = decode_finish_reason(reason)
    state = %{state | finish_reason: finish_reason}

    case emit_stream_event(state, %StreamEvent{type: :finish, finish_reason: finish_reason}) do
      :ok -> {:cont, state}
      {:halt, state} -> {:halt, state}
    end
  end

  defp emit_stream_event(%{on_event: on_event} = state, event) do
    case on_event.(event) do
      :ok -> :ok
      :halt -> {:halt, %{state | halted: :halt}}
      {:halt, reason} -> {:halt, %{state | halted: reason}}
      _other -> :ok
    end
  end

  defp finish_stream(status, state) do
    {payloads, sse} = SSE.finish(state.sse)
    {_result, state} = consume_stream_payloads(payloads, %{state | sse: sse})
    finalize_stream(status, state)
  end

  defp finalize_stream(status, %{error_body: body})
       when is_integer(status) and status not in 200..299 do
    {:error, http_error(status, body)}
  end

  defp finalize_stream(_status, %{error: %Error{} = error} = state) do
    {:error, with_partial(error, state)}
  end

  defp finalize_stream(_status, %{halted: halted} = state) when not is_nil(halted) do
    {:error, with_partial(cancelled_error(halted), state)}
  end

  defp finalize_stream(_status, %{decoded: 0} = state) do
    message =
      if state.malformed > 0,
        do: "stream contained no valid events",
        else: "stream ended without completion data"

    {:error, Error.new(:protocol, message, details: %{malformed_events: state.malformed})}
  end

  defp finalize_stream(_status, %{done: true} = state) do
    {:ok, stream_response(state)}
  end

  defp finalize_stream(_status, state), do: {:ok, stream_response(state)}

  defp halted_stream(%{error: %Error{} = error} = state) do
    {:error, with_partial(error, state)}
  end

  defp halted_stream(%{decoded: 0} = state) do
    {:error,
     Error.new(:protocol, "stream ended without completion data",
       details: %{malformed_events: state.malformed}
     )}
  end

  defp halted_stream(%{done: true} = state), do: {:ok, stream_response(state)}

  defp halted_stream(state) do
    {:error, with_partial(cancelled_error(state.halted), state)}
  end

  defp cancelled_error(reason) do
    Error.new(:cancelled, "stream cancelled", details: %{reason: inspect(reason, limit: 10)})
  end

  defp stream_transport_error(:timeout, state) do
    error =
      Error.new(:timeout, "stream timed out",
        retryable: true,
        details: %{reason: "timeout"}
      )

    {:error, with_partial(error, state)}
  end

  defp stream_transport_error(:cancelled, state) do
    {:error, with_partial(Error.new(:cancelled, "stream cancelled"), state)}
  end

  defp stream_transport_error(reason, state) do
    message = reason_message(reason)

    error =
      Error.new(:transport, "stream failed: #{message}",
        retryable: transport_retryable?(reason),
        details: %{reason: message}
      )

    {:error, with_partial(error, state)}
  end

  defp with_partial(%Error{} = error, state) do
    %{error | details: Map.put(error.details, :partial_response, stream_response(state))}
  end

  defp stream_response(state) do
    %Response{
      id: state.id,
      model: state.model,
      content: if(state.has_content, do: state.content, else: nil),
      tool_calls: stream_tool_calls_result(state.tools),
      finish_reason: state.finish_reason,
      usage: state.usage
    }
  end

  defp stream_tool_calls_result(tools) do
    tools
    |> Enum.sort_by(fn {index, _entry} -> index end)
    |> Enum.map(fn {_index, entry} ->
      %ToolCall{
        id: entry.id,
        name: if(entry.name == "", do: nil, else: entry.name),
        arguments: decode_arguments(entry.arguments),
        raw_arguments: if(entry.arguments == "", do: nil, else: entry.arguments)
      }
    end)
  end

  defp stream_tool_id(""), do: nil
  defp stream_tool_id(value) when is_binary(value), do: value
  defp stream_tool_id(_value), do: nil

  defp binary_value(value) when is_binary(value), do: value
  defp binary_value(_value), do: nil

  defp validate_config(%Config{base_url: base_url, timeout: timeout} = config)
       when is_binary(base_url) and base_url != "" and is_integer(timeout) and timeout > 0 do
    {:ok, config}
  end

  defp validate_config(%Config{}) do
    {:error, Error.new(:config, "base_url and a positive timeout are required")}
  end

  defp validate_config(_config) do
    {:error, Error.new(:config, "config must be a Patchbay.Provider.Config")}
  end

  defp model_for(%Request{model: model}, %Config{model: fallback}) do
    case model || fallback do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _ ->
        {:error,
         Error.new(
           :config,
           "model is required (set PATCHBAY_LLM_MODEL or the request model)"
         )}
    end
  end

  defp validate_request(%Request{messages: messages, tools: tools, extra: extra}) do
    cond do
      not is_list(messages) or messages == [] ->
        {:error, Error.new(:request, "messages must be a non-empty list")}

      not Enum.all?(messages, &match?(%Message{}, &1)) ->
        {:error, Error.new(:request, "messages must contain Patchbay.Provider.Message values")}

      not is_list(tools) or not Enum.all?(tools, &match?(%Tool{}, &1)) ->
        {:error, Error.new(:request, "tools must contain Patchbay.Provider.Tool values")}

      not is_map(extra) ->
        {:error, Error.new(:request, "extra must be a map")}

      not Enum.all?(Map.keys(extra), &(is_binary(&1) or is_atom(&1))) ->
        {:error, Error.new(:request, "extra keys must be strings or atoms")}

      true ->
        :ok
    end
  end

  defp post(transport, %Config{} = config, body) do
    url = Config.chat_completions_url(config)

    case transport.post(url, headers(config), body, timeout: config.timeout) do
      {:ok, status, response_headers, response_body}
      when is_integer(status) and is_binary(response_body) ->
        {:ok, status, response_headers, response_body}

      {:ok, _status, _response_headers, _response_body} ->
        {:error, Error.new(:transport, "transport returned an invalid response")}

      {:error, reason} ->
        message = reason_message(reason)

        {:error,
         Error.new(:transport, "request failed: #{message}",
           retryable: transport_retryable?(reason),
           details: %{reason: message}
         )}
    end
  end

  defp headers(%Config{api_key: api_key}) do
    base = [{"content-type", "application/json"}, {"accept", "application/json"}]

    case api_key do
      key when is_binary(key) and key != "" ->
        [{"authorization", "Bearer " <> key} | base]

      _ ->
        base
    end
  end

  defp encode_request(%Request{} = request, model, stream \\ false) do
    with {:ok, messages} <- encode_messages(request.messages),
         {:ok, tools} <- encode_tools(request.tools),
         {:ok, tool_choice} <- encode_tool_choice(request.tool_choice) do
      core =
        %{"model" => model, "messages" => messages, "stream" => stream}
        |> put_present("tools", if(tools == [], do: nil, else: tools))
        |> put_present("tool_choice", tool_choice)
        |> put_present("temperature", request.temperature)
        |> put_present("max_tokens", request.max_tokens)

      payload = Map.merge(stringify_keys(request.extra), core)

      case JSON.encode(payload) do
        {:ok, body} ->
          {:ok, body}

        {:error, reason} ->
          {:error,
           Error.new(:request, "could not encode request", details: %{reason: inspect(reason)})}
      end
    end
  end

  defp encode_messages(messages) do
    Enum.reduce_while(messages, {:ok, []}, fn message, {:ok, encoded} ->
      case encode_message(message) do
        {:ok, value} -> {:cont, {:ok, [value | encoded]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> reverse_result()
  end

  defp encode_message(%Message{role: role} = message)
       when role in [:system, :user, :assistant, :tool] do
    with {:ok, tool_calls} <- encode_tool_calls(message.tool_calls) do
      encoded =
        %{"role" => Atom.to_string(role), "content" => message.content}
        |> put_present("name", message.name)
        |> put_present("tool_call_id", message.tool_call_id)
        |> put_present("tool_calls", if(tool_calls == [], do: nil, else: tool_calls))

      {:ok, encoded}
    end
  end

  defp encode_message(_message) do
    {:error, Error.new(:request, "message has an unsupported role")}
  end

  defp encode_tool_calls(calls) when is_list(calls) do
    Enum.reduce_while(calls, {:ok, []}, fn call, {:ok, encoded} ->
      case encode_tool_call(call) do
        {:ok, value} -> {:cont, {:ok, [value | encoded]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> reverse_result()
  end

  defp encode_tool_calls(_calls) do
    {:error, Error.new(:request, "tool_calls must be a list")}
  end

  defp encode_tool_call(%ToolCall{name: name, id: id, arguments: arguments})
       when is_binary(name) and is_map(arguments) do
    case JSON.encode(arguments) do
      {:ok, encoded_arguments} ->
        {:ok,
         %{
           "id" => id,
           "type" => "function",
           "function" => %{"name" => name, "arguments" => encoded_arguments}
         }}

      {:error, reason} ->
        {:error,
         Error.new(:request, "could not encode tool arguments",
           details: %{reason: inspect(reason)}
         )}
    end
  end

  defp encode_tool_call(_call) do
    {:error, Error.new(:request, "tool call needs a name and map arguments")}
  end

  defp encode_tools(tools) do
    Enum.reduce_while(tools, {:ok, []}, fn tool, {:ok, encoded} ->
      case encode_tool(tool) do
        {:ok, value} -> {:cont, {:ok, [value | encoded]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> reverse_result()
  end

  defp encode_tool(%Tool{name: name, description: description, parameters: parameters})
       when is_binary(name) and is_map(parameters) do
    if Name.valid?(name) do
      function =
        %{"name" => name, "parameters" => parameters}
        |> put_present("description", description)

      {:ok, %{"type" => "function", "function" => function}}
    else
      {:error, Error.new(:request, "tool name is not a valid provider function name")}
    end
  end

  defp encode_tool(_tool) do
    {:error, Error.new(:request, "tool needs a name and map parameters")}
  end

  defp encode_tool_choice(nil), do: {:ok, nil}
  defp encode_tool_choice(:auto), do: {:ok, "auto"}
  defp encode_tool_choice(:none), do: {:ok, "none"}
  defp encode_tool_choice(:required), do: {:ok, "required"}
  defp encode_tool_choice({:function, name}) when is_binary(name), do: function_choice(name)
  defp encode_tool_choice({:tool, name}) when is_binary(name), do: function_choice(name)

  defp encode_tool_choice(choice) when is_map(choice) do
    if Enum.all?(Map.keys(choice), &(is_binary(&1) or is_atom(&1))) do
      {:ok, stringify_keys(choice)}
    else
      {:error, Error.new(:request, "tool_choice keys must be strings or atoms")}
    end
  end

  defp encode_tool_choice(_choice) do
    {:error, Error.new(:request, "unsupported tool_choice")}
  end

  defp function_choice(name) do
    if Name.valid?(name) do
      {:ok, %{"type" => "function", "function" => %{"name" => name}}}
    else
      {:error, Error.new(:request, "tool choice name is not a valid provider function name")}
    end
  end

  defp handle_response(status, body) when status in 200..299 and is_binary(body) do
    case JSON.decode(body) do
      {:ok, decoded} ->
        decode_completion(decoded)

      {:error, reason} ->
        {:error,
         Error.new(:protocol, "response was not valid JSON", details: %{reason: inspect(reason)})}
    end
  end

  defp handle_response(status, body) do
    {:error, http_error(status, body)}
  end

  defp decode_completion(%{"error" => error}) do
    {:error, error_object(error, nil, :api)}
  end

  defp decode_completion(%{"choices" => [choice | _]} = body) when is_map(choice) do
    message =
      case choice do
        %{"message" => message} when is_map(message) -> message
        _ -> %{}
      end

    with {:ok, tool_calls} <- decode_tool_calls(Map.get(message, "tool_calls")) do
      {:ok,
       %Response{
         id: body["id"],
         model: body["model"],
         content: normalize_content(Map.get(message, "content")),
         tool_calls: tool_calls,
         finish_reason: decode_finish_reason(Map.get(choice, "finish_reason")),
         usage: decode_usage(body["usage"])
       }}
    end
  end

  defp decode_completion(%{"choices" => []}) do
    {:error, Error.new(:protocol, "response contained no choices")}
  end

  defp decode_completion(_body) do
    {:error, Error.new(:protocol, "response did not contain a completion choice")}
  end

  defp decode_tool_calls(nil), do: {:ok, []}
  defp decode_tool_calls([]), do: {:ok, []}

  defp decode_tool_calls(calls) when is_list(calls) do
    Enum.reduce_while(calls, {:ok, []}, fn call, {:ok, decoded} ->
      case decode_tool_call(call) do
        {:ok, value} -> {:cont, {:ok, [value | decoded]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> reverse_result()
  end

  defp decode_tool_calls(value) do
    {:error, Error.new(:protocol, "tool_calls was not a list", details: %{value: inspect(value)})}
  end

  defp decode_tool_call(%{"function" => %{} = function} = call) do
    case function["name"] do
      name when is_binary(name) ->
        raw = function["arguments"]

        {:ok,
         %ToolCall{
           id: tool_call_id(call["id"]),
           name: name,
           arguments: decode_arguments(raw),
           raw_arguments: raw_arguments(raw)
         }}

      _ ->
        {:error, Error.new(:protocol, "tool call is missing a function name")}
    end
  end

  defp decode_tool_call(_call) do
    {:error, Error.new(:protocol, "tool call was not an object")}
  end

  defp decode_arguments(nil), do: %{}
  defp decode_arguments(""), do: %{}

  defp decode_arguments(raw) when is_binary(raw) do
    case JSON.decode(raw) do
      {:ok, arguments} when is_map(arguments) -> arguments
      _ -> %{}
    end
  end

  defp decode_arguments(arguments) when is_map(arguments), do: arguments
  defp decode_arguments(_arguments), do: %{}

  defp raw_arguments(raw) when is_binary(raw), do: raw
  defp raw_arguments(_raw), do: nil

  defp tool_call_id(id) when is_binary(id) and id != "", do: id
  defp tool_call_id(_id), do: nil

  defp normalize_content(nil), do: nil
  defp normalize_content(text) when is_binary(text), do: text

  defp normalize_content(parts) when is_list(parts) do
    parts
    |> Enum.map(fn
      %{"text" => text} when is_binary(text) -> text
      _part -> ""
    end)
    |> Enum.join()
  end

  defp normalize_content(_content), do: nil

  defp decode_finish_reason("stop"), do: :stop
  defp decode_finish_reason("length"), do: :length
  defp decode_finish_reason("tool_calls"), do: :tool_calls
  defp decode_finish_reason("function_call"), do: :tool_calls
  defp decode_finish_reason("content_filter"), do: :content_filter
  defp decode_finish_reason(nil), do: nil
  defp decode_finish_reason(_reason), do: :other

  defp decode_usage(%{} = usage) do
    %Usage{
      prompt_tokens: token_count(usage["prompt_tokens"]),
      completion_tokens: token_count(usage["completion_tokens"]),
      total_tokens: token_count(usage["total_tokens"])
    }
  end

  defp decode_usage(_usage), do: nil

  defp token_count(value) when is_integer(value) and value >= 0, do: value
  defp token_count(_value), do: 0

  defp http_error(status, body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, %{"error" => error}} ->
        error_object(error, status, :http)

      {:ok, _decoded} ->
        Error.new(:http, fallback_message(status),
          status: status,
          retryable: retryable?(status)
        )

      {:error, _reason} ->
        text = body |> String.trim() |> String.slice(0, 200)

        message =
          if text == "", do: fallback_message(status), else: "HTTP #{status}: #{text}"

        Error.new(:http, message, status: status, retryable: retryable?(status))
    end
  end

  defp http_error(status, _body) do
    Error.new(:http, fallback_message(status), status: status, retryable: retryable?(status))
  end

  defp error_object(%{} = error, status, kind) do
    message =
      case error["message"] do
        message when is_binary(message) and message != "" -> message
        _ -> fallback_message(status)
      end

    Error.new(kind, message,
      status: status,
      code: error["code"],
      retryable: retryable?(status),
      details: Map.take(error, ["type", "param"])
    )
  end

  defp error_object(message, status, kind) when is_binary(message) and message != "" do
    Error.new(kind, message, status: status, retryable: retryable?(status))
  end

  defp error_object(_error, status, kind) do
    Error.new(kind, fallback_message(status), status: status, retryable: retryable?(status))
  end

  defp fallback_message(nil), do: "provider returned an error"
  defp fallback_message(status), do: "provider returned HTTP #{status}"

  defp retryable?(status)
       when status in [408, 409, 425, 429] or (is_integer(status) and status >= 500),
       do: true

  defp retryable?(_status), do: false

  defp transport_retryable?({:ssl_options, _reason}), do: false
  defp transport_retryable?(:invalid_uri), do: false
  defp transport_retryable?(_reason), do: true

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {key, value}
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
    end)
  end

  defp reverse_result({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_result({:error, _error} = error), do: error

  defp reason_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_message(reason), do: inspect(reason, limit: 10)
end
