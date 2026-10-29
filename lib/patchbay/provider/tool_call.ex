defmodule Patchbay.Provider.ToolCall do
  @moduledoc """
  A tool call requested by the model.

  `arguments` holds decoded JSON object arguments. `raw_arguments` preserves
  the provider's original string when the response carried one, including when
  it was not a JSON object.
  """

  defstruct id: nil, name: nil, arguments: %{}, raw_arguments: nil

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t() | nil,
          arguments: map(),
          raw_arguments: String.t() | nil
        }

  @spec new(String.t() | nil, String.t() | nil, map(), keyword()) :: t()
  def new(id, name, arguments \\ %{}, opts \\ []) when is_map(arguments) do
    %__MODULE__{
      id: id,
      name: name,
      arguments: arguments,
      raw_arguments: Keyword.get(opts, :raw_arguments)
    }
  end
end
