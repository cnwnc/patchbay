defmodule Patchbay.Definition.Environment do
  @moduledoc """
  The Nix package set made available to an agent's worker.
  """

  alias Patchbay.Definition.Parse

  defstruct packages: []

  @type t :: %__MODULE__{packages: [String.t()]}

  @spec from_map(term(), Parse.errors()) :: {t(), Parse.errors()}
  def from_map(nil, errors), do: {%__MODULE__{}, errors}

  def from_map(raw, errors) when is_map(raw) do
    {packages, errors} =
      case Map.fetch(raw, "packages") do
        :error -> {[], errors}
        {:ok, value} -> Parse.string_list(value, ["environment", "packages"], errors)
      end

    packages = packages || []
    errors = duplicate_errors(packages, ["environment", "packages"], errors)

    {%__MODULE__{packages: packages}, errors}
  end

  def from_map(_raw, errors) do
    {%__MODULE__{}, Parse.error(errors, ["environment"], "must be a table")}
  end

  defp duplicate_errors(packages, path, errors) do
    packages
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {package, index}, errors ->
      if package in Enum.take(packages, index) do
        Parse.error(errors, path ++ [index], "duplicates #{inspect(package)}")
      else
        errors
      end
    end)
  end
end
