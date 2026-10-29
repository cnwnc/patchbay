defmodule Patchbay.Definition.Toolkit.Argument do
  @moduledoc """
  A typed model-facing argument for a fixed operation.
  """

  alias Patchbay.Definition.Error
  alias Patchbay.Definition.Parse

  @types %{
    "string" => :string,
    "number" => :number,
    "integer" => :integer,
    "boolean" => :boolean,
    "enum" => :enum,
    "path" => :path,
    "file" => :file,
    "directory" => :directory
  }

  defstruct type: nil, values: nil, required: nil

  @type type ::
          :string | :number | :integer | :boolean | :enum | :path | :file | :directory

  @type t :: %__MODULE__{
          type: type() | nil,
          values: [String.t()] | nil,
          required: boolean() | nil
        }

  @spec from_map(term(), Parse.errors(), Error.path()) :: {t() | nil, Parse.errors()}
  def from_map(raw, errors, path) when is_map(raw) do
    {type, errors} = Parse.required_enum(raw, "type", path ++ ["type"], @types, errors)
    {values, errors} = values_from(raw, type, path, errors)

    {required, errors} =
      Parse.optional_boolean(raw, "required", path ++ ["required"], nil, errors)

    {%__MODULE__{type: type, values: values, required: required}, errors}
  end

  def from_map(_raw, errors, path) do
    {nil, Parse.error(errors, path, "must be a table")}
  end

  defp values_from(raw, :enum, path, errors) do
    case Map.fetch(raw, "values") do
      :error ->
        {nil, Parse.error(errors, path ++ ["values"], "is required for an enum argument")}

      {:ok, value} ->
        {values, errors} = Parse.string_list(value, path ++ ["values"], errors)

        if values == [] do
          {nil, Parse.error(errors, path ++ ["values"], "must not be empty")}
        else
          {values, errors}
        end
    end
  end

  defp values_from(raw, _type, path, errors) do
    if Map.has_key?(raw, "values") do
      {nil, Parse.error(errors, path ++ ["values"], "is only valid for an enum argument")}
    else
      {nil, errors}
    end
  end
end
