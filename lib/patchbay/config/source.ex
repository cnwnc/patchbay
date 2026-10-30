defmodule Patchbay.Config.Source do
  @moduledoc """
  Reads and writes agent source files below a configuration root.

  Paths are derived from the configured `agents/<id>/agent.toml` location;
  callers never supply a path. A write is accepted only when the caller's
  expected hash matches the bytes currently on disk. Accepted writes replace
  the file atomically through a temporary file in the same directory followed
  by a rename, and the containing directory is synced afterwards.

  Symlinked agent directories and symlinked `agent.toml` files are rejected
  so reads and writes stay below the configuration root. Writes take an
  exclusive lock file next to the source, which also serializes writers in
  other Patchbay processes on the same machine.
  """

  alias Patchbay.Config

  @type t :: %{path: Path.t(), content: String.t(), hash: String.t()}

  @type error ::
          :invalid_config
          | :invalid_id
          | :not_found
          | :exists
          | :stale
          | :unsafe_path
          | {:io, File.posix()}
          | {:lock, term()}

  @lock_attempts 100
  @lock_backoff_ms 20
  @lock_stale_seconds 30

  @new_id_regex ~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/
  @lifecycle_kinds ~w(one-shot perpetual)

  @doc """
  Returns the SHA-256 hex digest of `content`.
  """
  @spec hash(String.t()) :: String.t()
  def hash(content) when is_binary(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Resolves the source path for an agent.

  `config` accepts a `Patchbay.Config` struct or a configuration directory.
  Identifiers containing path separators, parent references, or NUL bytes are
  rejected.
  """
  @spec path(Config.t() | Path.t(), String.t()) :: {:ok, Path.t()} | {:error, error()}
  def path(config, id) do
    with {:ok, directory} <- config_dir(config),
         :ok <- validate_id(id) do
      agents_dir = directory |> Path.join("agents") |> Path.expand()
      path = Path.expand(Path.join([agents_dir, id, "agent.toml"]))

      if Path.dirname(Path.dirname(path)) == agents_dir do
        {:ok, path}
      else
        {:error, :invalid_id}
      end
    end
  end

  @doc """
  Creates a new agent directory with `agent.toml` and an empty `prompts/`.

  The directory is created with `mkdir`, so an existing agent directory is
  never overwritten and reports `{:error, :exists}`. A failed create removes
  the partially built directory. Identifiers for new agents must start with a
  lowercase letter or digit and contain only lowercase letters, digits,
  dashes, and underscores, up to 64 bytes.
  """
  @spec create(Config.t() | Path.t(), String.t(), String.t()) ::
          {:ok, %{id: String.t(), path: Path.t(), hash: String.t()}} | {:error, error()}
  def create(config, id, content) when is_binary(content) do
    with :ok <- validate_new_id(id),
         {:ok, agents_dir} <- agents_directory(config),
         {:ok, path} <- path(config, id) do
      directory = Path.dirname(path)

      case File.mkdir(directory) do
        :ok ->
          build_agent_directory(directory, path, id, content, agents_dir)

        {:error, :eexist} ->
          {:error, :exists}

        {:error, reason} ->
          {:error, {:io, reason}}
      end
    end
  end

  @doc """
  Returns a minimal valid agent source for `id` and `lifecycle`.

  `lifecycle` accepts `"one-shot"` or `"perpetual"`; other values fall back
  to `"one-shot"`.
  """
  @spec template(String.t(), String.t()) :: String.t()
  def template(id, lifecycle \\ "one-shot")

  def template(id, lifecycle) when is_binary(id) and lifecycle in @lifecycle_kinds do
    """
    format-version = 1
    id = #{inspect(id)}

    [model]
    name = "default"

    [lifecycle]
    kind = #{inspect(lifecycle)}
    """
  end

  def template(id, _lifecycle), do: template(id, "one-shot")

  @doc """
  Returns true when `id` can be used for a new agent directory.
  """
  @spec valid_new_id?(term()) :: boolean()
  def valid_new_id?(id) when is_binary(id) do
    String.valid?(id) and Regex.match?(@new_id_regex, id)
  end

  def valid_new_id?(_id), do: false

  @doc """
  Reads an agent source file.
  """
  @spec read(Config.t() | Path.t(), String.t()) :: {:ok, t()} | {:error, error()}
  def read(config, id) do
    with {:ok, path} <- path(config, id),
         :ok <- safe_directory(config, path),
         :ok <- safe_source(path) do
      case File.read(path) do
        {:ok, content} -> {:ok, %{path: path, content: content, hash: hash(content)}}
        {:error, :enoent} -> {:error, :not_found}
        {:error, reason} -> {:error, {:io, reason}}
      end
    end
  end

  @doc """
  Replaces an agent source file when `expected_hash` matches its current hash.

  Pass `:absent` as `expected_hash` to create the file only while it does not
  exist; `:stale` is returned when a file appeared after the editor loaded.

  The hash comparison and replacement run while holding an exclusive lock file
  next to the source, so writers in other Patchbay processes are serialized
  too. `:stale` means the file changed after it was read, for example in an
  external editor; no bytes are written in that case.
  """
  @spec write(Config.t() | Path.t(), String.t(), String.t(), String.t() | :absent | nil) ::
          {:ok, %{path: Path.t(), hash: String.t()}} | {:error, error()}
  def write(config, id, content, expected_hash) when is_binary(content) do
    with {:ok, path} <- path(config, id),
         :ok <- safe_directory(config, path) do
      locked(path, fn ->
        with :ok <- safe_directory(config, path),
             :ok <- safe_source(path) do
          case File.read(path) do
            {:ok, current} ->
              if current_hash?(current, expected_hash) do
                case atomic_write(path, content) do
                  :ok -> {:ok, %{path: path, hash: hash(content)}}
                  {:error, reason} -> {:error, {:io, reason}}
                end
              else
                {:error, :stale}
              end

            {:error, :enoent} ->
              write_absent(path, content, expected_hash)

            {:error, reason} ->
              {:error, {:io, reason}}
          end
        end
      end)
    end
  end

  defp current_hash?(current, expected) when is_binary(expected) do
    expected =
      expected
      |> String.trim()
      |> String.downcase()
      |> String.replace_prefix("sha256:", "")

    hash(current) == expected
  end

  defp current_hash?(_current, _expected), do: false

  defp write_absent(path, content, :absent) do
    case File.lstat(path) do
      {:error, :enoent} ->
        case atomic_write(path, content) do
          :ok -> {:ok, %{path: path, hash: hash(content)}}
          {:error, reason} -> {:error, {:io, reason}}
        end

      {:ok, _stat} ->
        {:error, :stale}

      {:error, reason} ->
        {:error, {:io, reason}}
    end
  end

  defp write_absent(_path, _content, _expected), do: {:error, :not_found}

  defp validate_new_id(id) do
    if valid_new_id?(id), do: :ok, else: {:error, :invalid_id}
  end

  defp build_agent_directory(directory, path, id, content, agents_dir) do
    with :ok <- File.mkdir(Path.join(directory, "prompts")),
         :ok <- atomic_write(path, content) do
      _ = sync_directory(agents_dir)
      {:ok, %{id: id, path: path, hash: hash(content)}}
    else
      {:error, reason} ->
        File.rm_rf(directory)
        {:error, {:io, reason}}
    end
  end

  defp agents_directory(config) do
    with {:ok, directory} <- config_dir(config) do
      agents_dir = directory |> Path.join("agents") |> Path.expand()

      case File.mkdir(agents_dir) do
        :ok ->
          {:ok, agents_dir}

        {:error, :eexist} ->
          case File.lstat(agents_dir) do
            {:ok, %File.Stat{type: :directory}} -> {:ok, agents_dir}
            {:ok, %File.Stat{}} -> {:error, :unsafe_path}
            {:error, reason} -> {:error, {:io, reason}}
          end

        {:error, reason} ->
          {:error, {:io, reason}}
      end
    end
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

  defp config_dir(%Config{config_dir: directory}) when is_binary(directory),
    do: {:ok, directory}

  defp config_dir(directory) when is_binary(directory), do: {:ok, directory}
  defp config_dir(_config), do: {:error, :invalid_config}

  defp locked(path, fun) do
    lock = lock_path(path)

    case acquire_lock(lock, @lock_attempts) do
      {:ok, token} ->
        try do
          fun.()
        after
          release_lock(lock, token)
        end

      {:error, reason} ->
        {:error, {:lock, reason}}
    end
  end

  defp acquire_lock(_lock, 0), do: {:error, :busy}

  defp acquire_lock(lock, attempts) do
    token =
      "#{System.pid()} #{System.os_time(:second)} #{Base.url_encode64(:crypto.strong_rand_bytes(9))}"

    case File.open(lock, [:write, :binary, :exclusive]) do
      {:ok, device} ->
        _ = IO.binwrite(device, token <> "\n")
        _ = File.close(device)
        {:ok, token}

      {:error, :eexist} ->
        cond do
          stale_lock?(lock) ->
            File.rm(lock)
            acquire_lock(lock, attempts - 1)

          true ->
            Process.sleep(@lock_backoff_ms)
            acquire_lock(lock, attempts - 1)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp release_lock(lock, token) do
    case File.read(lock) do
      {:ok, content} -> if String.trim(content) == token, do: File.rm(lock), else: :ok
      {:error, _reason} -> :ok
    end
  end

  defp stale_lock?(lock) do
    case File.lstat(lock, time: :posix) do
      {:ok, %File.Stat{type: :regular, mtime: mtime}} ->
        System.os_time(:second) - mtime > @lock_stale_seconds

      _other ->
        false
    end
  end

  defp lock_path(path) do
    Path.join(Path.dirname(path), ".#{Path.basename(path)}.lock")
  end

  defp safe_directory(config, path) do
    with {:ok, directory} <- config_dir(config) do
      parent = Path.dirname(path)
      agents_dir = directory |> Path.join("agents") |> Path.expand()

      case File.lstat(parent) do
        {:ok, %File.Stat{type: :directory}} ->
          if Path.dirname(parent) == agents_dir, do: :ok, else: {:error, :unsafe_path}

        {:ok, %File.Stat{}} ->
          {:error, :unsafe_path}

        {:error, :enoent} ->
          {:error, :not_found}

        {:error, reason} ->
          {:error, {:io, reason}}
      end
    end
  end

  defp safe_source(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} -> {:error, :unsafe_path}
      {:ok, %File.Stat{}} -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:io, reason}}
    end
  end

  defp atomic_write(path, content) do
    temporary = temporary_path(path)

    try do
      with {:ok, device} <- File.open(temporary, [:write, :binary, :exclusive]) do
        result =
          with :ok <- :file.write(device, content),
               :ok <- :file.sync(device) do
            :ok
          end

        _ = File.close(device)

        with :ok <- result do
          preserve_mode(path, temporary)

          with :ok <- File.rename(temporary, path) do
            sync_directory(Path.dirname(path))
          end
        end
      end
    after
      File.rm(temporary)
    end
  end

  defp sync_directory(directory) do
    case :file.open(String.to_charlist(directory), [:read, :directory]) do
      {:ok, device} ->
        result = :file.sync(device)
        _ = :file.close(device)
        result

      {:error, reason} when reason in [:eisdir, :enotsup, :einval, :badarg] ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp temporary_path(path) do
    suffix =
      6
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64(padding: false)

    Path.join(Path.dirname(path), ".#{Path.basename(path)}.#{suffix}.tmp")
  end

  defp preserve_mode(path, temporary) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} -> File.chmod(temporary, Bitwise.band(mode, 0o777))
      _other -> :ok
    end
  end
end
