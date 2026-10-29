defmodule Patchbay.ToolHistory.Writer do
  @moduledoc false

  alias Patchbay.ToolHistory
  alias Patchbay.Transcript

  @enforce_keys [:io, :path]
  defstruct [:io, :path]

  @rs 0x1E

  @type t :: %__MODULE__{io: IO.device(), path: Path.t()}

  @spec open(Path.t()) ::
          {:ok, t()}
          | {:error, File.posix() | :symlink | :not_a_regular_file}
  def open(path) when is_binary(path) do
    with :ok <- Transcript.ensure_file(path),
         :ok <- recover(path),
         {:ok, io} <- Transcript.open_append(path) do
      {:ok, %__MODULE__{io: io, path: path}}
    end
  end

  defp recover(path) do
    case File.read(path) do
      {:ok, data} -> drop_torn_tail(path, data)
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp drop_torn_tail(path, data) do
    size = byte_size(data)

    case last_record_end(data, 0, nil) do
      nil when size == 0 -> :ok
      nil -> truncate(path, 0)
      ^size -> :ok
      offset -> truncate(path, offset)
    end
  end

  defp last_record_end(<<>>, _offset, last), do: last

  defp last_record_end(<<?\\, _escaped, rest::binary>>, offset, last),
    do: last_record_end(rest, offset + 2, last)

  defp last_record_end(<<@rs, rest::binary>>, offset, _last),
    do: last_record_end(rest, offset + 1, offset + 1)

  defp last_record_end(<<_byte, rest::binary>>, offset, last),
    do: last_record_end(rest, offset + 1, last)

  defp truncate(path, offset) do
    path
    |> File.open([:read, :write, :binary], fn io ->
      {:ok, _position} = :file.position(io, offset)
      :file.truncate(io)
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  @spec append(t(), ToolHistory.t()) :: :ok | {:error, term()}
  def append(%__MODULE__{io: io}, record) do
    IO.binwrite(io, ToolHistory.encode_record(record))
  end

  @spec append_many(t(), [ToolHistory.t()]) :: :ok | {:error, term()}
  def append_many(%__MODULE__{io: io}, records) when is_list(records) do
    IO.binwrite(io, Enum.map(records, &ToolHistory.encode_record/1))
  end

  @spec close(t()) :: :ok | {:error, term()}
  def close(%__MODULE__{io: io}), do: File.close(io)
end
