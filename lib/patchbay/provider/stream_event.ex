defmodule Patchbay.Provider.StreamEvent do
  @moduledoc """
  An incremental event delivered to a streaming completion callback.

  Events are normalized provider-neutral values:

    * `:text_delta` carries the next `text` fragment.
    * `:tool_call_delta` carries a raw fragment for the tool call at `index`.
      `id` and `name` may be `nil` when the provider has not sent them yet.
    * `:finish` reports the normalized `finish_reason` for the completion.

  The callback receives events in wire order. Its final `Patchbay.Provider.Response`
  is assembled from the same deltas, so a caller that only needs the result can
  ignore the events.
  """

  alias Patchbay.Provider.Response

  @type type :: :text_delta | :tool_call_delta | :finish

  defstruct type: nil,
            text: nil,
            index: nil,
            id: nil,
            name: nil,
            arguments: nil,
            finish_reason: nil

  @type t :: %__MODULE__{
          type: type() | nil,
          text: String.t() | nil,
          index: non_neg_integer() | nil,
          id: String.t() | nil,
          name: String.t() | nil,
          arguments: String.t() | nil,
          finish_reason: Response.finish_reason()
        }
end
