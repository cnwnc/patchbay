defmodule Patchbay.Config.Prompt do
  @moduledoc """
  Reads, creates, updates, and deletes Markdown prompt files for an agent.

  Prompts live at the top level of `<config_dir>/shared/prompts` and
  `<config_dir>/agents/<id>/prompts`. Only `.md` and `.markdown` files are
  listed. Nested paths, parent references, and symlinked prompt files are
  rejected. Writes use `Patchbay.Config.File`, so they are revision checked
  and atomic.
  """

  alias Patchbay.Config
  alias Patchbay.Config.File, as: ConfigFile

  @sources ["shared", "agent"]
  @extensions [".md", ".markdown"]
  @filename_regex ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,120}\z/

  @type source :: :shared | :agent
  @type entry :: %{
          name: String.t(),
          path: Path.t(),
          source: source(),
          content: String.t(),
          hash: String.t() | nil,
          error: String.t() | nil
        }

  @type error ::
          :invalid_config
          | :invalid_id
          | :invalid_filename
          | :invalid_source
          | :not_found
          | :stale
          | :exists
          | :unsafe_path
          | {:io, File.posix()}

  @doc "Prompt sources in display order."
  @spec sources() :: [String.t()]
  def sources, do: @sources

  @doc "Returns true when `filename` is a top-level Markdown prompt name."
  @spec valid_filename?(term()) :: boolean()
  def valid_filename?(filename) when is_binary(filename) do
    String.valid?(filename) and
      Path.basename(filename) == filename and
      not String.contains?(filename, ["/", "\\", <<0>>]) and
      filename not in [".", ".."] and
      Path.extname(filename) in @extensions and
      Regex.match?(@filename_regex, Path.rootname(filename))
  end

  def valid_filename?(_filename), do: false

  @doc "Returns true when `source` names a prompt directory."
  @spec valid_source?(term()) :: boolean()
  def valid_source?(source), do: source in @sources

  @doc "Resolves a prompt file path for an agent and source."
  @spec path(Config.t() | Path.t(), String.t(), String.t(), String.t()) ::
          {:ok, Path.t()} | {:error, error()}
  def path(config, agent_id, source, filename) do
    with {:ok, directory} <- prompt_dir(config, agent_id, source),
         true <- valid_filename?(filename) do
      path = Path.expand(Path.join(directory, filename))

      if Path.dirname(path) == directory do
        {:ok, path}
      else
        {:error, :invalid_filename}
      end
    else
      false -> {:error, :invalid_filename}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Lists shared prompts and then agent prompts, each ordered by filename.

  A file that cannot be read is kept in the list with an `:error` message so
  the editor can show it without hiding the rest of the directory.
  """
  @spec list(Config.t() | Path.t(), String.t() | nil) :: [entry()]
  def list(_config, nil), do: []

  def list(config, agent_id) do
    list_source(config, agent_id, "shared") ++ list_source(config, agent_id, "agent")
  end

  @doc "Reads one prompt file."
  @spec read(Config.t() | Path.t(), String.t(), String.t(), String.t()) ::
          {:ok, entry()} | {:error, error()}
  def read(config, agent_id, source, filename) do
    with {:ok, path} <- path(config, agent_id, source, filename) do
      case ConfigFile.read(path) do
        {:ok, %{content: content, hash: hash}} ->
          {:ok, entry(filename, path, source_atom(source), content, hash, nil)}

        {:error, :not_found} ->
          {:error, :not_found}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Creates a prompt file only while it does not exist.

  A missing prompt directory is created for the shared source. An agent prompt
  requires the agent directory to exist.
  """
  @spec create(Config.t() | Path.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, entry()} | {:error, error()}
  def create(config, agent_id, source, filename, content \\ nil) when is_binary(filename) do
    content = if is_binary(content), do: content, else: template(filename)

    with {:ok, path} <- path(config, agent_id, source, filename),
         :ok <- ensure_prompt_dir(config, agent_id, source),
         {:ok, _written} <-
           ConfigFile.write(path, content, :absent,
             guard: fn -> ensure_prompt_dir(config, agent_id, source) end
           ) do
      {:ok, entry(filename, path, source_atom(source), content, ConfigFile.hash(content), nil)}
    else
      {:error, :stale} -> {:error, :exists}
      {:error, {:io, :eexist}} -> {:error, :exists}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Replaces a prompt file when its digest still matches."
  @spec write(
          Config.t() | Path.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t() | nil
        ) ::
          {:ok, entry()} | {:error, error()}
  def write(config, agent_id, source, filename, content, expected_hash)
      when is_binary(content) do
    with {:ok, path} <- path(config, agent_id, source, filename),
         :ok <- ensure_prompt_dir(config, agent_id, source),
         {:ok, %{hash: hash}} <-
           ConfigFile.write(path, content, expected_hash,
             guard: fn -> ensure_prompt_dir(config, agent_id, source) end
           ) do
      {:ok, entry(filename, path, source_atom(source), content, hash, nil)}
    end
  end

  @doc "Deletes a prompt file when its digest still matches."
  @spec delete(Config.t() | Path.t(), String.t(), String.t(), String.t(), String.t() | nil) ::
          :ok | {:error, error()}
  def delete(config, agent_id, source, filename, expected_hash) do
    with {:ok, path} <- path(config, agent_id, source, filename),
         :ok <- ensure_prompt_dir(config, agent_id, source) do
      ConfigFile.delete(path, expected_hash,
        guard: fn -> ensure_prompt_dir(config, agent_id, source) end
      )
    end
  end

  @doc "Initial content for a new prompt."
  @spec template(String.t()) :: String.t()
  def template(filename) do
    name = Path.rootname(filename)
    "# #{name}\n\n"
  end

  @doc "Display name for a prompt source."
  @spec label(String.t() | source()) :: String.t()
  def label(:shared), do: "SHARED"
  def label("shared"), do: "SHARED"
  def label(:agent), do: "AGENT"
  def label("agent"), do: "AGENT"
  def label(_source), do: "—"

  defp list_source(config, agent_id, source) do
    case prompt_dir(config, agent_id, source) do
      {:ok, directory} ->
        entries =
          case File.ls(directory) do
            {:ok, entries} -> Enum.sort(entries)
            {:error, _reason} -> []
          end

        entries
        |> Enum.filter(&valid_filename?/1)
        |> Enum.map(fn filename -> load_entry(directory, filename, source) end)
        |> Enum.reject(&is_nil/1)

      {:error, _reason} ->
        []
    end
  end

  defp load_entry(directory, filename, source) do
    path = Path.join(directory, filename)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        case File.read(path) do
          {:ok, content} ->
            entry(filename, path, source_atom(source), content, ConfigFile.hash(content), nil)

          {:error, reason} ->
            entry(
              filename,
              path,
              source_atom(source),
              "",
              nil,
              :file.format_error(reason) |> to_string()
            )
        end

      {:ok, %File.Stat{type: :symlink}} ->
        entry(
          filename,
          path,
          source_atom(source),
          "",
          nil,
          "symlinked prompt files are not editable"
        )

      _other ->
        nil
    end
  end

  defp entry(name, path, source, content, hash, error) do
    %{name: name, path: path, source: source, content: content, hash: hash, error: error}
  end

  defp prompt_dir(config, agent_id, source) do
    with {:ok, root} <- config_dir(config),
         :ok <- validate_source(source),
         :ok <- validate_id(agent_id) do
      directory =
        case source do
          "shared" -> Path.expand(Path.join([root, "shared", "prompts"]))
          "agent" -> Path.expand(Path.join([root, "agents", agent_id, "prompts"]))
          :shared -> Path.expand(Path.join([root, "shared", "prompts"]))
          :agent -> Path.expand(Path.join([root, "agents", agent_id, "prompts"]))
        end

      with :ok <- safe_parent(Path.dirname(directory)),
           :ok <- safe_directory(directory) do
        {:ok, directory}
      end
    end
  end

  defp safe_parent(parent) do
    case File.lstat(parent) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, _stat} -> {:error, :unsafe_path}
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:io, reason}}
    end
  end

  defp safe_directory(directory) do
    case File.lstat(directory) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, _stat} -> {:error, :unsafe_path}
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:io, reason}}
    end
  end

  defp ensure_prompt_dir(config, agent_id, source) do
    with {:ok, directory} <- prompt_dir(config, agent_id, source) do
      case File.lstat(directory) do
        {:ok, %File.Stat{type: :directory}} ->
          :ok

        {:ok, _stat} ->
          {:error, :unsafe_path}

        {:error, :enoent} ->
          create_prompt_dir(config, agent_id, source, directory)

        {:error, reason} ->
          {:error, {:io, reason}}
      end
    end
  end

  defp create_prompt_dir(config, agent_id, source, directory) do
    with :ok <- ensure_parent_directory(config, agent_id, source, Path.dirname(directory)) do
      case File.mkdir(directory) do
        :ok -> ensure_real_directory(directory)
        {:error, reason} -> {:error, {:io, reason}}
      end
    end
  end

  defp ensure_parent_directory(_config, _agent_id, source, parent)
       when source in ["shared", :shared] do
    case File.lstat(parent) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, _stat} -> {:error, :unsafe_path}
      {:error, :enoent} -> create_shared_directory(parent)
      {:error, reason} -> {:error, {:io, reason}}
    end
  end

  defp ensure_parent_directory(config, agent_id, _source, _parent) do
    ensure_agent_directory(config, agent_id, "agent")
  end

  defp ensure_agent_directory(config, agent_id, _source) do
    with {:ok, directory} <- config_dir(config) do
      agent_dir = Path.expand(Path.join([directory, "agents", agent_id]))

      case File.lstat(agent_dir) do
        {:ok, %File.Stat{type: :directory}} -> :ok
        {:ok, _stat} -> {:error, :unsafe_path}
        {:error, :enoent} -> {:error, :not_found}
        {:error, reason} -> {:error, {:io, reason}}
      end
    end
  end

  defp create_shared_directory(parent) do
    case File.mkdir(parent) do
      :ok -> ensure_real_directory(parent)
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

  defp validate_source(source) do
    if valid_source?(source), do: :ok, else: {:error, :invalid_source}
  end

  defp validate_id(id) when is_binary(id) do
    cond do
      id == "" -> {:error, :invalid_id}
      id in [".", ".."] -> {:error, :invalid_id}
      Path.basename(id) != id -> {:error, :invalid_id}
      String.contains?(id, ["/", "\\", <<0>>]) -> {:error, :invalid_id}
      true -> :ok
    end
  end

  defp validate_id(_id), do: {:error, :invalid_id}

  defp source_atom("shared"), do: :shared
  defp source_atom("agent"), do: :agent
  defp source_atom(:shared), do: :shared
  defp source_atom(:agent), do: :agent

  defp config_dir(%Config{config_dir: directory}) when is_binary(directory), do: {:ok, directory}
  defp config_dir(directory) when is_binary(directory), do: {:ok, directory}
  defp config_dir(_config), do: {:error, :invalid_config}
end
