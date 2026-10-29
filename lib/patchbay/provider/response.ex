defmodule Patchbay.Provider.Response do
  @moduledoc """
  A provider-neutral nonstreaming completion.

  A response with tool calls may have `content: nil`. `finish_reason` is
  limited to known values so callers never have to branch on provider strings.
  """

  alias Patchbay.Provider.{ToolCall, Usage}

  @type finish_reason :: :stop | :length | :tool_calls | :content_filter | :other | nil

  defstruct id: nil,
            model: nil,
            content: nil,
            tool_calls: [],
            finish_reason: nil,
            usage: nil

  @type t :: %__MODULE__{
          id: String.t() | nil,
          model: String.t() | nil,
          content: String.t() | nil,
          tool_calls: [ToolCall.t()],
          finish_reason: finish_reason(),
          usage: Usage.t() | nil
        }
end
