defmodule Patchbay.Config.File do
  @moduledoc """
  Revision-checked atomic file replacement shared by configuration editors.

  A write is accepted only when the caller's expected SHA-256 digest matches
  the bytes currently on disk. Accepted writes replace the file atomically
  through a temporary file in the same directory followed by a rename, and the
  containing directory is synced afterwards. Pass `:absent` as the expected
  digest to create a file only while it does not exist.

  Writes take an exclusive lock file next to the target, which also serializes
  writers in other Patchbay processes on the same machine. Symlinked targets
  are rejected so callers cannot be redirected outside the directory they
  confined the path to.
  """

  @type error ::
          :not_found
          | :stale
          | :unsafe_path
          | {:io, File.posix()}
          | {:lock, term()}

  @lock_attempts 100
  @lock_backoff_ms 20
  @lock_stale_seconds 30

  @doc "Returns the SHA-256 hex digest of `content`."
  @spec hash(String.t()) :: String.t()
  def hash(content) when is_binary(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end

  @doc "Reads a regular file with its digest."
  @spec read(Path.t()) ::
          {:ok, %{path: Path.t(), content: String.t(), hash: String.t()}} | {:error, error()}
  def read(path) when is_binary(path) do
    with :ok <- safe_source(path) do
      case File.read(path) do
        {:ok, content} -> {:ok, %{path: path, content: content, hash: hash(content)}}
        {:error, :enoent} -> {:error, :not_found}
        {:error, reason} -> {:error, {:io, reason}}
      end
    end
  end

  @doc """
  Replaces `path` when `expected_hash` matches its current digest.

  Options:

    * `:guard` - a zero-arity function run while the lock is held; returning
      anything other than `:ok` aborts the write with that value
  """
  @spec write(Path.t(), String.t(), String.t() | :absent | nil, keyword()) ::
          {:ok, %{path: Path.t(), hash: String.t()}} | {:error, term()}
  def write(path, content, expected_hash, opts \\ []) when is_binary(content) do
    guarded(path, opts, fn ->
      with :ok <- safe_source(path) do
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

  @doc """
  Deletes `path` when `expected_hash` matches its current digest.
  """
  @spec delete(Path.t(), String.t() | nil, keyword()) :: :ok | {:error, term()}
  def delete(path, expected_hash, opts \\ []) when is_binary(path) do
    guarded(path, opts, fn ->
      with :ok <- safe_source(path) do
        case File.read(path) do
          {:ok, current} ->
            if current_hash?(current, expected_hash) do
              case File.rm(path) do
                :ok ->
                  _ = sync_directory(Path.dirname(path))
                  :ok

                {:error, :enoent} ->
                  {:error, :not_found}

                {:error, reason} ->
                  {:error, {:io, reason}}
              end
            else
              {:error, :stale}
            end

          {:error, :enoent} ->
            {:error, :not_found}

          {:error, reason} ->
            {:error, {:io, reason}}
        end
      end
    end)
  end

  @doc false
  @spec atomic_write(Path.t(), String.t()) :: :ok | {:error, File.posix()}
  def atomic_write(path, content) when is_binary(path) and is_binary(content) do
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

  @doc false
  @spec sync_directory(Path.t()) :: :ok | {:error, File.posix()}
  def sync_directory(directory) do
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

  defp guarded(path, opts, fun) do
    lock = lock_path(path)

    case acquire_lock(lock, @lock_attempts) do
      {:ok, token} ->
        try do
          case guard(opts) do
            :ok -> fun.()
            other -> {:error, other}
          end
        after
          release_lock(lock, token)
        end

      {:error, reason} ->
        {:error, {:lock, reason}}
    end
  end

  defp guard(opts) do
    case Keyword.get(opts, :guard) do
      fun when is_function(fun, 0) -> fun.()
      _other -> :ok
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

  defp safe_source(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} -> {:error, :unsafe_path}
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, %File.Stat{type: :directory}} -> {:error, :unsafe_path}
      {:ok, %File.Stat{}} -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:io, reason}}
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
