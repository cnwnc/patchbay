defmodule Patchbay.Toolkit.Manifest do
  @moduledoc """
  A toolkit manifest loaded from `priv/toolkits` or `config/toolkits`.

  A manifest names one toolkit and may reference a registered native toolkit
  by identifier, declare fixed argv operations, or both. The module name never
  appears in TOML, so manifests cannot load Elixir at runtime.

      name = "shell"
      description = "Workspace shell helpers"
      native = "terminal"
      implicit = true
      tools = ["complete_task"]

      [[operations]]
      name = "echo"
      executable = "/bin/sh"
      argv = ["-c", 'echo "$1"', "sh", "{text}"]

      [operations.arguments.text]
      type = "string"

  The `[toolkit]` table form is accepted as well as top-level keys.
  """

  alias Patchbay.Definition.Error
  alias Patchbay.Definition.Parse
  alias Patchbay.Definition.Toolkit.Operation

  defstruct [
    :name,
    :description,
    :native,
    :path,
    implicit: false,
    tools: [],
    config: %{},
    operations: []
  ]

  @type t :: %__MODULE__{
          name: String.t() | nil,
          description: String.t() | nil,
          native: String.t() | nil,
          path: Path.t() | nil,
          implicit: boolean(),
          tools: [String.t()],
          config: map(),
          operations: [Operation.t()]
        }

  @name_regex ~r/\A[a-z0-9][a-z0-9._-]{0,63}\z/
  @implicit_native "terminal"

  @builtin_dir Path.expand("../../../priv/toolkits", __DIR__)
  @builtin_paths Path.wildcard(Path.join(@builtin_dir, "*.toml"))
  @builtin_sources Map.new(@builtin_paths, fn path ->
                     {Path.basename(path, ".toml"), {path, File.read!(path)}}
                   end)

  for path <- @builtin_paths do
    @external_resource path
  end

  @doc "Manifest directory names under the application and a configuration root."
  @spec relative_dirs() :: [Path.t()]
  def relative_dirs, do: ["toolkits"]

  @doc "Names of manifests embedded at compile time."
  @spec builtin_names() :: [String.t()]
  def builtin_names, do: @builtin_sources |> Map.keys() |> Enum.sort()

  @doc "Default manifest search directories, highest priority first."
  @spec dirs(keyword()) :: [Path.t()]
  def dirs(opts \\ []) do
    case Keyword.get(opts, :toolkit_dirs) do
      dirs when is_list(dirs) ->
        Enum.map(dirs, &Path.expand/1)

      nil ->
        config_dirs(Keyword.get(opts, :config_root)) ++ priv_dirs()
    end
  end

  @doc "Loads a manifest by toolkit name from `dirs/1` or the embedded built-ins."
  @spec load(String.t(), keyword()) :: {:ok, t()} | {:error, %Error{}} | :error
  def load(name, opts \\ []) when is_binary(name) do
    if Regex.match?(@name_regex, name) do
      case find_manifest_file(dirs(opts), name) do
        {:ok, path} -> load_file(path)
        :error -> load_builtin(name)
      end
    else
      :error
    end
  end

  @doc "Loads and validates one manifest file."
  @spec load_file(Path.t()) :: {:ok, t()} | {:error, %Error{}}
  def load_file(path) when is_binary(path) do
    with {:ok, body} <- read(path) do
      load_source(body, path)
    end
  end

  @doc "Validates an already-decoded manifest map."
  @spec from_map(map(), Path.t() | nil, Parse.errors()) :: {t() | nil, Parse.errors()}
  def from_map(raw, path \\ nil, errors \\ [])

  def from_map(raw, path, errors) when is_map(raw) do
    body =
      case Map.get(raw, "toolkit") do
        %{} = toolkit -> toolkit
        _other -> raw
      end

    prefix = if Map.has_key?(raw, "toolkit"), do: ["toolkit"], else: []

    {name, errors} =
      case Parse.optional_string(body, "name", prefix ++ ["name"], errors) do
        {nil, errors} ->
          inferred = if path, do: Path.rootname(Path.basename(path)), else: nil
          {inferred, errors}

        result ->
          result
      end

    {description, errors} =
      Parse.optional_string(body, "description", prefix ++ ["description"], errors)

    {native, errors} = Parse.optional_string(body, "native", prefix ++ ["native"], errors)

    {implicit, errors} =
      Parse.optional_boolean(body, "implicit", prefix ++ ["implicit"], false, errors)

    {tools, errors} = tools_from(body, prefix, errors)
    {config, errors} = Parse.optional_map(body, "config", prefix ++ ["config"], errors)

    {operations, errors} =
      operations_from(body, prefix ++ ["operations"], errors)

    errors = validate_native(native, prefix ++ ["native"], errors)
    errors = validate_name(name, prefix ++ ["name"], errors)

    manifest = %__MODULE__{
      name: name,
      description: description,
      native: native,
      path: path,
      implicit: implicit,
      tools: tools,
      config: config || %{},
      operations: operations
    }

    {manifest, errors}
  end

  def from_map(_raw, _path, errors) do
    {nil, Parse.error(errors, [], "must be a table")}
  end

  @doc "Merges a resolved manifest into a definition toolkit declaration."
  @spec merge(map(), t()) :: map()
  def merge(toolkit, %__MODULE__{} = manifest) do
    operations = merge_operations(manifest.operations, Map.get(toolkit, :operations, []))

    toolkit
    |> Map.put(:description, manifest.description || Map.get(toolkit, :description))
    |> Map.put(:native, manifest.native)
    |> Map.put(:tools, manifest.tools)
    |> Map.put(:manifest_path, manifest.path)
    |> Map.put(:config, Map.merge(manifest.config, Map.get(toolkit, :config, %{})))
    |> Map.put(:operations, operations)
  end

  @doc """
  Loads every implicit manifest found in `dirs/1` plus the embedded built-ins.

  Implicit tools are global to every agent, so only manifests that resolve to
  the built-in terminal toolkit are considered. A configuration manifest may
  override the terminal manifest, but it cannot introduce another implicit
  native toolkit into every agent's tool list.
  """
  @spec implicit(keyword()) :: [t()]
  def implicit(opts \\ []) do
    from_dirs = opts |> dirs() |> Enum.flat_map(&implicit_in_dir/1)
    from_builtins = builtin_manifests()

    (from_dirs ++ from_builtins)
    |> Enum.filter(&(&1.implicit and &1.native == @implicit_native))
    |> Enum.reduce(%{}, fn manifest, acc -> Map.put_new(acc, manifest.name, manifest) end)
    |> Map.values()
  end

  defp implicit_in_dir(dir) do
    entries =
      case File.ls(dir) do
        {:ok, entries} -> entries
        {:error, _reason} -> []
      end

    entries
    |> Enum.sort()
    |> Enum.filter(&(Path.extname(&1) == ".toml"))
    |> Enum.flat_map(fn entry ->
      case load_file(Path.join(dir, entry)) do
        {:ok, %__MODULE__{implicit: true} = manifest} -> [manifest]
        _other -> []
      end
    end)
  end

  defp builtin_manifests do
    @builtin_sources
    |> Enum.sort_by(fn {name, _source} -> name end)
    |> Enum.flat_map(fn {_name, {path, body}} ->
      case load_source(body, path) do
        {:ok, %__MODULE__{} = manifest} -> [manifest]
        {:error, _error} -> []
      end
    end)
  end

  defp find_manifest_file(dirs, name) do
    Enum.find_value(dirs, :error, fn dir ->
      path = Path.join(dir, name <> ".toml")

      case File.stat(path) do
        {:ok, %File.Stat{type: :regular}} -> {:ok, path}
        _other -> nil
      end
    end)
  end

  defp load_builtin(name) do
    case Map.fetch(@builtin_sources, name) do
      {:ok, {path, body}} -> load_source(body, path)
      :error -> :error
    end
  end

  defp load_source(body, path) do
    with {:ok, raw} <- decode(body, path) do
      {manifest, errors} = from_map(raw, path, [])
      finish(manifest, errors, path)
    end
  rescue
    exception ->
      {:error,
       %Error{
         errors: [
           Error.issue([path], "invalid toolkit manifest: #{Exception.message(exception)}")
         ]
       }}
  catch
    kind, reason ->
      {:error,
       %Error{
         errors: [Error.issue([path], "invalid toolkit manifest: #{format_crash(kind, reason)}")]
       }}
  end

  defp format_crash(:throw, reason), do: "throw #{inspect(reason)}"
  defp format_crash(:exit, reason), do: "exit #{inspect(reason)}"
  defp format_crash(kind, reason), do: "#{kind} #{inspect(reason)}"

  defp merge_operations(manifest_operations, inline_operations) do
    inline =
      Map.new(inline_operations, fn operation -> {Map.get(operation, :name), operation} end)

    overridden = Map.keys(inline)

    manifest_operations
    |> Enum.map(fn operation -> Map.get(inline, Map.get(operation, :name), operation) end)
    |> Enum.concat(Enum.reject(inline_operations, &(Map.get(&1, :name) in overridden)))
  end

  defp tools_from(body, prefix, errors) do
    case Map.fetch(body, "tools") do
      :error ->
        {[], errors}

      {:ok, tools} ->
        Parse.string_list(tools, prefix ++ ["tools"], errors, allow_empty: true)
    end
  end

  defp operations_from(body, path, errors) do
    case Map.fetch(body, "operations") do
      :error ->
        {[], errors}

      {:ok, list} when is_list(list) ->
        {operations, errors} =
          list
          |> Enum.with_index()
          |> Enum.reduce({[], errors}, fn {raw, index}, {operations, errors} ->
            {operation, errors} = Operation.from_map(raw, errors, path ++ [index])
            {[operation | operations], errors}
          end)

        operations = Enum.reverse(operations)
        {Enum.reject(operations, &is_nil/1), errors}

      {:ok, _value} ->
        {[], Parse.error(errors, path, "must be an array of tables")}
    end
  end

  defp validate_name(nil, _path, errors), do: errors

  defp validate_name(name, path, errors) do
    if String.valid?(name) and Regex.match?(@name_regex, name) do
      errors
    else
      Parse.error(errors, path, "must be a lowercase toolkit identifier")
    end
  end

  defp validate_native(nil, _path, errors), do: errors

  defp validate_native(native, path, errors) do
    if Patchbay.Toolkit.Registry.native_module(native) do
      errors
    else
      Parse.error(errors, path, "references unknown native toolkit #{inspect(native)}")
    end
  end

  defp finish(nil, errors, _path) do
    {:error, %Error{errors: Enum.reverse(errors)}}
  end

  defp finish(%__MODULE__{} = manifest, errors, _path) do
    case Enum.reverse(errors) do
      [] -> {:ok, manifest}
      errors -> {:error, %Error{errors: errors}}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, body} ->
        {:ok, body}

      {:error, reason} ->
        {:error,
         %Error{
           errors: [
             Error.issue([path], "cannot read toolkit manifest: #{:file.format_error(reason)}")
           ]
         }}
    end
  end

  defp decode(body, path) do
    case TomlElixir.decode(body) do
      {:ok, raw} when is_map(raw) ->
        {:ok, raw}

      {:ok, _other} ->
        {:error, %Error{errors: [Error.issue([path], "must be a table")]}}

      {:error, exception} ->
        {:error,
         %Error{
           errors: [Error.issue([path], "invalid TOML: #{Exception.message(exception)}")]
         }}
    end
  rescue
    exception ->
      {:error,
       %Error{errors: [Error.issue([path], "invalid TOML: #{Exception.message(exception)}")]}}
  end

  defp priv_dirs do
    case :code.priv_dir(:patchbay) do
      dir when is_list(dir) -> [Path.join(to_string(dir), "toolkits")]
      _other -> []
    end
  end

  defp config_dirs(nil), do: []

  defp config_dirs(config_root) do
    Enum.map(relative_dirs(), &Path.join(config_root, &1))
  end
end
