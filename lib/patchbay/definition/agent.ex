defmodule Patchbay.Definition.Agent do
  @moduledoc """
  A declarative agent definition loaded from an agent directory.

  `prompts`, `shared_scripts`, and `agent_scripts` are resolved from the file
  tree by `Patchbay.Definition.load/2`. The remaining fields come from
  `agent.toml`.
  """

  alias Patchbay.Definition.{
    Budgets,
    Context,
    Environment,
    Lifecycle,
    Model,
    Parse,
    Prompt,
    Result,
    Teardown,
    Toolkit
  }

  defstruct [
    :format_version,
    :id,
    :path,
    :agent_dir,
    :config_root,
    :model,
    :lifecycle,
    :environment,
    :context,
    :teardown,
    :budgets,
    toolkits: [],
    results: [],
    prompts: [],
    shared_scripts: [],
    agent_scripts: []
  ]

  @type t :: %__MODULE__{
          format_version: 1 | nil,
          id: String.t() | nil,
          path: Path.t() | nil,
          agent_dir: Path.t() | nil,
          config_root: Path.t() | nil,
          model: Model.t() | nil,
          lifecycle: Lifecycle.t() | nil,
          environment: Environment.t(),
          context: Context.t(),
          teardown: Teardown.t(),
          budgets: Budgets.t(),
          toolkits: [Toolkit.t()],
          results: [Result.t()],
          prompts: [Prompt.t()],
          shared_scripts: [Path.t()],
          agent_scripts: [Path.t()]
        }

  @spec from_map(term(), Parse.errors()) :: {t() | nil, Parse.errors()}
  def from_map(raw, errors) when is_map(raw) do
    {format_version, errors} =
      Parse.required_integer(raw, "format-version", ["format-version"], errors)

    errors = validate_format_version(format_version, errors)
    {id, errors} = Parse.required_string(raw, "id", ["id"], errors)
    errors = validate_id(id, errors)

    {model, errors} = Model.from_map(Map.get(raw, "model"), errors)
    {lifecycle, errors} = Lifecycle.from_map(Map.get(raw, "lifecycle"), errors)
    {environment, errors} = Environment.from_map(Map.get(raw, "environment"), errors)
    {context, errors} = Context.from_map(Map.get(raw, "context"), errors)
    {teardown, errors} = Teardown.from_map(Map.get(raw, "teardown"), errors)
    {budgets, errors} = Budgets.from_map(Map.get(raw, "budgets"), errors)
    {toolkits, errors} = Toolkit.from_list(Map.get(raw, "toolkits"), errors)
    {inline_toolkit, errors} = Toolkit.from_inline(Map.get(raw, "operations"), errors)
    toolkits = if inline_toolkit, do: toolkits ++ [inline_toolkit], else: toolkits
    {results, errors} = Result.from_list(Map.get(raw, "results"), errors)

    agent = %__MODULE__{
      format_version: format_version,
      id: id,
      model: model,
      lifecycle: lifecycle,
      environment: environment,
      context: context,
      teardown: teardown,
      budgets: budgets,
      toolkits: toolkits,
      results: results
    }

    {agent, errors}
  end

  def from_map(_raw, errors) do
    {nil, Parse.error(errors, [], "must be a table")}
  end

  defp validate_format_version(1, errors), do: errors

  defp validate_format_version(nil, errors), do: errors

  defp validate_format_version(version, errors) do
    Parse.error(
      errors,
      ["format-version"],
      "must be 1, got #{inspect(version)}"
    )
  end

  defp validate_id(nil, errors), do: errors

  defp validate_id(id, errors) do
    if id in [".", ".."] or String.contains?(id, ["/", "\\"]) do
      Parse.error(errors, ["id"], "must be a valid directory name")
    else
      errors
    end
  end
end
