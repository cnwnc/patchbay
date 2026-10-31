defmodule Patchbay.Worker.Artifacts do
  @moduledoc """
  Built-in worker operation that carries file bytes across the worker/manager
  UID split.

  The workspace and result directories belong to the agent user, so the
  manager cannot read a completed run's files directly. Before a run's worker
  exits, the runtime asks it to read the requested ranges through this
  reserved operation. The read is confined to the worker's own workspace or
  result directory: a request is never allowed to name a path outside them
  even after symlink resolution.

  One call returns at most `max_read_bytes/0` base64-encoded bytes from a
  chosen offset, so an artifact of any size travels in bounded frames and the
  manager can stop at the published-size cap.
  """

  alias Patchbay.Provider.JSON
  alias Patchbay.Worker.Operations

  @read_operation "patchbay-read-artifact"

  @max_read_bytes 512 * 1024
  @max_path_bytes 4096

  @doc "Reserved operation name; agent definitions cannot declare it."
  @spec read_operation() :: binary()
  def read_operation, do: @read_operation

  @doc "Returns true for the reserved built-in operation name."
  @spec reserved?(term()) :: boolean()
  def reserved?(name), do: name == @read_operation

  @doc "Maximum number of source bytes one read call may return."
  @spec max_read_bytes() :: pos_integer()
  def max_read_bytes, do: @max_read_bytes

  @doc """
  Reads one range of a file inside a worker-owned root.

  `roots` maps `"workspace"` (required) and `"result"` (optional) to absolute
  directory paths. `arguments` accepts:

    * `"path"` - required path; absolute only when it stays inside the chosen
      root, otherwise resolved relative to it
    * `"root"` - `"workspace"` (default) or `"result"`
    * `"offset"` - non-negative byte offset, default `0`
    * `"length"` - bytes to read, clamped to `max_read_bytes/0`

  Returns the normal operation result shape: `{:ok, map}` with a JSON
  `:output` payload carrying `"size"`, `"offset"`, `"length"`, `"data"`
  (base64), and `"eof"`. The manager never trusts more than one chunk of the
  file at a time.
  """
  @spec read(%{optional(binary()) => binary() | nil}, map()) ::
          {:ok, %{output: binary(), status: :ok}} | {:error, term()}
  def read(roots, arguments) when is_map(arguments) and is_map(roots) do
    started = System.monotonic_time(:millisecond)

    with {:ok, root_name} <- root_name(arguments),
         {:ok, base} <- root(roots, root_name),
         {:ok, path} <- request_path(arguments),
         {:ok, absolute} <- confine(base, path),
         {:ok, size, real} <- regular_file(absolute),
         {:ok, offset} <- offset(arguments),
         {:ok, length} <- request_length(arguments),
         {:ok, data} <- read_range(real, offset, length, size) do
      got = byte_size(data)

      payload =
        %{
          "data" => Base.encode64(data),
          "eof" => offset + got >= size,
          "length" => got,
          "offset" => offset,
          "size" => size
        }

      {:ok,
       %{
         status: :ok,
         output: json!(payload),
         duration_ms: System.monotonic_time(:millisecond) - started
       }}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_arguments}
    end
  end

  def read(_roots, _arguments), do: {:error, :invalid_arguments}

  defp root_name(%{"root" => root}) when root in ["workspace", "result"], do: {:ok, root}

  defp root_name(%{"root" => nil}), do: {:ok, "workspace"}

  defp root_name(arguments) when is_map(arguments) and not is_map_key(arguments, "root"),
    do: {:ok, "workspace"}

  defp root_name(_arguments), do: {:error, :invalid_root}

  defp root(roots, "workspace") do
    case Map.get(roots, "workspace") do
      base when is_binary(base) and base != "" -> {:ok, Path.expand(base)}
      _other -> {:error, :workspace_unavailable}
    end
  end

  defp root(roots, "result") do
    case Map.get(roots, "result") do
      base when is_binary(base) and base != "" -> {:ok, Path.expand(base)}
      _other -> {:error, :result_dir_unavailable}
    end
  end

  defp request_path(%{"path" => path})
       when is_binary(path) and path != "" and byte_size(path) <= @max_path_bytes do
    if String.contains?(path, <<0>>) do
      {:error, :invalid_path}
    else
      {:ok, path}
    end
  end

  defp request_path(_arguments), do: {:error, :invalid_path}

  defp confine(base, path) do
    candidate =
      if Path.type(path) == :absolute do
        Path.expand(path)
      else
        Path.expand(path, base)
      end

    with {:ok, real_base} <- Operations.canonical(base),
         {:ok, real} <- Operations.canonical(candidate) do
      under(real, real_base)
    else
      _invalid -> {:error, :invalid_path}
    end
  end

  defp under(path, base) do
    if path != base and String.starts_with?(path, base <> "/"),
      do: {:ok, path},
      else: {:error, :path_outside_root}
  end

  defp regular_file(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} -> {:ok, size, path}
      {:ok, _other_type} -> {:error, :not_a_regular_file}
      {:error, _reason} -> {:error, :not_found}
    end
  end

  defp offset(%{"offset" => offset}) when is_integer(offset) and offset >= 0,
    do: {:ok, offset}

  defp offset(%{"offset" => _other}), do: {:error, :invalid_offset}

  defp offset(arguments) when is_map(arguments), do: {:ok, 0}

  defp offset(_arguments), do: {:error, :invalid_offset}

  defp request_length(%{"length" => length}) when is_integer(length) and length > 0,
    do: {:ok, min(length, @max_read_bytes)}

  defp request_length(%{"length" => _other}), do: {:error, :invalid_length}

  defp request_length(_arguments), do: {:ok, @max_read_bytes}

  defp read_range(path, offset, length, size) do
    remaining = max(size - offset, 0)

    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        read =
          case :file.pread(io, offset, min(length, remaining)) do
            {:ok, data} -> {:ok, data}
            :eof -> {:ok, ""}
            {:error, reason} -> {:error, {:read_failed, reason}}
          end

        File.close(io)
        read

      {:error, reason} ->
        {:error, {:read_failed, reason}}
    end
  end

  defp json!(payload) do
    case JSON.encode(payload) do
      {:ok, encoded} -> encoded
      {:error, _reason} -> "{}"
    end
  end
end
