defmodule Patchbay.CLI.Secrets do
  @moduledoc """
  `patchbay secrets` command group.

  The commands operate directly on the manager secret store and never require
  the manager service to be running. Values are read from standard input; a
  value is never accepted as an argument, so it cannot appear in the process
  list or shell history.

      patchbay secrets list
      printf 'value' | patchbay secrets set github-main
      patchbay secrets get github-main
      patchbay secrets delete github-main

  Pass `--secrets-dir` or `--state-dir` when the service environment is not
  inherited, for example when running as the manager user:

      sudo -u patchbay env PATCHBAY_STATE_DIR=/var/lib/patchbay \\
        patchbay secrets set github-main
  """

  alias Patchbay.Config
  alias Patchbay.Secrets

  @usage """
  Usage: patchbay secrets <command> [options]

    list                    List secret names
    set <name>              Read a value from stdin and create or replace it
    get <name>              Write the raw value to stdout
    delete <name>           Delete one secret

  Options:
    --secrets-dir <path>    Secret store directory
    --state-dir <path>      Manager state directory (store defaults to <state>/secrets)
  """

  @spec main([binary()]) :: no_return()
  def main(argv) do
    case run(argv) do
      :ok -> System.halt(0)
      {:error, message, status} -> fail(message, status)
    end
  end

  @doc false
  @spec run([binary()]) :: :ok | {:error, String.t(), non_neg_integer()}
  def run(argv) do
    with {:ok, opts, positional} <- split_options(argv, [], []) do
      store = store_dir(opts)

      case positional do
        ["list"] ->
          with {:ok, names} <- Secrets.list(store) do
            Enum.each(names, &IO.puts/1)
          else
            {:error, reason} -> {:error, "cannot list secrets: #{format(reason)}", 1}
          end

        ["set", name] ->
          value = IO.binread(:stdio, :eof)

          with {:ok, value} <- read_value(value),
               :ok <- Secrets.put(store, name, Secrets.strip_input_newline(value)) do
            IO.puts("set #{name}")
          else
            {:error, reason} -> {:error, "cannot set secret: #{format(reason)}", 1}
          end

        ["get", name] ->
          with {:ok, value} <- Secrets.fetch(store, name) do
            IO.binwrite(:stdio, value)
          else
            {:error, reason} -> {:error, "cannot read secret: #{format(reason)}", 1}
          end

        ["delete", name] ->
          with :ok <- Secrets.delete(store, name) do
            IO.puts("deleted #{name}")
          else
            {:error, reason} -> {:error, "cannot delete secret: #{format(reason)}", 1}
          end

        ["help"] ->
          IO.puts(@usage)

        ["--help"] ->
          IO.puts(@usage)

        [] ->
          {:error, @usage, 2}

        [unknown | _rest] ->
          {:error, "patchbay secrets: unknown command #{inspect(unknown)}\n\n" <> @usage, 2}
      end
    else
      {:error, message} -> {:error, message <> "\n\n" <> @usage, 2}
    end
  end

  @doc "Resolves the store directory the same way the manager does."
  @spec store_dir(keyword()) :: Path.t()
  def store_dir(opts) do
    config = Config.load(Keyword.take(opts, [:state_dir, :secrets_dir]))
    config.secrets_dir
  end

  defp read_value(nil), do: {:error, :missing_value}
  defp read_value(value) when is_binary(value), do: {:ok, value}
  defp read_value(_value), do: {:error, :missing_value}

  defp split_options([], opts, positional), do: {:ok, opts, positional}

  defp split_options(["--secrets-dir", path | rest], opts, positional),
    do: split_options(rest, Keyword.put(opts, :secrets_dir, path), positional)

  defp split_options(["--state-dir", path | rest], opts, positional),
    do: split_options(rest, Keyword.put(opts, :state_dir, path), positional)

  defp split_options(["--secrets-dir=" <> path | rest], opts, positional),
    do: split_options(rest, Keyword.put(opts, :secrets_dir, path), positional)

  defp split_options(["--state-dir=" <> path | rest], opts, positional),
    do: split_options(rest, Keyword.put(opts, :state_dir, path), positional)

  defp split_options(["--" <> flag | _rest], _opts, _positional),
    do: {:error, "patchbay secrets: unknown option #{inspect(flag)}"}

  defp split_options([arg | rest], opts, positional) when is_binary(arg),
    do: split_options(rest, opts, positional ++ [arg])

  defp split_options([_arg | _rest], _opts, _positional),
    do: {:error, "patchbay secrets: invalid argument"}

  defp format(:invalid_secret_name), do: "name must match [a-z0-9][a-z0-9._-]{0,63}"
  defp format(:not_found), do: "secret not found"
  defp format(:invalid_secret_value), do: "value is too large or contains a NUL byte"

  defp format(:invalid_secret_file),
    do: "store path is not a regular file (symlinks and directories are refused)"

  defp format(reason) when is_binary(reason), do: reason
  defp format(reason), do: inspect(reason)

  defp fail(message, status) do
    IO.puts(:stderr, message)
    System.halt(status)
  end
end
