defmodule Patchbay.Definition.Parse do
  @moduledoc false

  alias Patchbay.Definition.Error

  @type errors :: [Error.issue()]
  @type enum_map :: %{String.t() => atom()}

  @spec error(errors(), Error.path(), String.t()) :: errors()
  def error(errors, path, message), do: [Error.issue(path, message) | errors]

  @spec required_string(map(), String.t(), Error.path(), errors()) ::
          {String.t() | nil, errors()}
  def required_string(map, key, path, errors) do
    case Map.fetch(map, key) do
      :error -> {nil, error(errors, path, "is required")}
      {:ok, value} -> validate_string(value, path, errors)
    end
  end

  @spec optional_string(map(), String.t(), Error.path(), errors()) ::
          {String.t() | nil, errors()}
  def optional_string(map, key, path, errors) do
    case Map.fetch(map, key) do
      :error -> {nil, errors}
      {:ok, value} -> validate_string(value, path, errors)
    end
  end

  @spec required_integer(map(), String.t(), Error.path(), errors()) ::
          {integer() | nil, errors()}
  def required_integer(map, key, path, errors) do
    case Map.fetch(map, key) do
      :error -> {nil, error(errors, path, "is required")}
      {:ok, value} -> validate_integer(value, path, errors)
    end
  end

  @spec optional_integer(map(), String.t(), Error.path(), errors()) ::
          {integer() | nil, errors()}
  def optional_integer(map, key, path, errors) do
    case Map.fetch(map, key) do
      :error -> {nil, errors}
      {:ok, value} -> validate_integer(value, path, errors)
    end
  end

  @spec optional_boolean(map(), String.t(), Error.path(), boolean(), errors()) ::
          {boolean(), errors()}
  def optional_boolean(map, key, path, default, errors) do
    case Map.fetch(map, key) do
      :error -> {default, errors}
      {:ok, value} when is_boolean(value) -> {value, errors}
      {:ok, _value} -> {default, error(errors, path, "must be a boolean")}
    end
  end

  @spec optional_enum(map(), String.t(), Error.path(), enum_map(), errors()) ::
          {atom() | nil, errors()}
  def optional_enum(map, key, path, mapping, errors) do
    case Map.fetch(map, key) do
      :error ->
        {nil, errors}

      {:ok, value} when is_binary(value) ->
        case Map.fetch(mapping, value) do
          {:ok, atom} -> {atom, errors}
          :error -> {nil, error(errors, path, enum_message(mapping))}
        end

      {:ok, _value} ->
        {nil, error(errors, path, "must be a string")}
    end
  end

  @spec required_enum(map(), String.t(), Error.path(), enum_map(), errors()) ::
          {atom() | nil, errors()}
  def required_enum(map, key, path, mapping, errors) do
    if Map.has_key?(map, key) do
      optional_enum(map, key, path, mapping, errors)
    else
      {nil, error(errors, path, "is required")}
    end
  end

  @spec optional_map(map(), String.t(), Error.path(), errors()) :: {map() | nil, errors()}
  def optional_map(map, key, path, errors) do
    case Map.fetch(map, key) do
      :error -> {nil, errors}
      {:ok, value} when is_map(value) -> {value, errors}
      {:ok, _value} -> {nil, error(errors, path, "must be a table")}
    end
  end

  @spec string_list(term(), Error.path(), errors(), keyword()) ::
          {[String.t()] | nil, errors()}
  def string_list(value, path, errors, opts \\ []) do
    allow_empty? = Keyword.get(opts, :allow_empty, false)

    if is_list(value) do
      {strings, errors} =
        value
        |> Enum.with_index()
        |> Enum.reduce({[], errors}, fn {entry, index}, {strings, errors} ->
          cond do
            allow_empty? and entry == "" ->
              {["" | strings], errors}

            true ->
              case validate_string(entry, path ++ [index], errors) do
                {nil, errors} -> {strings, errors}
                {entry, errors} -> {[entry | strings], errors}
              end
          end
        end)

      if length(strings) == length(value) do
        {Enum.reverse(strings), errors}
      else
        {nil, errors}
      end
    else
      {nil, error(errors, path, "must be a list of strings")}
    end
  end

  defp validate_string(value, path, errors) when is_binary(value) do
    if String.trim(value) == "" do
      {nil, error(errors, path, "must not be empty")}
    else
      {value, errors}
    end
  end

  defp validate_string(_value, path, errors) do
    {nil, error(errors, path, "must be a string")}
  end

  defp validate_integer(value, _path, errors) when is_integer(value) and value >= 0 do
    {value, errors}
  end

  defp validate_integer(value, path, errors) when is_integer(value) do
    {nil, error(errors, path, "must not be negative, got #{value}")}
  end

  defp validate_integer(_value, path, errors) do
    {nil, error(errors, path, "must be an integer")}
  end

  defp enum_message(mapping) do
    values = mapping |> Map.keys() |> Enum.sort() |> Enum.map_join(", ", &inspect/1)
    "must be one of #{values}"
  end
end
