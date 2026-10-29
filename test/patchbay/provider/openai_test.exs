defmodule Patchbay.Provider.HTTPStub do
  @moduledoc false

  def start(status, body, opts \\ []) do
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

    spawn_link(fn -> serve(listen, status, body, parent, opts) end)

    %{url: "http://127.0.0.1:#{port}", port: port}
  end

  def closed_port do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    :ok = :gen_tcp.close(listen)
    port
  end

  defp serve(listen, status, body, parent, opts) do
    case :gen_tcp.accept(listen, 5_000) do
      {:ok, socket} ->
        request = read_request(socket, "")

        response = [
          "HTTP/1.1 #{status} #{reason(status)}\r\n",
          "content-type: #{Keyword.get(opts, :content_type, "application/json")}\r\n",
          "content-length: #{byte_size(body)}\r\n",
          "connection: close\r\n\r\n",
          body
        ]

        send(parent, {:stub_request, request})
        :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)

      {:error, _reason} ->
        :ok
    end

    :gen_tcp.close(listen)
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

  defp reason(200), do: "OK"
  defp reason(401), do: "Unauthorized"
  defp reason(429), do: "Too Many Requests"
  defp reason(500), do: "Internal Server Error"
  defp reason(_status), do: "Stub"
end

defmodule Patchbay.Provider.OpenAITest do
  use ExUnit.Case, async: false

  alias Patchbay.Provider.{
    Config,
    Error,
    JSON,
    Message,
    OpenAI,
    Request,
    Response,
    Tool,
    ToolCall,
    Usage
  }

  alias Patchbay.Provider.HTTPStub

  test "posts a normalized request and returns normalized tool calls" do
    stub = HTTPStub.start(200, tool_response())

    request = %Request{
      model: "gpt-test",
      messages: [Message.system("be terse"), Message.user("read a.txt")],
      tools: [
        Tool.new("read_file", "Read a file", %{
          "type" => "object",
          "properties" => %{"path" => %{"type" => "string"}}
        })
      ],
      tool_choice: {:function, "read_file"}
    }

    assert {:ok, %Response{} = response} =
             OpenAI.complete(request, config: config(stub))

    assert response.id == "chatcmpl-1"
    assert response.model == "gpt-test"
    assert response.content == nil
    assert response.finish_reason == :tool_calls

    assert %Usage{prompt_tokens: 12, completion_tokens: 7, total_tokens: 19} =
             response.usage

    assert [
             %ToolCall{
               id: "call_1",
               name: "read_file",
               arguments: %{"path" => "a.txt"},
               raw_arguments: arguments
             }
           ] = response.tool_calls

    assert arguments == json!(%{"path" => "a.txt"})

    assert_receive {:stub_request, captured}
    assert captured.method == "POST"
    assert captured.path == "/v1/chat/completions"
    assert captured.headers["authorization"] == "Bearer sk-test"
    assert captured.headers["content-type"] == "application/json"

    assert {:ok, body} = JSON.decode(captured.body)
    assert body["model"] == "gpt-test"
    assert body["stream"] == false

    assert body["tool_choice"] == %{
             "type" => "function",
             "function" => %{"name" => "read_file"}
           }

    assert [
             %{"role" => "system", "content" => "be terse"},
             %{"role" => "user", "content" => "read a.txt"}
           ] = body["messages"]

    assert [%{"type" => "function", "function" => function}] = body["tools"]
    assert function["name"] == "read_file"
    assert function["description"] == "Read a file"

    assert function["parameters"] == %{
             "type" => "object",
             "properties" => %{"path" => %{"type" => "string"}}
           }
  end

  test "uses the configured model and omits authorization without an API key" do
    stub = HTTPStub.start(200, text_response("hello"))

    assert {:ok, %Response{content: "hello", finish_reason: :stop}} =
             OpenAI.complete(
               %Request{messages: [Message.user("hi")]},
               config: config(stub, api_key: nil)
             )

    assert_receive {:stub_request, captured}
    refute Map.has_key?(captured.headers, "authorization")

    assert {:ok, body} = JSON.decode(captured.body)
    assert body["model"] == "configured-model"
    refute Map.has_key?(body, "tools")
    refute Map.has_key?(body, "tool_choice")
  end

  test "encodes assistant tool calls and tool results" do
    stub = HTTPStub.start(200, text_response("done"))

    request = %Request{
      model: "gpt-test",
      messages: [
        Message.system("system"),
        Message.user("user"),
        Message.assistant(nil,
          tool_calls: [ToolCall.new("call_1", "read_file", %{"path" => "a"})]
        ),
        Message.tool("call_1", "contents", name: "read_file")
      ]
    }

    assert {:ok, %Response{}} = OpenAI.complete(request, config: config(stub))
    assert_receive {:stub_request, captured}

    assert {:ok, body} = JSON.decode(captured.body)

    assert [
             %{"role" => "system", "content" => "system"},
             %{"role" => "user", "content" => "user"},
             %{"role" => "assistant", "content" => nil, "tool_calls" => [call]},
             %{
               "role" => "tool",
               "content" => "contents",
               "tool_call_id" => "call_1",
               "name" => "read_file"
             }
           ] = body["messages"]

    assert call["id"] == "call_1"
    assert call["type"] == "function"
    assert call["function"]["name"] == "read_file"
    assert call["function"]["arguments"] == json!(%{"path" => "a"})
  end

  test "normalizes content parts and preserves unparseable tool arguments" do
    body =
      json!(%{
        "id" => "chatcmpl-2",
        "model" => "gpt-test",
        "choices" => [
          %{
            "message" => %{
              "role" => "assistant",
              "content" => [
                %{"type" => "text", "text" => "a"},
                %{"type" => "text", "text" => "b"}
              ],
              "tool_calls" => [
                %{
                  "id" => "call_2",
                  "type" => "function",
                  "function" => %{"name" => "read_file", "arguments" => "not json"}
                }
              ]
            },
            "finish_reason" => "tool_calls"
          }
        ]
      })

    stub = HTTPStub.start(200, body)

    assert {:ok,
            %Response{
              content: "ab",
              tool_calls: [
                %ToolCall{
                  id: "call_2",
                  arguments: %{},
                  raw_arguments: "not json"
                }
              ]
            }} = OpenAI.complete(valid_request(), config: config(stub))

    assert_receive {:stub_request, _captured}
  end

  test "normalizes a non-2xx provider error" do
    stub =
      HTTPStub.start(
        401,
        json!(%{
          "error" => %{
            "message" => "Incorrect API key provided",
            "type" => "invalid_request_error",
            "code" => "invalid_api_key"
          }
        })
      )

    assert {:error,
            %Error{
              kind: :http,
              status: 401,
              message: "Incorrect API key provided",
              code: "invalid_api_key",
              retryable: false,
              details: %{"type" => "invalid_request_error"}
            }} = OpenAI.complete(valid_request(), config: config(stub))
  end

  test "marks server errors retryable and keeps a text body out of details" do
    stub = HTTPStub.start(500, "upstream exploded", content_type: "text/plain")

    assert {:error, %Error{kind: :http, status: 500, retryable: true} = error} =
             OpenAI.complete(valid_request(), config: config(stub))

    assert error.message == "HTTP 500: upstream exploded"
  end

  test "normalizes an error object returned with a success status" do
    stub =
      HTTPStub.start(
        200,
        json!(%{
          "error" => %{"message" => "model overloaded", "type" => "server_error"}
        })
      )

    assert {:error,
            %Error{
              kind: :api,
              status: nil,
              message: "model overloaded",
              retryable: false
            }} = OpenAI.complete(valid_request(), config: config(stub))
  end

  test "reports malformed success bodies as protocol errors" do
    stub = HTTPStub.start(200, "{not json")

    assert {:error, %Error{kind: :protocol}} =
             OpenAI.complete(valid_request(), config: config(stub))
  end

  test "reports transport failures without leaking request content" do
    port = HTTPStub.closed_port()

    config = %Config{
      base_url: "http://127.0.0.1:#{port}/v1",
      model: "gpt-test",
      timeout: 2_000
    }

    assert {:error, %Error{kind: :transport, retryable: true} = error} =
             OpenAI.complete(valid_request(), config: config)

    refute error.message =~ "hello"
  end

  test "rejects incomplete requests before using the transport" do
    assert {:error, %Error{kind: :config}} =
             OpenAI.complete(%Request{messages: [Message.user("hi")]}, config: %Config{})

    assert {:error, %Error{kind: :request}} =
             OpenAI.complete(%Request{model: "gpt-test", messages: []}, config: %Config{})

    assert {:error, %Error{kind: :request}} =
             OpenAI.complete(
               %Request{model: "gpt-test", messages: ["not a message"]},
               config: %Config{}
             )
  end

  defp config(stub, opts \\ []) do
    %Config{
      base_url: stub.url <> "/v1",
      api_key: Keyword.get(opts, :api_key, "sk-test"),
      model: Keyword.get(opts, :model, "configured-model"),
      timeout: 5_000
    }
  end

  defp valid_request do
    %Request{model: "gpt-test", messages: [Message.user("hello")]}
  end

  defp tool_response do
    json!(%{
      "id" => "chatcmpl-1",
      "model" => "gpt-test",
      "choices" => [
        %{
          "index" => 0,
          "message" => %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              %{
                "id" => "call_1",
                "type" => "function",
                "function" => %{
                  "name" => "read_file",
                  "arguments" => json!(%{"path" => "a.txt"})
                }
              }
            ]
          },
          "finish_reason" => "tool_calls"
        }
      ],
      "usage" => %{
        "prompt_tokens" => 12,
        "completion_tokens" => 7,
        "total_tokens" => 19
      }
    })
  end

  defp text_response(content) do
    json!(%{
      "id" => "chatcmpl-text",
      "model" => "configured-model",
      "choices" => [
        %{
          "index" => 0,
          "message" => %{"role" => "assistant", "content" => content},
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
    })
  end

  defp json!(term) do
    {:ok, body} = JSON.encode(term)
    body
  end
end
