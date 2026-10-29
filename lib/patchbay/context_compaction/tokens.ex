defmodule Patchbay.ContextCompaction.Tokens do
  @moduledoc """
  Conservative token estimation for provider messages.

  The estimator deliberately rounds up and charges a per-message and
  per-tool-call overhead. It is used only for compaction thresholds, where
  overestimating is safer than letting a request exceed a model's window.
  """

  alias Patchbay.Provider.{JSON, Message, ToolCall}

  @bytes_per_token 3
  @message_overhead 6
  @tool_call_overhead 12

  @spec estimate([Message.t()]) :: non_neg_integer()
  def estimate(messages) when is_list(messages) do
    Enum.reduce(messages, 0, fn message, total -> total + estimate_message(message) end)
  end

  @spec estimate_message(Message.t()) :: non_neg_integer()
  def estimate_message(%Message{} = message) do
    @message_overhead + estimate_text(message.content) + estimate_calls(message.tool_calls)
  end

  @spec estimate_text(binary() | nil) :: non_neg_integer()
  def estimate_text(nil), do: 0

  def estimate_text(text) when is_binary(text) do
    if text == "", do: 0, else: div(byte_size(text) + @bytes_per_token - 1, @bytes_per_token)
  end

  defp estimate_calls(calls) when is_list(calls) do
    Enum.reduce(calls, 0, fn call, total ->
      total + @tool_call_overhead + estimate_call(call)
    end)
  end

  defp estimate_calls(_calls), do: 0

  defp estimate_call(%ToolCall{} = call) do
    estimate_text(call.id) + estimate_text(call.name) + estimate_arguments(call)
  end

  defp estimate_call(_call), do: 0

  defp estimate_arguments(%ToolCall{raw_arguments: raw}) when is_binary(raw) do
    estimate_text(raw)
  end

  defp estimate_arguments(%ToolCall{arguments: arguments}) do
    case JSON.encode(arguments) do
      {:ok, encoded} -> estimate_text(encoded)
      {:error, _reason} -> 16
    end
  end
end
