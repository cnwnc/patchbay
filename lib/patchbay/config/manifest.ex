defmodule Patchbay.Config.Manifest do
  @moduledoc """
  Reads, creates, and edits toolkit manifest files below `<config_dir>/toolkits`.

  Manifests embedded in the application are listed read-only; a configuration
  manifest with the same file name is editable and overrides the embedded one.
  Saves use `Patchbay.Config.File` for revision-checked atomic replacement and
  are validated with `Patchbay.Toolkit.Manifest` before any bytes are written.
  The structured form is rendered through `TomlElixir.Document`, so comments
  and keys the form does not cover survive a save.
  """

  alias Patchbay.Config
  alias Patchbay.Config.File, as: ConfigFile
  alias Patchbay.Definition.Error
  alias Patchbay.Toolkit.Manifest
  alias Patchbay.Toolkit.Name
  alias Patchbay.Toolkit.Registry
  alias TomlElixir.Document

  @id_regex ~r/\A[a-z0-9][a-z0-9._-]{0,63}\z/
  @env_line_regex ~r/\A([A-Za-z_][A-Za-z0-9_]*)=(.*)\z/

  @type entry :: %{
          id: String.t(),
          name: String.t() | nil,
          path: Path.t() | nil,
          source: :config | :builtin,
          description: String.t() | nil,
          native: String.t() | nil,
          tools: [String.t()],
          implicit: boolean(),
          operations: [String.t()],
          error: String.t() | nil,
          builtin_override?: boolean()
        }

  @type form :: %{String.t() => term()}

  @doc "Returns true when `id` can name a configuration manifest file."
  @spec valid_id?(term()) :: boolean()
  def valid_id?(id) when is_binary(id) do
    String.valid?(id) and Regex.match?(@id_regex, id)
  end

  def valid_id?(_id), do: false

  @doc "Registered native toolkit identifiers offered by the editor."
  @spec native_ids() :: [String.t()]
  def native_ids, do: Registry.ids()

  @doc "Tool names registered by a native toolkit, or an empty list."
  @spec native_tools(String.t() | nil) :: [String.t()]
  def native_tools(native) when is_binary(native) and native != "" do
    case Registry.native_module(native) do
      nil -> []
      module -> Registry.tools(module, %{}) |> Enum.map(& &1.name) |> Enum.sort()
    end
  end

  def native_tools(_native), do: []

  @doc "Resolves a manifest file path below the configuration toolkits directory."
  @spec path(Config.t() | Path.t(), String.t()) ::
          {:ok, Path.t()} | {:error, :invalid_id | :invalid_config}
  def path(config, id) do
    with {:ok, directory} <- config_dir(config) do
      if valid_id?(id) do
        toolkits = Path.expand(Path.join(directory, "toolkits"))
        path = Path.expand(Path.join([toolkits, id <> ".toml"]))

        cond do
          Path.dirname(path) != toolkits -> {:error, :invalid_id}
          true -> safe_toolkits_directory(toolkits, path)
        end
      else
        {:error, :invalid_id}
      end
    end
  end

  @doc """
  Lists configuration manifests followed by embedded manifests.

  A configuration manifest whose file name matches an embedded manifest is
  listed once, as the editable configuration entry.
  """
  @spec entries(Config.t() | Path.t()) :: [entry()]
  def entries(config) do
    config_entries = config_entries(config)
    overridden = MapSet.new(config_entries, & &1.id)

    config_entries ++
      (Manifest.builtin_names()
       |> Enum.reject(&MapSet.member?(overridden, &1))
       |> Enum.map(&builtin_entry/1))
  end

  @doc "Fetches one manifest entry."
  @spec get(Config.t() | Path.t(), String.t()) ::
          {:ok, entry()} | {:error, :not_found | :invalid_id | :invalid_config}
  def get(config, id) do
    with {:ok, path} <- path(config, id) do
      case File.lstat(path) do
        {:ok, %File.Stat{type: :regular}} ->
          {:ok, config_entry(id, path, builtin?(id))}

        {:ok, %File.Stat{type: :symlink}} ->
          {:error, :unsafe_path}

        {:ok, _stat} ->
          {:error, :unsafe_path}

        {:error, :enoent} ->
          if builtin?(id), do: {:ok, builtin_entry(id)}, else: {:error, :not_found}

        {:error, reason} ->
          {:error, {:io, reason}}
      end
    end
  end

  @doc """
  Reads one manifest's text and digest.

  Embedded manifests are returned with `read_only?: true`.
  """
  @spec read(Config.t() | Path.t(), String.t()) ::
          {:ok,
           %{
             entry: entry(),
             content: String.t(),
             hash: String.t(),
             path: Path.t(),
             read_only?: boolean()
           }}
          | {:error, term()}
  def read(config, id) do
    with {:ok, entry} <- get(config, id) do
      case entry.source do
        :builtin ->
          case Manifest.builtin_source(id) do
            {:ok, path, content} ->
              {:ok,
               %{
                 entry: entry,
                 content: content,
                 hash: ConfigFile.hash(content),
                 path: path,
                 read_only?: true
               }}

            :error ->
              {:error, :not_found}
          end

        :config ->
          case ConfigFile.read(entry.path) do
            {:ok, %{content: content, hash: hash}} ->
              {:ok,
               %{
                 entry: entry,
                 content: content,
                 hash: hash,
                 path: entry.path,
                 read_only?: false
               }}

            {:error, reason} ->
              {:error, reason}
          end
      end
    end
  end

  @doc """
  Creates a new configuration manifest.

  The file is written only while it does not exist. A manifest that shares a
  name with an embedded manifest is allowed and becomes an override.
  """
  @spec create(Config.t() | Path.t(), String.t(), keyword()) ::
          {:ok, entry()} | {:error, term()}
  def create(config, id, opts \\ []) do
    native = Keyword.get(opts, :native)
    native = if is_binary(native), do: String.trim(native), else: ""
    content = template(id, native)

    with {:ok, path} <- path(config, id),
         :ok <- ensure_toolkits_dir(config),
         :ok <- validate_native(native),
         :ok <- validate_source(content, path),
         {:ok, _written} <-
           ConfigFile.write(path, content, :absent, guard: fn -> ensure_toolkits_dir(config) end) do
      {:ok, config_entry(id, path, builtin?(id))}
    else
      {:error, :stale} -> {:error, :exists}
      {:error, {:io, :eexist}} -> {:error, :exists}
      {:error, {:invalid, message}} -> {:error, {:invalid, message}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Replaces a configuration manifest after validating the new text.

  Returns `{:error, :read_only}` for an embedded manifest with no
  configuration override.
  """
  @spec write(Config.t() | Path.t(), String.t(), String.t(), String.t() | :absent | nil) ::
          {:ok, %{path: Path.t(), hash: String.t()}} | {:error, term()}
  def write(config, id, content, expected_hash) when is_binary(content) do
    with {:ok, path} <- path(config, id),
         :ok <- ensure_configurable(path),
         :ok <- validate_source(content, path) do
      ConfigFile.write(path, content, expected_hash, guard: fn -> ensure_toolkits_dir(config) end)
    end
  end

  @doc "A minimal valid manifest for `id`."
  @spec template(String.t(), String.t()) :: String.t()
  def template(id, native \\ "")

  def template(id, native) when is_binary(id) do
    native_line =
      if is_binary(native) and native != "", do: "native = #{inspect(native)}\n", else: ""

    """
    name = #{inspect(id)}
    #{native_line}
    # Fixed operations can be added in the structured editor.
    """
  end

  @doc "Parses a manifest into an editable document and structured form."
  @spec load(String.t(), Path.t() | nil) ::
          {:ok, %{document: Document.t(), form: form(), manifest: map() | nil, errors: term()}}
          | {:error, String.t()}
  def load(source, path) when is_binary(source) do
    case Document.parse(source) do
      {:ok, document} ->
        data = Document.to_map(document)
        {manifest, errors} = Manifest.from_map(data, path, [])

        {:ok,
         %{document: document, form: form_from_data(data), manifest: manifest, errors: errors}}

      {:error, exception} ->
        {:error, "Cannot parse manifest: #{Exception.message(exception)}"}
    end
  end

  @doc "Builds form state from submitted parameters, keeping omitted fields."
  @spec form_from_params(form() | nil, form()) :: form()
  def form_from_params(params, current) when is_map(params) do
    current = current || empty_form()

    %{
      "table" => current["table"] || "",
      "name" => text_value(params, current, "name"),
      "description" => text_value(params, current, "description"),
      "implicit" => text_value(params, current, "implicit"),
      "native" => text_value(params, current, "native"),
      "tools" => text_value(params, current, "tools"),
      "config_root" => text_value(params, current, "config_root"),
      "config_namespace" => text_value(params, current, "config_namespace"),
      "config_env" => text_value(params, current, "config_env"),
      "operations" => operations_from_params(params["operations"], current["operations"])
    }
  end

  def form_from_params(_params, current), do: current || empty_form()

  @spec add_operation(form()) :: form()
  def add_operation(form) do
    Map.update!(form, "operations", &(&1 ++ [empty_operation()]))
  end

  @spec remove_operation(form(), non_neg_integer()) :: form()
  def remove_operation(form, index) do
    Map.update!(form, "operations", &List.delete_at(&1, index))
  end

  @doc """
  Applies a structured form to a parsed manifest and validates the result.
  """
  @spec build(Document.t(), form(), String.t(), Path.t() | nil) ::
          {:ok, String.t()} | {:error, String.t()}
  def build(document, form, id, config_dir) do
    with :ok <- validate_form(form, id),
         {:ok, document} <- apply_form(document, form, id),
         content = Document.to_string(document),
         {:ok, _manifest} <- validate_source_with_manifest(content, path_for_id(config_dir, id)) do
      {:ok, content}
    end
  end

  defp config_entries(config) do
    with {:ok, directory} <- config_dir(config) do
      toolkits = Path.expand(Path.join(directory, "toolkits"))

      case File.lstat(toolkits) do
        {:ok, %File.Stat{type: :directory}} -> list_config_entries(toolkits)
        _other -> []
      end
    else
      _other -> []
    end
  end

  defp list_config_entries(toolkits) do
    case File.ls(toolkits) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.valid?/1)
        |> Enum.filter(&(Path.extname(&1) == ".toml"))
        |> Enum.sort()
        |> Enum.map(&Path.join(toolkits, &1))
        |> Enum.filter(&regular_file?/1)
        |> Enum.map(fn path ->
          id = Path.basename(path, ".toml")
          config_entry(id, path, builtin?(id))
        end)

      {:error, _reason} ->
        []
    end
  end

  defp safe_toolkits_directory(toolkits, path) do
    case File.lstat(toolkits) do
      {:ok, %File.Stat{type: :directory}} -> {:ok, path}
      {:ok, _stat} -> {:error, :unsafe_path}
      {:error, :enoent} -> {:ok, path}
      {:error, reason} -> {:error, {:io, reason}}
    end
  end

  defp regular_file?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> true
      _other -> false
    end
  end

  defp config_entry(id, path, builtin_override?) do
    if valid_id?(id) do
      loaded_config_entry(id, path, builtin_override?)
    else
      invalid_id_entry(id, path, builtin_override?)
    end
  end

  defp loaded_config_entry(id, path, builtin_override?) do
    case safe_load_file(path) do
      {:ok, manifest} ->
        %{
          id: id,
          name: manifest.name,
          path: path,
          source: :config,
          description: manifest.description,
          native: manifest.native,
          tools: manifest.tools,
          implicit: manifest.implicit,
          operations: Enum.map(manifest.operations, & &1.name),
          error: nil,
          builtin_override?: builtin_override?
        }

      {:error, message} ->
        %{
          id: id,
          name: nil,
          path: path,
          source: :config,
          description: nil,
          native: nil,
          tools: [],
          implicit: false,
          operations: [],
          error: message,
          builtin_override?: builtin_override?
        }
    end
  end

  defp invalid_id_entry(id, path, builtin_override?) do
    %{
      id: id,
      name: nil,
      path: path,
      source: :config,
      description: nil,
      native: nil,
      tools: [],
      implicit: false,
      operations: [],
      error:
        "the file name is not a valid manifest ID; rename it to lowercase letters, digits, dots, underscores, or dashes",
      builtin_override?: builtin_override?
    }
  end

  defp builtin_entry(id) do
    case Manifest.load(id, toolkit_dirs: []) do
      {:ok, manifest} ->
        %{
          id: id,
          name: manifest.name,
          path: manifest.path,
          source: :builtin,
          description: manifest.description,
          native: manifest.native,
          tools: manifest.tools,
          implicit: manifest.implicit,
          operations: Enum.map(manifest.operations, & &1.name),
          error: nil,
          builtin_override?: false
        }

      {:error, %Error{} = error} ->
        %{
          id: id,
          name: nil,
          path: nil,
          source: :builtin,
          description: nil,
          native: nil,
          tools: [],
          implicit: false,
          operations: [],
          error: Error.message(error),
          builtin_override?: false
        }

      :error ->
        %{
          id: id,
          name: nil,
          path: nil,
          source: :builtin,
          description: nil,
          native: nil,
          tools: [],
          implicit: false,
          operations: [],
          error: "manifest is not available",
          builtin_override?: false
        }
    end
  end

  defp safe_load_file(path) do
    case Manifest.load_file(path) do
      {:ok, manifest} -> {:ok, manifest}
      {:error, %Error{} = error} -> {:error, Error.message(error)}
      {:error, reason} -> {:error, inspect(reason)}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
  end

  defp builtin?(id) do
    id in Manifest.builtin_names()
  end

  defp ensure_toolkits_dir(config) do
    with {:ok, directory} <- config_dir(config) do
      toolkits = Path.expand(Path.join(directory, "toolkits"))

      cond do
        File.dir?(toolkits) -> ensure_real_directory(toolkits)
        File.exists?(toolkits) -> {:error, :unsafe_path}
        true -> create_toolkits_dir(toolkits)
      end
    end
  end

  defp create_toolkits_dir(toolkits) do
    case File.mkdir_p(toolkits) do
      :ok -> ensure_real_directory(toolkits)
      {:error, reason} -> {:error, {:io, reason}}
    end
  end

  defp ensure_real_directory(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, _stat} -> {:error, :unsafe_path}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, {:io, reason}}
    end
  end

  defp ensure_configurable(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, %File.Stat{type: :symlink}} -> {:error, :unsafe_path}
      {:ok, %File.Stat{}} -> {:error, :unsafe_path}
      {:error, :enoent} -> {:error, :read_only}
      {:error, reason} -> {:error, {:io, reason}}
    end
  end

  defp validate_native(""), do: :ok

  defp validate_native(native) do
    if Registry.native_module(native),
      do: :ok,
      else: {:error, {:invalid, "unknown native toolkit"}}
  end

  defp validate_source(source, path) do
    case validate_source_with_manifest(source, path) do
      {:ok, _manifest} -> :ok
      {:error, message} -> {:error, {:invalid, message}}
    end
  end

  defp validate_source_with_manifest(source, path) do
    with {:ok, raw} <- decode(source),
         {manifest, errors} <- Manifest.from_map(raw, path, []) do
      case Enum.reverse(errors) do
        [] -> {:ok, manifest}
        errors -> {:error, error_text(errors)}
      end
    end
  rescue
    exception -> {:error, "Generated TOML is invalid: #{Exception.message(exception)}"}
  end

  defp decode(source) do
    case TomlElixir.decode(source) do
      {:ok, raw} when is_map(raw) -> {:ok, raw}
      {:ok, _value} -> {:error, "manifest must be a table"}
      {:error, exception} -> {:error, "Invalid TOML: #{Exception.message(exception)}"}
    end
  end

  defp error_text(errors) when is_list(errors) do
    errors
    |> Enum.map(fn
      %{message: message, path: path} -> "#{Enum.join(path, ".")}: #{message}"
      %Error{errors: errors} -> error_text(errors)
      other -> inspect(other)
    end)
    |> Enum.join("; ")
  end

  defp error_text(other), do: inspect(other)

  defp validate_form(form, id) do
    with :ok <- validate_manifest_name(form["name"], id),
         :ok <- form_native_error(string(form["native"])),
         :ok <- validate_operations(form["operations"] || []) do
      :ok
    end
  end

  defp form_native_error(native) do
    case validate_native(native) do
      :ok -> :ok
      {:error, {:invalid, message}} -> {:error, message}
    end
  end

  defp validate_manifest_name("", _id), do: :ok

  defp validate_manifest_name(name, id) do
    name = String.trim(string(name))

    if name == "" or name == id or valid_id?(name) do
      :ok
    else
      {:error, "manifest name must be a lowercase identifier"}
    end
  end

  defp validate_operations(operations) do
    operations
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {operation, index}, :ok ->
      name = String.trim(string(operation["name"]))
      executable = String.trim(string(operation["executable"]))
      argv = value_lines(operation["argv"])

      cond do
        name == "" ->
          {:halt, {:error, "operation #{index + 1} requires a name"}}

        not Name.valid?(name) ->
          {:halt, {:error, "operation #{index + 1} has an invalid name"}}

        executable == "" and argv == [] ->
          {:halt, {:error, "operation #{index + 1} requires an executable or arguments"}}

        executable == "" and String.trim(List.first(argv)) == "" ->
          {:halt, {:error, "operation #{index + 1} requires an executable"}}

        true ->
          {:cont, :ok}
      end
    end)
    |> case do
      :ok -> duplicate_operation_names(operations)
      error -> error
    end
  end

  defp duplicate_operation_names(operations) do
    names =
      operations
      |> Enum.map(&(string(&1["name"]) |> String.trim()))
      |> Enum.reject(&(&1 == ""))

    if length(names) == Enum.count(Enum.uniq(names)) do
      :ok
    else
      {:error, "operation names must be unique"}
    end
  end

  defp apply_form(document, form, id) do
    prefix = table_prefix(form["table"])

    with {:ok, document} <- put_string(document, prefix ++ ["description"], form["description"]),
         {:ok, document} <- put_name(document, prefix, form["name"], id),
         {:ok, document} <- put_boolean(document, prefix ++ ["implicit"], form["implicit"]),
         {:ok, document} <- put_optional_string(document, prefix ++ ["native"], form["native"]),
         {:ok, document} <- put_list(document, prefix ++ ["tools"], value_lines(form["tools"])),
         {:ok, document} <- apply_config(document, prefix, form),
         {:ok, document} <- apply_operations(document, prefix, form["operations"]) do
      {:ok, document}
    end
  end

  defp put_name(document, prefix, name, id) do
    case String.trim(string(name)) do
      "" -> put_optional_string(document, prefix ++ ["name"], id)
      name -> put_optional_string(document, prefix ++ ["name"], name)
    end
  end

  defp apply_config(document, prefix, form) do
    with {:ok, document} <-
           put_config_string(document, prefix ++ ["config", "root"], form["config_root"]),
         {:ok, document} <-
           put_config_string(
             document,
             prefix ++ ["config", "namespace"],
             form["config_namespace"]
           ) do
      put_config_map(document, prefix ++ ["config", "env"], env_map(form["config_env"]))
    end
  end

  defp put_config_string(document, path, value) do
    put_optional_string(document, path, value)
  end

  defp put_config_map(document, path, map) when map == %{}, do: Document.delete(document, path)

  defp put_config_map(document, path, map) do
    Document.put(document, path, map)
  end

  defp apply_operations(document, prefix, operations) do
    path = prefix ++ ["operations"]

    operations =
      operations
      |> Enum.with_index()
      |> Enum.map(fn {operation, index} ->
        operation
        |> Map.put("_key", to_string(index))
        |> build_operation()
      end)

    put_list(document, path, operations)
  end

  defp build_operation(operation) do
    %{
      "name" => String.trim(string(operation["name"])),
      "description" => String.trim(string(operation["description"])),
      "executable" => String.trim(string(operation["executable"])),
      "argv" => value_lines(operation["argv"])
    }
    |> drop_empty()
    |> Map.put("argv", value_lines(operation["argv"]))
  end

  defp drop_empty(map) do
    map
    |> Enum.reject(fn
      {_key, ""} -> true
      {_key, []} -> true
      {_key, _value} -> false
    end)
    |> Map.new()
  end

  defp put_optional_string(document, path, value) do
    case String.trim(string(value)) do
      "" -> Document.delete(document, path)
      value -> Document.put(document, path, value)
    end
  end

  defp put_string(document, path, value) do
    case String.trim(string(value)) do
      "" -> Document.delete(document, path)
      value -> Document.put(document, path, value)
    end
  end

  defp put_boolean(document, path, value) when value in ["", "false", false, nil],
    do: Document.delete(document, path)

  defp put_boolean(document, path, _value), do: Document.put(document, path, true)

  defp put_list(document, path, []), do: Document.delete(document, path)
  defp put_list(document, path, list), do: Document.put(document, path, list)

  defp form_from_data(data) when is_map(data) do
    {root, table} =
      case Map.get(data, "toolkit") do
        %{} = toolkit -> {toolkit, "toolkit"}
        _other -> {data, ""}
      end

    form = empty_form()
    config = table(root["config"])

    form
    |> Map.put("table", table)
    |> Map.put("name", string(root["name"]))
    |> Map.put("description", string(root["description"]))
    |> Map.put("implicit", if(root["implicit"] == true, do: "true", else: "false"))
    |> Map.put("native", string(root["native"]))
    |> Map.put("tools", list_text(root["tools"]))
    |> Map.put("config_root", string(config["root"]))
    |> Map.put("config_namespace", string(config["namespace"]))
    |> Map.put("config_env", env_text(config["env"]))
    |> Map.put("operations", operations_from_data(root["operations"]))
  end

  defp form_from_data(_data), do: empty_form()

  defp operations_from_data(operations) when is_list(operations) do
    operations
    |> Enum.with_index()
    |> Enum.map(fn {operation, index} ->
      operation = table(operation)

      %{
        "_key" => Integer.to_string(index),
        "name" => string(operation["name"]),
        "description" => string(operation["description"]),
        "executable" => string(operation["executable"]),
        "argv" => list_text(operation["argv"])
      }
    end)
  end

  defp operations_from_data(_operations), do: []

  defp operations_from_params(nil, current), do: current || []

  defp operations_from_params(params, current) when is_map(params),
    do: operations_from_params(map_values(params), current)

  defp operations_from_params(params, current) when is_list(params) do
    current = current || []

    params
    |> Enum.with_index()
    |> Enum.map(fn {raw, index} ->
      raw = table(raw)
      previous = current_item(raw, current, index)

      %{
        "_key" => text_value(raw, previous, "_key"),
        "name" => text_value(raw, previous, "name"),
        "description" => text_value(raw, previous, "description"),
        "executable" => text_value(raw, previous, "executable"),
        "argv" => text_value(raw, previous, "argv")
      }
    end)
  end

  defp operations_from_params(_params, current), do: current || []

  defp current_item(raw, current, index) do
    key = text_value(raw, empty_operation(), "_key")

    Enum.find(current, &(Map.get(&1, "_key") == key)) ||
      Enum.at(current, index) ||
      empty_operation()
  end

  defp empty_form do
    %{
      "table" => "",
      "name" => "",
      "description" => "",
      "implicit" => "false",
      "native" => "",
      "tools" => "",
      "config_root" => "",
      "config_namespace" => "",
      "config_env" => "",
      "operations" => []
    }
  end

  defp empty_operation do
    %{
      "_key" => "",
      "name" => "",
      "description" => "",
      "executable" => "",
      "argv" => ""
    }
  end

  defp table_prefix("toolkit"), do: ["toolkit"]
  defp table_prefix(_table), do: []

  defp text_value(params, current, key) do
    case Map.fetch(params, key) do
      {:ok, value} -> string(value)
      :error -> string(Map.get(current, key))
    end
  end

  defp map_values(map) do
    map
    |> Enum.filter(fn {key, value} ->
      (is_integer(key) or not is_nil(parse_index(key))) and is_map(value)
    end)
    |> Enum.sort_by(fn {key, _value} -> parse_index(key) end)
    |> Enum.map(fn {_key, value} -> value end)
  end

  defp parse_index(key) when is_integer(key) and key >= 0, do: key

  defp parse_index(key) when is_binary(key) do
    case Integer.parse(key) do
      {value, ""} when value >= 0 -> value
      _other -> nil
    end
  end

  defp parse_index(_key), do: nil

  defp value_lines(nil), do: []

  defp value_lines(value) when is_binary(value) do
    value
    |> String.split(~r/\r?\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp value_lines(value) when is_list(value) do
    value
    |> Enum.map(&string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp value_lines(_value), do: []

  defp list_text(nil), do: ""

  defp list_text(list) when is_list(list) do
    list |> Enum.map(&string/1) |> Enum.join("\n")
  end

  defp list_text(value), do: string(value)

  defp env_text(nil), do: ""

  defp env_text(env) when is_map(env),
    do: env |> Enum.sort() |> Enum.map_join("\n", fn {k, v} -> "#{k}=#{string(v)}" end)

  defp env_text(_env), do: ""

  defp env_map(value) do
    value
    |> value_lines()
    |> Enum.map(fn line ->
      case Regex.run(@env_line_regex, line) do
        [_, variable, reference] -> {variable, String.trim(reference)}
        nil -> {line, ""}
      end
    end)
    |> Map.new()
  end

  defp table(value) when is_map(value) and not is_struct(value), do: value
  defp table(_value), do: %{}

  defp string(nil), do: ""
  defp string(value) when is_binary(value), do: value
  defp string(value) when is_integer(value), do: Integer.to_string(value)
  defp string(value) when is_atom(value), do: Atom.to_string(value)
  defp string(value), do: inspect(value)

  defp config_dir(%Config{config_dir: directory}) when is_binary(directory), do: {:ok, directory}
  defp config_dir(directory) when is_binary(directory), do: {:ok, directory}
  defp config_dir(_config), do: {:error, :invalid_config}

  defp path_for_id(nil, _id), do: nil

  defp path_for_id(config_dir, id) do
    case path(config_dir, id) do
      {:ok, path} -> path
      {:error, _reason} -> nil
    end
  end
end
