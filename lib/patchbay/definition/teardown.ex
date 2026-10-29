defmodule Patchbay.Definition.Teardown do
  @moduledoc """
  What happens to an agent run's workspace after the terminal result.
  """

  alias Patchbay.Definition.Parse

  @workspace_actions %{"retain" => :retain, "export" => :export, "destroy" => :destroy}

  defstruct workspace: nil

  @type workspace_action :: :retain | :export | :destroy
  @type t :: %__MODULE__{workspace: workspace_action() | nil}

  @spec from_map(term(), Parse.errors()) :: {t(), Parse.errors()}
  def from_map(nil, errors), do: {%__MODULE__{}, errors}

  def from_map(raw, errors) when is_map(raw) do
    {workspace, errors} =
      Parse.optional_enum(
        raw,
        "workspace",
        ["teardown", "workspace"],
        @workspace_actions,
        errors
      )

    {%__MODULE__{workspace: workspace}, errors}
  end

  def from_map(_raw, errors) do
    {%__MODULE__{}, Parse.error(errors, ["teardown"], "must be a table")}
  end
end
