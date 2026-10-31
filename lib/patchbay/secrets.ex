defmodule Patchbay.Secrets do
  @moduledoc """
  Manager-only named secret store.

  Secrets are one file per name below `Patchbay.Config.secrets_dir`, which
  defaults to `<state_dir>/secrets`. The directory is created `0700` and every
  secret file is created `0600`. The configuration tree is never used for
  secret material, so a shared read-only config directory cannot expose a
  value.

  A secret file contains the raw value. No trailing newline is added or
  removed when reading. The CLI strips a single trailing `\\n` or `\\r\\n`
  from **input** because piping text usually adds one; see
  `strip_input_newline/1`.

  Names match `[a-z0-9][a-z0-9._-]{0,63}`. They are single path components:
  names containing `/`, `\\`, NUL, `.`, or `..` are rejected before any path
  is built. Reads and deletes use `lstat/1` and refuse symlinks or
  non-regular files, so a planted link cannot redirect the manager outside the
  store.

  Environment variable names used for injection match
  `[A-Z_][A-Z0-9_]{0,127}`. `PATCHBAY_*` and ordinary process variables such
  as `PATH` and `HOME` are reserved.
  """

  alias Patchbay.Transcript

  @directory_name "secrets"
  @name_regex ~r/\A[a-z0-9][a-z0-9._-]{0,63}\z/
  @variable_regex ~r/\A[A-Z_][A-Z0-9_]{0,127}\z/
  @reserved_prefix "PATCHBAY_"

  @reserved_variables ~w(
    PATH HOME USER LOGNAME SHELL TERM TMPDIR LANG LANGUAGE LC_ALL LC_CTYPE
  )

  @max_value_bytes 65_536
  @max_total_bytes 262_144
  @max_entries 256

  @type name :: String.t()
  @type error ::
          :not_found
          | :invalid_secret_name
          | :invalid_secret_value
          | :invalid_secret_file
          | :too_many_secrets
          | File.posix()

  @doc "Store directory below one manager state directory."
  @spec dir(Path.t()) :: Path.t()
  def dir(state_dir) when is_binary(state_dir), do: Path.join(state_dir, @directory_name)

  @doc "Returns true for a valid secret name."
  @spec valid_name?(term()) :: boolean()
  def valid_name?(name) when is_binary(name) do
    String.valid?(name) and Regex.match?(@name_regex, name)
  end

  def valid_name?(_name), do: false

  @doc """
  Returns true for an environment variable name that may receive a secret.

  `PATCHBAY_*` control names and ordinary process variables are rejected.
  """
  @spec valid_variable?(term()) :: boolean()
  def valid_variable?(name) when is_binary(name) do
    String.valid?(name) and Regex.match?(@variable_regex, name) and
      not String.starts_with?(name, @reserved_prefix) and name not in @reserved_variables
  end

  def valid_variable?(_name), do: false

  @doc "Maximum bytes accepted for one secret value."
  @spec max_value_bytes() :: pos_integer()
  def max_value_bytes, do: @max_value_bytes

  @doc "Maximum number of secrets accepted by `put/3` and injection."
  @spec max_entries() :: pos_integer()
  def max_entries, do: @max_entries

  @doc """
  Removes one trailing line ending from CLI input.

  Stored values are raw bytes; this only helps `printf 'x\\n' | patchbay
  secrets set name` produce the value `x` instead of `x\\n`. It removes exactly
  one `\\r\\n` or `\\n`, never more.
  """
  @spec strip_input_newline(binary()) :: binary()
  def strip_input_newline(value) when is_binary(value) do
    size = byte_size(value)

    cond do
      size >= 2 and binary_part(value, size - 2, 2) == "\r\n" ->
        binary_part(value, 0, size - 2)

      size >= 1 and binary_part(value, size - 1, 1) == "\n" ->
        binary_part(value, 0, size - 1)

      true ->
        value
    end
  end

  @doc "Lists secret names in lexical order. A missing store is empty."
  @spec list(Path.t()) :: {:ok, [name()]} | {:error, error()}
  def list(root) when is_binary(root) do
    with :ok <- reject_symlink(root) do
      case File.ls(root) do
        {:ok, entries} ->
          names =
            entries
            |> Enum.filter(&valid_name?/1)
            |> Enum.filter(&regular_file?(Path.join(root, &1)))
            |> Enum.sort()

          if length(names) > @max_entries,
            do: {:error, :too_many_secrets},
            else: {:ok, names}

        {:error, :enoent} ->
          {:ok, []}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Reads one secret value, which is returned byte-for-byte."
  @spec fetch(Path.t(), term()) :: {:ok, binary()} | {:error, error()}
  def fetch(root, name) when is_binary(root) do
    with :ok <- validate_name(name),
         :ok <- ensure_store(root),
         :ok <- ensure_regular_target(Path.join(root, name)) do
      case File.read(Path.join(root, name)) do
        {:ok, value} when byte_size(value) <= @max_value_bytes -> {:ok, value}
        {:ok, _value} -> {:error, :invalid_secret_value}
        {:error, :enoent} -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def fetch(_root, name), do: {:error, invalid_name_error(name)}

  @doc """
  Creates or replaces one secret.

  The value is written to a temporary file in the private store directory and
  renamed over the target, so a reader sees either the old or the new bytes.
  """
  @spec put(Path.t(), term(), term()) :: :ok | {:error, error()}
  def put(root, name, value) when is_binary(root) do
    with :ok <- validate_name(name),
         :ok <- validate_value(value),
         :ok <- ensure_root(root),
         :ok <- ensure_regular_target(Path.join(root, name)) do
      write_atomic(root, Path.join(root, name), value)
    end
  end

  def put(_root, name, _value), do: {:error, invalid_name_error(name)}

  @doc "Deletes one secret. A missing name is `{:error, :not_found}`."
  @spec delete(Path.t(), term()) :: :ok | {:error, error()}
  def delete(root, name) when is_binary(root) do
    with :ok <- validate_name(name),
         :ok <- ensure_store(root),
         :ok <- ensure_regular_target(Path.join(root, name)) do
      case File.rm(Path.join(root, name)) do
        :ok -> :ok
        {:error, :enoent} -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def delete(_root, name), do: {:error, invalid_name_error(name)}

  @doc """
  Validates a map of `environment variable => secret value`.

  Used by the manager and worker supervisor before a value leaves the manager
  process. Errors name the variable, never the value.
  """
  @spec validate_map(term()) :: :ok | {:error, term()}
  def validate_map(map) when is_map(map) and map_size(map) <= @max_entries do
    Enum.reduce_while(map, {:ok, 0}, fn
      {name, value}, {:ok, total} when is_binary(name) and is_binary(value) ->
        cond do
          not valid_variable?(name) ->
            {:halt, {:error, {:invalid_variable, name}}}

          byte_size(value) > @max_value_bytes ->
            {:halt, {:error, {:value_too_large, name}}}

          :binary.match(value, <<0>>) != :nomatch ->
            {:halt, {:error, {:invalid_value, name}}}

          total + byte_size(value) > @max_total_bytes ->
            {:halt, {:error, :secrets_too_large}}

          true ->
            {:cont, {:ok, total + byte_size(value)}}
        end

      _entry, _acc ->
        {:halt, {:error, :invalid_entry}}
    end)
    |> case do
      {:ok, _total} -> :ok
      {:error, _reason} = error -> error
    end
  end

  def validate_map(_map), do: {:error, :invalid_map}

  @doc "Joins secret environment variable names for `PATCHBAY_SECRET_ENV`."
  @spec encode_names([String.t()]) :: String.t()
  def encode_names(names) when is_list(names) do
    names
    |> Enum.filter(&valid_variable?/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.join(",")
  end

  @doc "Parses `PATCHBAY_SECRET_ENV` into valid, unique variable names."
  @spec parse_names(term()) :: [String.t()]
  def parse_names(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.filter(&valid_variable?/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.take(@max_entries)
  end

  def parse_names(_value), do: []

  defp validate_name(name) do
    if valid_name?(name), do: :ok, else: {:error, :invalid_secret_name}
  end

  defp validate_value(value) when is_binary(value) do
    cond do
      byte_size(value) > @max_value_bytes -> {:error, :invalid_secret_value}
      :binary.match(value, <<0>>) != :nomatch -> {:error, :invalid_secret_value}
      true -> :ok
    end
  end

  defp validate_value(_value), do: {:error, :invalid_secret_value}

  defp ensure_root(root) do
    case Transcript.ensure_dir(root) do
      :ok -> :ok
      {:error, :symlink} -> {:error, :invalid_secret_file}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_store(root) do
    with :ok <- reject_symlink(root) do
      case File.stat(root) do
        {:ok, %File.Stat{type: :directory}} -> :ok
        {:ok, _stat} -> {:error, :invalid_secret_file}
        {:error, :enoent} -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp ensure_regular_target(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, _stat} -> {:error, :invalid_secret_file}
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp reject_symlink(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} -> {:error, :invalid_secret_file}
      {:ok, _stat} -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp regular_file?(path) do
    match?({:ok, %File.Stat{type: :regular}}, File.lstat(path))
  end

  defp write_atomic(root, path, value) do
    temporary =
      Path.join(root, ".tmp-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false))

    with {:ok, io} <- File.open(temporary, [:write, :binary, :exclusive]) do
      written = IO.binwrite(io, value)
      File.close(io)

      result =
        with :ok <- written,
             :ok <- File.chmod(temporary, 0o600),
             :ok <- File.rename(temporary, path),
             :ok <- File.chmod(path, 0o600) do
          :ok
        end

      case result do
        :ok ->
          :ok

        {:error, reason} ->
          _ = File.rm(temporary)
          {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp invalid_name_error(_name), do: :invalid_secret_name
end
