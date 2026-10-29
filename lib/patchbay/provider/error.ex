defmodule Patchbay.Provider.Error do
  @moduledoc """
  A provider-neutral error.

  `kind` identifies where the failure happened. Provider error payloads are
  reduced to `message`, `code`, and `details` rather than leaking the raw
  wire response.
  """

  @type kind ::
          :config | :request | :transport | :http | :api | :protocol | :timeout | :cancelled

  defexception kind: nil,
               message: "provider error",
               status: nil,
               code: nil,
               retryable: false,
               details: %{}

  @type t :: %__MODULE__{
          kind: kind() | nil,
          message: String.t() | nil,
          status: non_neg_integer() | nil,
          code: String.t() | integer() | nil,
          retryable: boolean(),
          details: map()
        }

  @spec new(kind(), String.t(), keyword()) :: t()
  def new(kind, message, opts \\ []) when is_atom(kind) and is_binary(message) do
    %__MODULE__{
      kind: kind,
      message: message,
      status: Keyword.get(opts, :status),
      code: Keyword.get(opts, :code),
      retryable: Keyword.get(opts, :retryable, false),
      details: Keyword.get(opts, :details, %{})
    }
  end
end
