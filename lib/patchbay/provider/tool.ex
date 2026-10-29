defmodule Patchbay.Provider.Tool do
  @moduledoc """
  A provider-neutral tool definition exposed to the model.

  `parameters` is a JSON Schema object. The default accepts an empty object.
  """

  @default_parameters %{"type" => "object", "properties" => %{}}

  defstruct name: nil, description: nil, parameters: @default_parameters

  @type t :: %__MODULE__{
          name: String.t() | nil,
          description: String.t() | nil,
          parameters: map()
        }

  @spec new(String.t(), String.t() | nil, map() | nil) :: t()
  def new(name, description \\ nil, parameters \\ nil) when is_binary(name) do
    %__MODULE__{
      name: name,
      description: description,
      parameters: parameters || @default_parameters
    }
  end
end
