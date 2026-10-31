defmodule Patchbay.Worker.Nix do
  @moduledoc """
  Builds the argv that starts a worker inside `nix shell`.

  An empty package list keeps the direct worker spawn. A non-empty list runs
  `nix shell <refs> --command <worker> <args>` using an argv list, never a
  shell string. Simple package names are prefixed with `nixpkgs#`; references
  that already name a flake installable or path are passed through. The host
  Nix registry and daemon configuration decide how those refs resolve.
  """

  alias Patchbay.Worker.Exec

  @max_packages 128
  @max_ref_bytes 4096
  @simple_name ~r/\A[A-Za-z0-9][A-Za-z0-9._+-]*\z/

  @type command :: {binary(), [binary()]}

  @doc """
  Validates and normalizes a package list.

  Every entry becomes one `nix shell` installable. Simple names gain the
  `nixpkgs#` prefix; explicit refs keep their spelling.
  """
  @spec normalize_packages(term()) :: {:ok, [String.t()]} | {:error, :invalid_packages}
  def normalize_packages(packages) when is_list(packages) and length(packages) <= @max_packages do
    packages
    |> Enum.reduce_while({:ok, []}, fn package, {:ok, normalized} ->
      case normalize_package(package) do
        {:ok, ref} -> {:cont, {:ok, [ref | normalized]}}
        {:error, :invalid_packages} -> {:halt, {:error, :invalid_packages}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, :invalid_packages} = error -> error
    end
  end

  def normalize_packages(_packages), do: {:error, :invalid_packages}

  @doc """
  Returns the executable and argv for a worker start.

  Options:
  - `:nix_executable` - explicit Nix client path; defaults to `nix` on `PATH`
  """
  @spec command([String.t()], binary(), [binary()], keyword()) ::
          {:ok, command()} | {:error, :invalid_packages | :nix_not_found}
  def command(packages, executable, args, opts \\ [])

  def command([], executable, args, _opts) when is_binary(executable) and is_list(args),
    do: {:ok, {executable, args}}

  def command(packages, executable, args, opts)
      when is_list(packages) and is_binary(executable) and is_list(args) do
    with {:ok, refs} <- normalize_packages(packages),
         {:ok, nix} <- nix_executable(Keyword.get(opts, :nix_executable)) do
      {:ok, {nix, ["shell" | refs] ++ ["--command", executable | args]}}
    end
  end

  def command(_packages, _executable, _args, _opts), do: {:error, :invalid_packages}

  defp normalize_package(package) when is_binary(package) do
    cond do
      byte_size(package) == 0 or byte_size(package) > @max_ref_bytes ->
        {:error, :invalid_packages}

      not String.valid?(package) ->
        {:error, :invalid_packages}

      unsafe_ref?(package) ->
        {:error, :invalid_packages}

      explicit_ref?(package) ->
        {:ok, package}

      Regex.match?(@simple_name, package) ->
        {:ok, "nixpkgs#" <> package}

      true ->
        {:error, :invalid_packages}
    end
  end

  defp normalize_package(_package), do: {:error, :invalid_packages}

  defp unsafe_ref?(package) do
    String.starts_with?(package, "-") or
      Enum.any?(:binary.bin_to_list(package), fn byte -> byte <= 0x20 or byte == 0x7F end) or
      String.trim(package) != package
  end

  defp explicit_ref?(package) do
    package == "nixpkgs" or
      String.contains?(package, "#") or
      String.contains?(package, ":") or
      String.starts_with?(package, ["/", "./", "../", "~/"])
  end

  defp nix_executable(nil) do
    case System.find_executable("nix") do
      nil -> {:error, :nix_not_found}
      path -> {:ok, path}
    end
  end

  defp nix_executable(path) when is_binary(path) do
    if Path.type(path) == :absolute and Exec.valid_executable?(path),
      do: {:ok, path},
      else: {:error, :nix_not_found}
  end

  defp nix_executable(_path), do: {:error, :nix_not_found}
end
