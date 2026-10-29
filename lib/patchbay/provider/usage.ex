defmodule Patchbay.Provider.Usage do
  @moduledoc """
  Token usage reported by a provider.
  """

  defstruct prompt_tokens: 0, completion_tokens: 0, total_tokens: 0

  @type t :: %__MODULE__{
          prompt_tokens: non_neg_integer(),
          completion_tokens: non_neg_integer(),
          total_tokens: non_neg_integer()
        }
end
