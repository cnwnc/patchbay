defmodule Patchbay.Transcript do
  @moduledoc """
  Filesystem handling for manager-owned transcript files.

  Transcript directories are private (`0700`) and transcript files are
  readable/writable only by the owner (`0600`). Symlinks are refused at the
  final path component so an event append cannot be redirected outside the
  transcript directory.
  """

  @dir_mode 0o700
  @file_mode 0o600

  @type error :: File.posix() | :symlink | :not_a_regular_file | :not_a_directory

  @doc "Creates `path` as a private directory."
  @spec ensure_dir(Path.t()) :: :ok | {:error, error()}
  def ensure_dir(path) when is_binary(path) do
    with :ok <- reject_symlink(path),
         :ok <- mkdir_p(path),
         :ok <- reject_symlink(path),
         :ok <- chmod(path, @dir_mode) do
      case File.stat(path) do
        {:ok, %File.Stat{type: :directory}} -> :ok
        {:ok, _stat} -> {:error, :not_a_directory}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Appends `data` to `path`.

  Creates the file with `0600` when it does not exist and refuses to follow a
  symlink or write to a non-regular file. Pass `sync: true` to flush the append
  to stable storage before returning.
  """
  @spec append(Path.t(), iodata(), keyword()) :: :ok | {:error, error()}
  def append(path, data, opts \\ []) when is_binary(path) do
    case open_append(path) do
      {:ok, io} ->
        try do
          with :ok <- IO.binwrite(io, data) do
            sync(io, Keyword.get(opts, :sync, false))
          end
        after
          File.close(io)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp sync(_io, false), do: :ok
  defp sync(io, true), do: :file.sync(io)

  @doc """
  Flushes a directory entry update to stable storage.

  The BEAM cannot open a directory as a file, so this delegates to the
  platform `sync` utility. A missing utility leaves the call a no-op; the
  caller has already written and synced the file itself.
  """
  @spec sync_dir(Path.t()) :: :ok
  def sync_dir(path) when is_binary(path) do
    case System.find_executable("sync") do
      nil ->
        :ok

      executable ->
        try do
          case System.cmd(executable, [path], stderr_to_stdout: true) do
            {_output, 0} -> :ok
            {output, _status} -> warn_sync(path, output)
          end
        rescue
          _error -> :ok
        end
    end
  end

  defp warn_sync(path, output) do
    require Logger
    Logger.warning("directory sync failed for #{inspect(path)}: #{String.trim(output)}")
    :ok
  end

  @doc """
  Checks that `path` is absent or a regular file, and is not a symlink.
  """
  @spec ensure_file(Path.t()) :: :ok | {:error, error()}
  def ensure_file(path) when is_binary(path) do
    with :ok <- reject_symlink(path) do
      ensure_regular(path)
    end
  end

  @doc "Opens `path` for append, applying private file permissions."
  @spec open_append(Path.t()) :: {:ok, IO.device()} | {:error, error()}
  def open_append(path) when is_binary(path) do
    with :ok <- ensure_file(path),
         {:ok, io} <- File.open(path, [:append, :binary]) do
      case chmod(path, @file_mode) do
        :ok ->
          {:ok, io}

        {:error, _reason} = error ->
          File.close(io)
          error
      end
    end
  end

  defp reject_symlink(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} -> {:error, :symlink}
      {:ok, _stat} -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_regular(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, _stat} -> {:error, :not_a_regular_file}
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp mkdir_p(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp chmod(path, mode) do
    case File.chmod(path, mode) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
