defmodule Patchbay.ContextCompaction.Zstd do
  @moduledoc """
  Runs the `zstd` executable through an Erlang port.

  Arguments are passed as an argv list to `:spawn_executable`; no shell is
  involved, so file names and options cannot be reinterpreted as shell syntax.
  """

  @default_level 3
  @default_timeout 30_000

  @spec compress_file(Path.t(), Path.t(), keyword()) :: :ok | {:error, term()}
  def compress_file(input, output, opts \\ [])
      when is_binary(input) and is_binary(output) do
    with {:ok, executable} <- executable(opts) do
      args = ["-q", "-f", level_arg(opts), "-o", output, "--", input]
      run(executable, args, opts)
    end
  end

  @spec decompress_file(Path.t(), Path.t(), keyword()) :: :ok | {:error, term()}
  def decompress_file(input, output, opts \\ [])
      when is_binary(input) and is_binary(output) do
    with {:ok, executable} <- executable(opts) do
      args = ["-q", "-f", "-d", "-o", output, "--", input]
      run(executable, args, opts)
    end
  end

  defp level_arg(opts) do
    level = Keyword.get(opts, :zstd_level, @default_level)
    "-" <> Integer.to_string(level)
  end

  defp executable(opts) do
    requested =
      Keyword.get(opts, :zstd_executable) ||
        Keyword.get(opts, :zstd) ||
        "zstd"

    resolve(requested)
  end

  defp resolve(requested) when is_binary(requested) do
    cond do
      requested == "" or String.contains?(requested, <<0>>) ->
        {:error, :invalid_zstd_executable}

      Path.type(requested) == :absolute ->
        if File.regular?(requested) do
          {:ok, requested}
        else
          {:error, {:zstd_not_found, requested}}
        end

      true ->
        case System.find_executable(requested) do
          nil -> {:error, {:zstd_not_found, requested}}
          path -> {:ok, path}
        end
    end
  end

  defp resolve(requested), do: {:error, {:invalid_zstd_executable, requested}}

  defp run(executable, args, opts) do
    timeout = Keyword.get(opts, :zstd_timeout, @default_timeout)

    port =
      try do
        Port.open({:spawn_executable, executable}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:args, args}
        ])
      rescue
        error -> {:error, {:zstd_spawn_failed, Exception.message(error)}}
      catch
        kind, reason -> {:error, {:zstd_spawn_failed, {kind, reason}}}
      end

    case port do
      port when is_port(port) -> await(port, timeout)
      {:error, _reason} = error -> error
    end
  end

  defp await(port, timeout) do
    await(port, timeout, [])
  end

  defp await(port, timeout, output) do
    receive do
      {^port, {:data, data}} ->
        await(port, timeout, [data | output])

      {^port, {:exit_status, status}} ->
        result(port, status, output)
    after
      timeout ->
        close(port)
        {:error, :zstd_timeout}
    end
  end

  defp result(_port, 0, _output), do: :ok

  defp result(_port, status, output) do
    {:error, {:zstd_failed, status, output |> Enum.reverse() |> IO.iodata_to_binary()}}
  end

  defp close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
