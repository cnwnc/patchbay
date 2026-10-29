defmodule Patchbay.Provider.Request do
  @moduledoc """
  A provider-neutral completion request.

  `tool_choice` accepts `:auto`, `:none`, `:required`, `{:function, name}`, or
  a provider-shaped map for escape-hatch cases. `extra` is merged into the
  request body; core fields win on conflict.
  """

  alias Patchbay.Provider.{Message, Tool}

  @type tool_choice ::
          :auto | :none | :required | {:function, String.t()} | map() | nil

  defstruct model: nil,
            messages: [],
            tools: [],
            tool_choice: nil,
            temperature: nil,
            max_tokens: nil,
            extra: %{}

  @type t :: %__MODULE__{
          model: String.t() | nil,
          messages: [Message.t()],
          tools: [Tool.t()],
          tool_choice: tool_choice(),
          temperature: number() | nil,
          max_tokens: pos_integer() | nil,
          extra: map()
        }
end
