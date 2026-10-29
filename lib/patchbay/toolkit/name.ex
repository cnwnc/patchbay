defmodule Patchbay.Toolkit.Name do
  @moduledoc """
  The identifier shape shared by toolkit operations and provider tool names.

  Provider function names are restricted to letters, digits, underscores, and
  hyphens, with at most 64 bytes. Operation declarations use the same shape so
  a valid definition cannot produce a request the provider rejects.
  """

  @regex ~r/\A[A-Za-z0-9_-]{1,64}\z/

  @doc "Returns true when `name` is a provider-safe operation identifier."
  @spec valid?(term()) :: boolean()
  def valid?(name) when is_binary(name) do
    String.valid?(name) and Regex.match?(@regex, name)
  end

  def valid?(_name), do: false

  @doc "Returns the shared identifier regex."
  @spec regex() :: Regex.t()
  def regex, do: @regex
end
