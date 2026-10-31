defmodule Patchbay.Definition.Workspace do
  @moduledoc """
  Whether an agent gets a workspace at all.

  `enabled` defaults to true, so existing definitions keep their workspace.
  When it is false the runtime allocates no workspace: `{%workspace}` is not
  available, and definitions that require it — operations or filesystem roots
  built on the variable — fail validation. The result directory stays
  independent of this setting and is always allocated.
  """

  alias Patchbay.Definition.Parse

  defstruct enabled: true

  @type t :: %__MODULE__{enabled: boolean()}

  @spec from_map(term(), Parse.errors()) :: {t(), Parse.errors()}
  def from_map(nil, errors), do: {%__MODULE__{}, errors}

  def from_map(raw, errors) when is_map(raw) do
    {enabled, errors} =
      Parse.optional_boolean(raw, "enabled", ["workspace", "enabled"], true, errors)

    {%__MODULE__{enabled: enabled}, errors}
  end

  def from_map(_raw, errors) do
    {%__MODULE__{}, Parse.error(errors, ["workspace"], "must be a table")}
  end

  @doc "A definition's workspace setting, treating an absent field as enabled."
  @spec enabled?(term()) :: boolean()
  def enabled?(%{workspace: %__MODULE__{enabled: enabled}}), do: enabled == true
  def enabled?(_definition), do: true
end
