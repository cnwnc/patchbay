defmodule Patchbay.Provider.Message do
  @moduledoc """
  A provider-neutral chat message.

  Assistant messages may carry tool calls with no text content. Tool messages
  carry the id of the call they answer.
  """

  alias Patchbay.Provider.ToolCall

  @type role :: :system | :user | :assistant | :tool

  defstruct role: nil, content: nil, tool_calls: [], tool_call_id: nil, name: nil

  @type t :: %__MODULE__{
          role: role() | nil,
          content: String.t() | nil,
          tool_calls: [ToolCall.t()],
          tool_call_id: String.t() | nil,
          name: String.t() | nil
        }

  @spec system(String.t(), keyword()) :: t()
  def system(content, opts \\ []) when is_binary(content) do
    %__MODULE__{role: :system, content: content, name: Keyword.get(opts, :name)}
  end

  @spec user(String.t(), keyword()) :: t()
  def user(content, opts \\ []) when is_binary(content) do
    %__MODULE__{role: :user, content: content, name: Keyword.get(opts, :name)}
  end

  @doc """
  Builds an assistant message.

  Pass `tool_calls:` for a message that requests tools; its content may be
  `nil`.
  """
  @spec assistant(String.t() | nil, keyword()) :: t()
  def assistant(content \\ nil, opts \\ []) do
    %__MODULE__{
      role: :assistant,
      content: content,
      tool_calls: Keyword.get(opts, :tool_calls, []),
      name: Keyword.get(opts, :name)
    }
  end

  @doc "Builds a tool result message for `tool_call_id`."
  @spec tool(String.t(), String.t(), keyword()) :: t()
  def tool(tool_call_id, content, opts \\ [])
      when is_binary(tool_call_id) and is_binary(content) do
    %__MODULE__{
      role: :tool,
      content: content,
      tool_call_id: tool_call_id,
      name: Keyword.get(opts, :name)
    }
  end
end
