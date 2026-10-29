defmodule Patchbay.Definition.Toolkit do
  @moduledoc """
  A toolkit instance declared by an agent.

  `toolkit` names a manifest. The manifest may resolve to a registered native
  toolkit, fixed operations, or both. `config` is merged over manifest config.
  `operations` contains inline fixed operations; an inline operation with the
  same name as a manifest operation replaces it.

  Agents may also use the shorthand `[[operations]]` at the top level. It
  becomes one implicit `fixed` toolkit.
  """

  alias Patchbay.Definition.Parse
  alias Patchbay.Definition.Toolkit.Operation

  @inline_toolkit "fixed"

  defstruct [
    :toolkit,
    :description,
    :native,
    :manifest_path,
    :source,
    config: %{},
    tools: [],
    operations: []
  ]

  @type t :: %__MODULE__{
          toolkit: String.t() | nil,
          description: String.t() | nil,
          native: String.t() | nil,
          manifest_path: Path.t() | nil,
          source: :declared | :inline | nil,
          config: map(),
          tools: [String.t()],
          operations: [Operation.t()]
        }

  @doc "Name of the implicit toolkit created from top-level `[[operations]]`."
  @spec inline_toolkit_id() :: String.t()
  def inline_toolkit_id, do: @inline_toolkit

  @spec from_list(term(), Parse.errors()) :: {[t()], Parse.errors()}
  def from_list(nil, errors), do: {[], errors}

  def from_list(list, errors) when is_list(list) do
    {toolkits, errors} =
      list
      |> Enum.with_index()
      |> Enum.reduce({[], errors}, fn {raw, index}, {toolkits, errors} ->
        {toolkit, errors} = from_map(raw, errors, index)
        {[toolkit | toolkits], errors}
      end)

    {toolkits |> Enum.reverse() |> Enum.reject(&is_nil/1), errors}
  end

  def from_list(_value, errors) do
    {[], Parse.error(errors, ["toolkits"], "must be an array of tables")}
  end

  @spec from_map(term(), Parse.errors(), non_neg_integer()) :: {t() | nil, Parse.errors()}
  def from_map(raw, errors, index) when is_map(raw) do
    path = ["toolkits", index]

    {toolkit, errors} = Parse.required_string(raw, "toolkit", path ++ ["toolkit"], errors)

    {description, errors} =
      Parse.optional_string(raw, "description", path ++ ["description"], errors)

    {config, errors} = Parse.optional_map(raw, "config", path ++ ["config"], errors)
    {operations, errors} = operations_from(raw, path, errors)

    {%__MODULE__{
       toolkit: toolkit,
       description: description,
       config: config || %{},
       operations: operations,
       source: :declared
     }, errors}
  end

  def from_map(_raw, errors, index) do
    {nil, Parse.error(errors, ["toolkits", index], "must be a table")}
  end

  @doc """
  Builds the implicit toolkit from top-level `[[operations]]`.

  Returns `{nil, errors}` when the key is absent so callers can append the
  toolkit only when it was declared.
  """
  @spec from_inline(term(), Parse.errors()) :: {t() | nil, Parse.errors()}
  def from_inline(nil, errors), do: {nil, errors}

  def from_inline(list, errors) when is_list(list) do
    {operations, errors} = operations_from(%{"operations" => list}, ["__inline__"], errors)

    case operations do
      [] ->
        {nil, errors}

      operations ->
        {%__MODULE__{toolkit: @inline_toolkit, operations: operations, source: :inline}, errors}
    end
  end

  def from_inline(_value, errors) do
    {nil, Parse.error(errors, ["operations"], "must be an array of tables")}
  end

  defp operations_from(raw, path, errors) do
    case Map.fetch(raw, "operations") do
      :error ->
        {[], errors}

      {:ok, list} when is_list(list) ->
        {operations, errors} =
          list
          |> Enum.with_index()
          |> Enum.reduce({[], errors}, fn {raw_operation, index}, {operations, errors} ->
            {operation, errors} =
              Operation.from_map(raw_operation, errors, operation_path(path, index))

            {[operation | operations], errors}
          end)

        operations = Enum.reverse(operations)
        errors = duplicate_name_errors(operations, path, errors)
        {Enum.reject(operations, &is_nil/1), errors}

      {:ok, _value} ->
        {[], Parse.error(errors, path ++ ["operations"], "must be an array of tables")}
    end
  end

  defp operation_path(["__inline__"], index), do: ["operations", index]
  defp operation_path(path, index), do: path ++ ["operations", index]

  defp duplicate_name_errors(operations, path, errors) do
    operations
    |> Enum.with_index()
    |> Enum.reduce({MapSet.new(), errors}, fn
      {%Operation{name: name}, index}, {seen, errors} when is_binary(name) ->
        if MapSet.member?(seen, name) do
          errors =
            Parse.error(
              errors,
              operation_error_path(path, index, "name"),
              "duplicates operation #{inspect(name)}"
            )

          {seen, errors}
        else
          {MapSet.put(seen, name), errors}
        end

      {_operation, _index}, acc ->
        acc
    end)
    |> elem(1)
  end

  defp operation_error_path(["__inline__"], index, field), do: ["operations", index, field]

  defp operation_error_path(path, index, field),
    do: path ++ ["operations", index, field]
end
