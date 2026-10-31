defmodule Patchbay.Definition.Toolkit.Operation do
  @moduledoc """
  One fixed operation exposed by a toolkit instance or a lifecycle hook.

  `argv` is required and, when `executable` is omitted, its first element is
  the executable. Supplying `executable` explicitly makes `argv` the argument
  vector. `Patchbay.Worker.Operations.from_definition/1` converts validated
  declarations into the worker's fixed operation schema.

  Model-facing arguments may be declared in an `arguments` table or directly
  as child tables under the operation:

      [[operations]]
      name = "build"
      argv = ["nix", "build", "{%workspace}{target}"]

      [operations.arguments.target]
      type = "string"

      [operations.mode]
      type = "enum"
      values = ["dev", "prod"]

  Lifecycle hooks use `from_hook_map/3` and may reference fixed variables only.
  """

  alias Patchbay.Definition.Error
  alias Patchbay.Definition.Parse
  alias Patchbay.Definition.Toolkit.Argument
  alias Patchbay.Toolkit.Name
  alias Patchbay.Toolkit.Variables

  @reserved_keys ["name", "executable", "argv", "arguments", "description"]

  defstruct [:name, :executable, :argv, :description, arguments: %{}]

  @type t :: %__MODULE__{
          name: String.t() | nil,
          executable: String.t() | nil,
          argv: [String.t()] | nil,
          description: String.t() | nil,
          arguments: %{String.t() => Argument.t() | nil}
        }

  @spec from_map(term(), Parse.errors(), Error.path()) :: {t() | nil, Parse.errors()}
  def from_map(raw, errors, path) when is_map(raw) do
    {name, errors} = Parse.required_string(raw, "name", path ++ ["name"], errors)
    errors = validate_name(name, path ++ ["name"], errors)

    {description, errors} =
      Parse.optional_string(raw, "description", path ++ ["description"], errors)

    {executable, errors} = executable_from(raw, path, errors)
    {argv, errors} = argv_from(raw, executable, path, errors)
    {arguments, errors} = arguments_from(raw, path, errors)

    operation = %__MODULE__{
      name: name,
      executable: executable,
      argv: argv,
      description: description,
      arguments: arguments
    }

    errors = placeholder_errors(operation, path ++ ["argv"], errors)
    {operation, errors}
  end

  def from_map(_raw, errors, path) do
    {nil, Parse.error(errors, path, "must be a table")}
  end

  @doc """
  Parses a lifecycle hook.

  Hooks may use fixed variables only; declaring or referencing model arguments
  is an error.
  """
  @spec from_hook_map(term(), Parse.errors(), Error.path()) :: {t() | nil, Parse.errors()}
  def from_hook_map(raw, errors, path) when is_map(raw) do
    {name, errors} = Parse.required_string(raw, "name", path ++ ["name"], errors)
    errors = validate_name(name, path ++ ["name"], errors)

    {description, errors} =
      Parse.optional_string(raw, "description", path ++ ["description"], errors)

    {executable, errors} = executable_from(raw, path, errors)
    {argv, errors} = argv_from(raw, executable, path, errors)
    errors = reject_arguments(raw, path, errors)
    errors = validate_hook_executable(executable, argv, path, errors)

    operation = %__MODULE__{
      name: name,
      executable: executable,
      argv: argv,
      description: description,
      arguments: %{}
    }

    errors = placeholder_errors(operation, path ++ ["argv"], errors, mode: :hook)
    {operation, errors}
  end

  def from_hook_map(_raw, errors, path) do
    {nil, Parse.error(errors, path, "must be a table")}
  end

  @doc false
  @spec placeholder_errors(t(), Error.path(), Parse.errors(), keyword()) :: Parse.errors()
  def placeholder_errors(operation, path, errors, opts \\ [])

  def placeholder_errors(%__MODULE__{argv: argv, arguments: arguments}, path, errors, opts)
      when is_list(argv) do
    argv
    |> Variables.validate_argv(arguments || %{}, opts)
    |> Enum.reduce(errors, fn {index, issues}, errors ->
      Enum.reduce(issues, errors, fn issue, errors ->
        Parse.error(errors, path ++ [index], issue_message(issue))
      end)
    end)
  end

  def placeholder_errors(_operation, _path, errors, _opts), do: errors

  defp issue_message({:unknown_variable, name}) do
    "uses unsupported built-in variable #{inspect("%" <> name)}"
  end

  defp issue_message({:undeclared_argument, name}) do
    "references undeclared argument #{inspect(name)}"
  end

  defp issue_message({:model_argument_not_allowed, name}) do
    "lifecycle hooks cannot reference model argument #{inspect(name)}"
  end

  defp issue_message({:unsupported_shell_variable, match}) do
    "uses shell-style #{inspect(match)} (the sequence stays literal); write the {%name} form instead"
  end

  defp executable_from(raw, path, errors) do
    case Parse.optional_string(raw, "executable", path ++ ["executable"], errors) do
      {nil, errors} ->
        {nil, errors}

      {executable, errors} ->
        if Path.type(executable) == :absolute do
          {executable, errors}
        else
          {nil, Parse.error(errors, path ++ ["executable"], "must be an absolute path")}
        end
    end
  end

  defp argv_from(raw, executable, path, errors) do
    case Map.fetch(raw, "argv") do
      :error ->
        {nil, Parse.error(errors, path ++ ["argv"], "is required")}

      {:ok, value} ->
        {argv, errors} = Parse.string_list(value, path ++ ["argv"], errors, allow_empty: true)

        if is_nil(executable) and is_list(argv) and argv == [] do
          {nil, Parse.error(errors, path ++ ["argv"], "must not be empty")}
        else
          {argv, errors}
        end
    end
  end

  defp arguments_from(raw, path, errors) do
    {from_arguments, errors} = arguments_table(raw, path, errors)
    {from_slots, errors} = argument_slots(raw, path, errors)

    duplicates =
      from_arguments
      |> Map.keys()
      |> Enum.filter(&Map.has_key?(from_slots, &1))

    errors =
      Enum.reduce(duplicates, errors, fn name, errors ->
        Parse.error(errors, path ++ [name], "declares argument #{inspect(name)} more than once")
      end)

    {%{}, errors}
    |> merge_arguments(from_arguments)
    |> merge_arguments(from_slots)
    |> elem(0)
    |> then(&{&1, errors})
  end

  defp arguments_table(raw, path, errors) do
    case Map.fetch(raw, "arguments") do
      :error ->
        {%{}, errors}

      {:ok, arguments} when is_map(arguments) ->
        parse_arguments(arguments, path ++ ["arguments"], errors)

      {:ok, list} when is_list(list) ->
        list
        |> Enum.with_index()
        |> Enum.reduce({%{}, errors}, fn {declaration, index}, {arguments, errors} ->
          slot_path = path ++ ["arguments", index]

          case Map.fetch(declaration, "name") do
            {:ok, name} when is_binary(name) ->
              {argument, errors} = Argument.from_map(declaration, errors, slot_path)
              {Map.put(arguments, name, argument), errors}

            _other ->
              {arguments, Parse.error(errors, slot_path ++ ["name"], "is required")}
          end
        end)

      {:ok, _value} ->
        {%{}, Parse.error(errors, path ++ ["arguments"], "must be a table or array of tables")}
    end
  end

  defp argument_slots(raw, path, errors) do
    raw
    |> Enum.sort_by(fn {name, _value} -> name end)
    |> Enum.reduce({%{}, errors}, fn
      {name, declaration}, {arguments, errors}
      when is_map(declaration) and name not in @reserved_keys ->
        {argument, errors} = Argument.from_map(declaration, errors, path ++ [name])
        {Map.put(arguments, name, argument), errors}

      {_name, _value}, acc ->
        acc
    end)
  end

  defp parse_arguments(arguments, path, errors) do
    arguments
    |> Enum.sort_by(fn {name, _declaration} -> name end)
    |> Enum.reduce({%{}, errors}, fn {name, declaration}, {arguments, errors} ->
      {argument, errors} = Argument.from_map(declaration, errors, path ++ [name])
      {Map.put(arguments, name, argument), errors}
    end)
  end

  defp merge_arguments({arguments, errors}, more) do
    {Map.merge(arguments, more), errors}
  end

  defp reject_arguments(raw, path, errors) do
    declared = Map.get(raw, "arguments")
    slots = Enum.filter(Map.keys(raw), &(is_map(raw[&1]) and &1 not in @reserved_keys))

    cond do
      not is_nil(declared) ->
        Parse.error(errors, path ++ ["arguments"], "lifecycle hooks cannot declare arguments")

      slots != [] ->
        Parse.error(errors, path, "lifecycle hooks cannot declare arguments")

      true ->
        errors
    end
  end

  defp validate_hook_executable(nil, [executable | _args], path, errors) do
    if is_binary(executable) and Path.type(executable) == :absolute do
      errors
    else
      Parse.error(errors, path ++ ["argv", 0], "must be an absolute path")
    end
  end

  defp validate_hook_executable(_executable, _argv, _path, errors), do: errors

  defp validate_name(nil, _path, errors), do: errors

  defp validate_name(name, path, errors) do
    if Name.valid?(name) do
      errors
    else
      Parse.error(
        errors,
        path,
        "must be a provider-safe identifier of 1-64 letters, digits, underscores, or hyphens"
      )
    end
  end
end
