defmodule Patchbay.Definition.Model do
  @moduledoc """
  The model provider selected for an agent.
  """

  alias Patchbay.Definition.Parse

  defstruct provider: "default", name: nil, reasoning: nil

  @type t :: %__MODULE__{
          provider: String.t(),
          name: String.t() | nil,
          reasoning: String.t() | nil
        }

  @spec from_map(term(), Parse.errors()) :: {t() | nil, Parse.errors()}
  def from_map(nil, errors) do
    {nil, Parse.error(errors, ["model"], "is required")}
  end

  def from_map(raw, errors) when is_map(raw) do
    {provider, errors} =
      case Parse.optional_string(raw, "provider", ["model", "provider"], errors) do
        {nil, errors} -> {"default", errors}
        result -> result
      end

    {name, errors} = Parse.required_string(raw, "name", ["model", "name"], errors)
    {reasoning, errors} = Parse.optional_string(raw, "reasoning", ["model", "reasoning"], errors)

    {%__MODULE__{provider: provider, name: name, reasoning: reasoning}, errors}
  end

  def from_map(_raw, errors) do
    {nil, Parse.error(errors, ["model"], "must be a table")}
  end
end
