defmodule Patchbay.Toolkit.Native.Terminal do
  @moduledoc """
  Built-in terminal tools.

  `complete_task` and `fail_task` close a run. The agent runner intercepts
  these names before dispatching a tool call, so `execute/3` is never reached
  for an ordinary run. The schemas live here because the toolkit is declared
  by `priv/toolkits/terminal.toml`.
  """

  @behaviour Patchbay.Toolkit.Native

  @complete_task "complete_task"
  @fail_task "fail_task"

  @impl true
  def id, do: "terminal"

  @impl true
  def tools(context) do
    definition = Map.get(context, :definition, %{})

    [
      %{
        name: @complete_task,
        description:
          "Finish the task with the declared results. Required results must be present.",
        schema: complete_task_schema(definition)
      },
      %{
        name: @fail_task,
        description: "Fail the task with a reason when it cannot be completed.",
        schema: %{
          "type" => "object",
          "properties" => %{"reason" => %{"type" => "string"}},
          "required" => ["reason"]
        }
      }
    ]
  end

  @impl true
  def execute(name, _arguments, _context), do: {:error, {:runner_managed_tool, name}}

  @doc "Tool names provided by this toolkit."
  @spec tool_names() :: [String.t()]
  def tool_names, do: [@complete_task, @fail_task]

  defp complete_task_schema(definition) do
    results = Map.get(definition, :results, [])

    properties =
      Map.new(results, fn result ->
        {result.id, result_schema(result)}
      end)

    required = results |> Enum.filter(& &1.required) |> Enum.map(& &1.id)

    results_schema =
      %{"type" => "object", "properties" => properties}
      |> put_required(required)

    %{
      "type" => "object",
      "properties" => %{"results" => results_schema},
      "required" => ["results"]
    }
  end

  defp result_schema(result) do
    schema =
      case result.form do
        :number -> %{"type" => "number"}
        _form -> %{"type" => "string"}
      end

    schema =
      case description(result) do
        nil -> schema
        description -> Map.put(schema, "description", description)
      end

    schema
  end

  defp description(result) do
    parts =
      [result.label]
      |> Enum.concat(extension_note(result))
      |> Enum.reject(&(&1 in [nil, ""]))

    case parts do
      [] -> nil
      parts -> Enum.join(parts, " ")
    end
  end

  defp extension_note(%{form: :file, extensions: extensions}) do
    extensions =
      extensions
      |> List.wrap()
      |> Enum.map(&String.trim_leading(&1, "."))
      |> Enum.reject(&(&1 == ""))

    case extensions do
      [] ->
        ["(a file path inside the workspace)"]

      extensions ->
        ["(a file path inside the workspace; extensions: #{Enum.join(extensions, ", ")})"]
    end
  end

  defp extension_note(_result), do: []

  defp put_required(schema, []), do: schema
  defp put_required(schema, required), do: Map.put(schema, "required", required)
end
