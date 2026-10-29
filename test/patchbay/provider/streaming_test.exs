defmodule Patchbay.Provider.StreamingStub do
  @moduledoc false

  def start(chunks, opts \\ []) do
    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen)
    parent = self()

    spawn(fn -> serve(listen, chunks, parent, opts) end)

    %{url: "http://127.0.0.1:#{port}", port: port}
  end

  defp serve(listen, chunks, parent, opts) do
    case :gen_tcp.accept(listen, 5_000) do
      {:ok, socket} ->
        request = read_request(socket, "")
        send(parent, {:stub_request, request})

        case Keyword.get(opts, :hang) do
          nil -> respond(socket, chunks, opts)
          milliseconds -> hang(socket, milliseconds)
        end

      {:error, _reason} ->
        :ok
    end

    :gen_tcp.close(listen)
  end

  defp respond(socket, chunks, opts) do
    status = Keyword.get(opts, :status, 200)

    if status in 200..299 do
      :gen_tcp.send(
        socket,
        "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n" <>
          "content-type: text/event-stream\r\nconnection: close\r\n\r\n"
      )

      Enum.each(chunks, fn chunk ->
        Process.sleep(Keyword.get(opts, :gap, 2))
        send_chunk(socket, chunk)
      end)

      :gen_tcp.send(socket, "0\r\n\r\n")
    else
      body = Enum.join(chunks)

      :gen_tcp.send(
        socket,
        "HTTP/1.1 #{status} Stub\r\ncontent-type: application/json\r\n" <>
          "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body
      )
    end

    :gen_tcp.close(socket)
  end

  defp hang(socket, milliseconds) do
    Process.sleep(milliseconds)
    :gen_tcp.close(socket)
  end

  defp send_chunk(_socket, ""), do: :ok

  defp send_chunk(socket, chunk) do
    :gen_tcp.send(socket, Integer.to_string(byte_size(chunk), 16) <> "\r\n" <> chunk <> "\r\n")
  end

  defp read_request(socket, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, rest] ->
        request = parse_head(head)
        %{request | body: read_body(socket, rest, content_length(head))}

      [_incomplete] ->
        case :gen_tcp.recv(socket, 0, 5_000) do
          {:ok, data} -> read_request(socket, acc <> data)
          {:error, _reason} -> %{method: nil, path: nil, headers: %{}, body: acc}
        end
    end
  end

  defp read_body(_socket, acc, length) when byte_size(acc) >= length do
    binary_part(acc, 0, length)
  end

  defp read_body(socket, acc, length) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> read_body(socket, acc <> data, length)
      {:error, _reason} -> acc
    end
  end

  defp parse_head(head) do
    [request_line | header_lines] = String.split(head, "\r\n")
    [method, path, _version] = String.split(request_line, " ")

    headers =
      Map.new(header_lines, fn line ->
        [name, value] = String.split(line, ":", parts: 2)
        {String.downcase(String.trim(name)), String.trim(value)}
      end)

    %{method: method, path: path, headers: headers, body: ""}
  end

  defp content_length(head) do
    head
    |> String.split("\r\n")
    |> Enum.find_value(0, fn line ->
      case String.split(line, ":", parts: 2) do
        [name, value] ->
          if String.downcase(String.trim(name)) == "content-length" do
            value |> String.trim() |> String.to_integer()
          end

        _other ->
          nil
      end
    end)
  end
end

defmodule Patchbay.Provider.FakeStreamTransport do
  @moduledoc false

  @behaviour Patchbay.Provider.Transport

  @impl true
  def post(_url, _headers, _body, _opts), do: {:error, :not_used}

  @impl true
  def stream(_url, headers, body, acc, reducer, opts) do
    if pid = Keyword.get(opts, :notify), do: send(pid, {:fake_stream_request, headers, body})

    status = Keyword.get(opts, :status, 200)
    chunks = Keyword.get(opts, :chunks, [])

    case reduce(reducer, {:status, status, []}, acc) do
      {:cont, acc} -> feed(chunks, reducer, acc, status)
      {:halt, acc} -> {:halted, acc}
    end
  end

  defp feed([], _reducer, acc, status), do: {:ok, status, [], acc}

  defp feed([chunk | rest], reducer, acc, status) do
    bytes = for <<byte <- chunk>>, do: <<byte>>

    case feed_bytes(bytes, reducer, acc) do
      {:cont, acc} -> feed(rest, reducer, acc, status)
      {:halt, acc} -> {:halted, acc}
    end
  end

  defp feed_bytes([], _reducer, acc), do: {:cont, acc}

  defp feed_bytes([byte | rest], reducer, acc) do
    case reducer.({:data, byte}, acc) do
      {:cont, acc} -> feed_bytes(rest, reducer, acc)
      {:halt, acc} -> {:halt, acc}
    end
  end

  defp reduce(reducer, event, acc) do
    case reducer.(event, acc) do
      {:cont, acc} -> {:cont, acc}
      {:halt, acc} -> {:halt, acc}
    end
  end
end

defmodule Patchbay.Provider.StreamingTest do
  use ExUnit.Case, async: false

  alias Patchbay.Provider

  alias Patchbay.Provider.{
    CompleteOnlyProvider,
    Config,
    Error,
    FakeStreamTransport,
    JSON,
    Message,
    NoStreamTransport,
    OpenAI,
    Request,
    Response,
    StreamEvent,
    StreamingProvider,
    StreamingStub,
    ToolCall,
    Usage
  }

  test "streams text deltas split across HTTP chunks and returns a final response" do
    chunks = [
      sse(%{
        "id" => "chatcmpl-stream",
        "model" => "gpt-test",
        "choices" => [%{"index" => 0, "delta" => %{"role" => "assistant"}}]
      }),
      "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hel",
      "lo\"}}]}\n\n",
      sse(%{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{"content" => " there"},
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 2, "total_tokens" => 5}
      }),
      "data: [DONE]\n\n"
    ]

    stub = StreamingStub.start(chunks)

    assert {:ok, %Response{} = response} =
             OpenAI.stream(valid_request(), &callback/1, config: config(stub))

    assert response.id == "chatcmpl-stream"
    assert response.model == "gpt-test"
    assert response.content == "Hello there"
    assert response.finish_reason == :stop
    assert %Usage{prompt_tokens: 3, completion_tokens: 2, total_tokens: 5} = response.usage
    assert response.tool_calls == []

    assert_receive {:event, %StreamEvent{type: :text_delta, text: "Hello"}}
    assert_receive {:event, %StreamEvent{type: :text_delta, text: " there"}}
    assert_receive {:event, %StreamEvent{type: :finish, finish_reason: :stop}}

    assert_receive {:stub_request, captured}
    assert captured.method == "POST"
    assert captured.path == "/v1/chat/completions"
    assert captured.headers["accept"] == "text/event-stream"
    assert captured.headers["authorization"] == "Bearer sk-test"

    assert {:ok, body} = JSON.decode(captured.body)
    assert body["stream"] == true
    assert body["model"] == "gpt-test"
  end

  test "normalizes tool call argument deltas split into single bytes" do
    chunks = [
      sse(%{
        "id" => "chatcmpl-tools",
        "model" => "gpt-test",
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "tool_calls" => [
                %{
                  "index" => 0,
                  "id" => "call_1",
                  "type" => "function",
                  "function" => %{"name" => "read_", "arguments" => "{\"pa"}
                }
              ]
            }
          }
        ]
      }),
      sse(%{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "tool_calls" => [
                %{
                  "index" => 0,
                  "function" => %{"name" => "file", "arguments" => "th\":\"a.txt\"}"}
                }
              ]
            }
          }
        ]
      }),
      sse(%{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "tool_calls" => [
                %{
                  "index" => 1,
                  "id" => "call_2",
                  "function" => %{"name" => "other", "arguments" => "{}"}
                }
              ]
            },
            "finish_reason" => "tool_calls"
          }
        ]
      }),
      "data: [DONE]\n\n"
    ]

    assert {:ok, %Response{} = response} =
             OpenAI.stream(valid_request(), &callback/1,
               transport: FakeStreamTransport,
               config: config(%{url: "http://127.0.0.1:1"}),
               transport_options: [chunks: chunks]
             )

    assert response.content == nil
    assert response.finish_reason == :tool_calls

    assert [
             %ToolCall{
               id: "call_1",
               name: "read_file",
               arguments: %{"path" => "a.txt"},
               raw_arguments: raw
             },
             %ToolCall{id: "call_2", name: "other", arguments: %{}}
           ] = response.tool_calls

    assert raw == json!(%{"path" => "a.txt"})

    assert_receive {:event,
                    %StreamEvent{
                      type: :tool_call_delta,
                      index: 0,
                      id: "call_1",
                      name: "read_",
                      arguments: "{\"pa"
                    }}

    assert_receive {:event,
                    %StreamEvent{type: :tool_call_delta, index: 0, name: "file", arguments: _}}

    assert_receive {:event, %StreamEvent{type: :tool_call_delta, index: 1, id: "call_2"}}
    assert_receive {:event, %StreamEvent{type: :finish, finish_reason: :tool_calls}}
  end

  test "skips malformed, comment, and non-data events without stopping the stream" do
    chunks = [
      ": keep-alive\n\n",
      "event: message\n\n",
      "data: not json\n\n",
      sse(%{"choices" => []}),
      sse(%{
        "choices" => [
          %{"index" => 0, "delta" => %{"content" => "ok"}, "finish_reason" => "stop"}
        ]
      }),
      "data: [DONE]\n\n"
    ]

    assert {:ok, %Response{content: "ok", finish_reason: :stop}} =
             OpenAI.stream(valid_request(), &callback/1,
               transport: FakeStreamTransport,
               config: config(%{url: "http://127.0.0.1:1"}),
               transport_options: [chunks: chunks]
             )
  end

  test "returns a protocol error when no payload is valid" do
    chunks = ["data: {broken\n\n", "data: [DONE]\n\n"]

    assert {:error, %Error{kind: :protocol, details: %{malformed_events: 1}}} =
             OpenAI.stream(valid_request(), &callback/1,
               transport: FakeStreamTransport,
               config: config(%{url: "http://127.0.0.1:1"}),
               transport_options: [chunks: chunks]
             )
  end

  test "returns an API error carried inside an SSE payload" do
    chunks = [
      sse(%{"error" => %{"message" => "model overloaded", "type" => "server_error"}}),
      "data: [DONE]\n\n"
    ]

    assert {:error, %Error{kind: :api, message: "model overloaded"}} =
             OpenAI.stream(valid_request(), &callback/1,
               transport: FakeStreamTransport,
               config: config(%{url: "http://127.0.0.1:1"}),
               transport_options: [chunks: chunks]
             )
  end

  test "returns an HTTP error without emitting callback events" do
    body =
      json!(%{
        "error" => %{
          "message" => "Incorrect API key provided",
          "type" => "invalid_request_error",
          "code" => "invalid_api_key"
        }
      })

    stub = StreamingStub.start([body], status: 401)

    assert {:error,
            %Error{
              kind: :http,
              status: 401,
              message: "Incorrect API key provided",
              code: "invalid_api_key",
              retryable: false
            }} = OpenAI.stream(valid_request(), &callback/1, config: config(stub))

    refute_received {:event, _event}
  end

  test "accepts a stream that ends without DONE or a trailing blank line" do
    chunk =
      "data: " <>
        json!(%{
          "choices" => [
            %{"index" => 0, "delta" => %{"content" => "tail"}, "finish_reason" => "stop"}
          ]
        })

    assert {:ok, %Response{content: "tail", finish_reason: :stop}} =
             OpenAI.stream(valid_request(), &callback/1,
               transport: FakeStreamTransport,
               config: config(%{url: "http://127.0.0.1:1"}),
               transport_options: [chunks: [chunk]]
             )
  end

  test "cancels before starting when the cancel function is true" do
    assert {:error, %Error{kind: :cancelled}} =
             OpenAI.stream(valid_request(), &callback/1,
               config: config(%{url: "http://127.0.0.1:1"}),
               cancel: fn -> true end
             )
  end

  test "cancels the stream when the callback halts and keeps the partial response" do
    chunks = [
      sse(%{"choices" => [%{"index" => 0, "delta" => %{"content" => "first"}}]}),
      sse(%{
        "choices" => [
          %{"index" => 0, "delta" => %{"content" => "second"}, "finish_reason" => "stop"}
        ]
      }),
      "data: [DONE]\n\n"
    ]

    callback = fn
      %StreamEvent{type: :text_delta, text: "first"} ->
        {:halt, :user_cancel}

      %StreamEvent{} = event ->
        send(self(), {:event, event})
        :ok
    end

    assert {:error,
            %Error{
              kind: :cancelled,
              details: %{partial_response: %Response{content: "first"}}
            }} =
             OpenAI.stream(valid_request(), callback,
               transport: FakeStreamTransport,
               config: config(%{url: "http://127.0.0.1:1"}),
               transport_options: [chunks: chunks]
             )

    refute_received {:event, %StreamEvent{text: "second"}}
  end

  test "times out a stalled stream" do
    stub = StreamingStub.start([], hang: 400)

    started = System.monotonic_time(:millisecond)

    assert {:error, %Error{kind: :timeout, retryable: true}} =
             OpenAI.stream(valid_request(), &callback/1, config: config(stub, timeout: 60))

    assert System.monotonic_time(:millisecond) - started < 1_000
  end

  test "rejects a transport without stream support" do
    assert {:error, %Error{kind: :config}} =
             OpenAI.stream(valid_request(), &callback/1,
               transport: NoStreamTransport,
               config: config(%{url: "http://127.0.0.1:1"})
             )
  end

  test "rejects a non-function callback" do
    assert {:error, %Error{kind: :request}} =
             OpenAI.stream(valid_request(), :not_a_function,
               transport: FakeStreamTransport,
               config: config(%{url: "http://127.0.0.1:1"})
             )
  end

  test "Provider.stream dispatches and reports providers without streaming" do
    request = valid_request()

    assert {:ok, %Response{content: "stub"}} =
             Provider.stream(request, &callback/1,
               provider: StreamingProvider,
               message: "stub"
             )

    assert {:error, %Error{kind: :config}} =
             Provider.stream(request, &callback/1, provider: CompleteOnlyProvider)
  end

  defp callback(event) do
    send(self(), {:event, event})
    :ok
  end

  defp config(stub, opts \\ []) do
    %Config{
      base_url: stub.url <> "/v1",
      api_key: Keyword.get(opts, :api_key, "sk-test"),
      model: Keyword.get(opts, :model, "configured-model"),
      timeout: Keyword.get(opts, :timeout, 5_000)
    }
  end

  defp valid_request do
    %Request{model: "gpt-test", messages: [Message.user("hello")]}
  end

  defp sse(payload), do: "data: " <> json!(payload) <> "\n\n"

  defp json!(term) do
    {:ok, body} = JSON.encode(term)
    body
  end
end

defmodule Patchbay.Provider.NoStreamTransport do
  @moduledoc false
  @behaviour Patchbay.Provider.Transport

  @impl true
  def post(_url, _headers, _body, _opts), do: {:error, :not_used}
end

defmodule Patchbay.Provider.StreamingProvider do
  @moduledoc false
  @behaviour Patchbay.Provider

  alias Patchbay.Provider.{Request, Response}

  @impl true
  def complete(_request, _opts), do: {:error, :not_used}

  @impl true
  def stream(_request, on_event, opts) do
    :ok = on_event.(%Patchbay.Provider.StreamEvent{type: :text_delta, text: "stub"})
    {:ok, %Response{id: :stub, model: opts[:message], content: "stub"}}
  end
end

defmodule Patchbay.Provider.CompleteOnlyProvider do
  @moduledoc false
  @behaviour Patchbay.Provider

  alias Patchbay.Provider.{Request, Response}

  @impl true
  def complete(%Request{} = request, _opts), do: {:ok, %Response{model: request.model}}
end
