defmodule Patchbay.Definition.Model do
  @moduledoc """
  The model provider selected for an agent.

  `name` selects the provider model for requests. Omitting it, or setting it to
  `"default"`, uses the manager's configured model (`PATCHBAY_LLM_MODEL`, then
  `OPENAI_MODEL`) and is stored as `nil`. Any other value is sent to the
  provider as written.
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

    {name, errors} = Parse.optional_string(raw, "name", ["model", "name"], errors)
    {reasoning, errors} = Parse.optional_string(raw, "reasoning", ["model", "reasoning"], errors)

    {%__MODULE__{provider: provider, name: explicit_name(name), reasoning: reasoning}, errors}
  end

  def from_map(_raw, errors) do
    {nil, Parse.error(errors, ["model"], "must be a table")}
  end

  defp explicit_name("default"), do: nil
  defp explicit_name(name), do: name
end
