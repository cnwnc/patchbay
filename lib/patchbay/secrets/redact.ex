defmodule Patchbay.Secrets.Redact do
  @moduledoc """
  Best-effort removal of literal secret values from stored and model-facing
  data.

  The runtime keeps the values it injected into one agent's worker and runs
  them through this module before an event, tool-history record, persisted
  context message, or model-facing tool result is written. This covers the
  common case where a tool or the model echoes a token into an error message
  or command output.

  This is not an exfiltration barrier. An agent operation is explicitly given
  the secret and can encode, split, or otherwise transform it before returning
  text. Values shorter than four bytes are not replaced, because they would
  match unrelated text. Streamed model deltas are not rewritten.
  """

  @replacement "[redacted]"
  @minimum_bytes 4

  @doc """
  Replaces literal values from `values` in `term`.

  Maps, lists, tuples, and structs are traversed. Terms without candidates are
  returned unchanged.
  """
  @spec redact(term(), map()) :: term()
  def redact(term, values) when is_map(values) do
    case patterns(values) do
      [] -> term
      patterns -> walk(term, patterns)
    end
  end

  def redact(term, _values), do: term

  @doc "Returns the replacement marker used by `redact/2`."
  @spec replacement() :: String.t()
  def replacement, do: @replacement

  defp patterns(values) do
    values
    |> Map.values()
    |> Enum.filter(&(is_binary(&1) and byte_size(&1) >= @minimum_bytes))
    |> Enum.uniq()
    |> Enum.sort_by(&byte_size/1, :desc)
  end

  defp walk(binary, patterns) when is_binary(binary) do
    Enum.reduce(patterns, binary, fn pattern, acc ->
      :binary.replace(acc, pattern, @replacement, [:global])
    end)
  end

  defp walk(%_{} = struct, patterns) do
    struct
    |> Map.from_struct()
    |> Map.new(fn {key, value} -> {key, walk(value, patterns)} end)
    |> then(&struct(struct.__struct__, &1))
  end

  defp walk(%{} = map, patterns) do
    Map.new(map, fn {key, value} -> {key, walk(value, patterns)} end)
  end

  defp walk(list, patterns) when is_list(list), do: Enum.map(list, &walk(&1, patterns))

  defp walk(tuple, patterns) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&walk(&1, patterns))
    |> List.to_tuple()
  end

  defp walk(other, _patterns), do: other
end
