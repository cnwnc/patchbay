defmodule Patchbay.Definition.Result do
  @moduledoc """
  A named value an agent submits through `complete_task`.

  Results are required by default. A result with `required-by` is conditional
  on another declared result and is therefore not unconditionally required.
  """

  alias Patchbay.Definition.Parse

  @forms %{"prose" => :prose, "number" => :number, "url" => :url, "file" => :file}

  defstruct id: nil,
            form: nil,
            label: nil,
            required: true,
            required_by: nil,
            extensions: []

  @type form :: :prose | :number | :url | :file

  @type t :: %__MODULE__{
          id: String.t() | nil,
          form: form() | nil,
          label: String.t() | nil,
          required: boolean(),
          required_by: String.t() | nil,
          extensions: [String.t()]
        }

  @spec from_list(term(), Parse.errors()) :: {[t()], Parse.errors()}
  def from_list(nil, errors), do: {[], errors}

  def from_list(list, errors) when is_list(list) do
    {results, errors} =
      list
      |> Enum.with_index()
      |> Enum.reduce({[], errors}, fn {raw, index}, {results, errors} ->
        {result, errors} = from_map(raw, errors, index)
        {[result | results], errors}
      end)

    results =
      results
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.reject(fn {result, _index} -> is_nil(result) end)

    {Enum.map(results, fn {result, _index} -> result end), validate_all(results, errors)}
  end

  def from_list(_value, errors) do
    {[], Parse.error(errors, ["results"], "must be an array of tables")}
  end

  @spec from_map(term(), Parse.errors(), non_neg_integer()) :: {t() | nil, Parse.errors()}
  def from_map(raw, errors, index) when is_map(raw) do
    path = ["results", index]

    {id, errors} = Parse.required_string(raw, "id", path ++ ["id"], errors)
    {label, errors} = Parse.required_string(raw, "label", path ++ ["label"], errors)
    {form, errors} = Parse.required_enum(raw, "form", path ++ ["form"], @forms, errors)

    {required_by, errors} =
      Parse.optional_string(raw, "required-by", path ++ ["required-by"], errors)

    {required, errors} = required_from(raw, path, errors)
    required = if required_by, do: false, else: required

    {extensions, errors} = extensions_from(raw, form, path, errors)

    result = %__MODULE__{
      id: id,
      form: form,
      label: label,
      required: required,
      required_by: required_by,
      extensions: extensions
    }

    {result, errors}
  end

  def from_map(_raw, errors, index) do
    {nil, Parse.error(errors, ["results", index], "must be a table")}
  end

  defp required_from(raw, path, errors) do
    errors =
      if Map.has_key?(raw, "required") and Map.has_key?(raw, "required-by") do
        Parse.error(
          errors,
          path ++ ["required-by"],
          "is mutually exclusive with required"
        )
      else
        errors
      end

    Parse.optional_boolean(raw, "required", path ++ ["required"], true, errors)
  end

  defp extensions_from(raw, form, path, errors) do
    cond do
      form == :file ->
        case Map.fetch(raw, "extensions") do
          :error ->
            {[], errors}

          {:ok, value} ->
            {extensions, errors} =
              Parse.string_list(value, path ++ ["extensions"], errors, allow_empty: true)

            {extensions || [], errors}
        end

      Map.has_key?(raw, "extensions") ->
        {[], Parse.error(errors, path ++ ["extensions"], "is only valid for a file result")}

      true ->
        {[], errors}
    end
  end

  defp validate_all(results, errors) do
    errors = duplicate_id_errors(results, errors)
    errors = dependency_errors(results, errors)
    cycle_errors(Enum.map(results, fn {result, _index} -> result end), errors)
  end

  defp duplicate_id_errors(results, errors) do
    results
    |> Enum.reduce({MapSet.new(), errors}, fn
      {%__MODULE__{id: id}, index}, {seen, errors} when is_binary(id) ->
        if MapSet.member?(seen, id) do
          errors =
            Parse.error(
              errors,
              ["results", index, "id"],
              "duplicates result #{inspect(id)}"
            )

          {seen, errors}
        else
          {MapSet.put(seen, id), errors}
        end

      {_result, _index}, acc ->
        acc
    end)
    |> elem(1)
  end

  defp dependency_errors(results, errors) do
    ids =
      results
      |> Enum.map(fn {result, _index} -> result.id end)
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    results
    |> Enum.reduce(errors, fn
      {%__MODULE__{required_by: dependency}, index}, errors when is_binary(dependency) ->
        if MapSet.member?(ids, dependency) do
          errors
        else
          Parse.error(
            errors,
            ["results", index, "required-by"],
            "references undeclared result #{inspect(dependency)}"
          )
        end

      {_result, _index}, errors ->
        errors
    end)
  end

  defp cycle_errors(results, errors) do
    edges =
      for %__MODULE__{id: id, required_by: dependency} <- results,
          is_binary(id),
          is_binary(dependency),
          into: %{},
          do: {id, dependency}

    case find_cycle(edges) do
      nil ->
        errors

      cycle ->
        Parse.error(errors, ["results"], "result dependency cycle: #{Enum.join(cycle, " -> ")}")
    end
  end

  defp find_cycle(edges) do
    Enum.find_value(Map.keys(edges), fn node ->
      case walk(node, edges, [], MapSet.new()) do
        {:cycle, cycle} -> cycle
        {:ok, _visited} -> nil
      end
    end)
  end

  defp walk(node, edges, trail, visited) do
    cond do
      node in trail ->
        path = Enum.reverse([node | trail])
        start = Enum.find_index(path, &(&1 == node))
        {:cycle, Enum.drop(path, start)}

      MapSet.member?(visited, node) ->
        {:ok, visited}

      true ->
        visited = MapSet.put(visited, node)

        case Map.get(edges, node) do
          nil ->
            {:ok, visited}

          next ->
            case walk(next, edges, [node | trail], visited) do
              {:cycle, _cycle} = cycle -> cycle
              {:ok, visited} -> {:ok, visited}
            end
        end
    end
  end
end
