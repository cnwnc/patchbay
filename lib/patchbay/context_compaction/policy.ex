defmodule Patchbay.ContextCompaction.Policy do
  @moduledoc """
  Compaction thresholds resolved from an agent definition's `[context]` table.

  A missing or non-positive threshold disables compaction. When a threshold is
  present the target defaults to half of it and is clamped below the threshold
  so every compaction has to remove at least one token.
  """

  alias Patchbay.Definition.Context

  defstruct enabled?: false, threshold: nil, target: nil

  @type t :: %__MODULE__{
          enabled?: boolean(),
          threshold: non_neg_integer() | nil,
          target: non_neg_integer() | nil
        }

  @threshold_keys [
    :threshold,
    :compact_threshold,
    :compact_at,
    :"compact-threshold",
    :"compact-at",
    "threshold",
    "compact-threshold",
    "compact_at",
    "compact-at"
  ]

  @target_keys [
    :target,
    :compact_target,
    :compact_to,
    :"compact-target",
    :"compact-to",
    "target",
    "compact-target",
    "compact_target",
    "compact-to",
    "compact_to"
  ]

  @spec from(term(), keyword()) :: t()
  def from(source, opts \\ []) do
    fields = fields(source)
    threshold = override(Keyword.get(opts, :threshold), fields, @threshold_keys)
    target = override(Keyword.get(opts, :target), fields, @target_keys)

    cond do
      not is_integer(threshold) or threshold <= 0 ->
        %__MODULE__{}

      true ->
        threshold = threshold
        target = normalize_target(target, threshold)
        %__MODULE__{enabled?: true, threshold: threshold, target: target}
    end
  end

  @spec enabled?(t()) :: boolean()
  def enabled?(%__MODULE__{enabled?: enabled?}), do: enabled?

  defp override(value, _fields, _keys) when is_integer(value) and value >= 0, do: value
  defp override(_value, fields, keys), do: fetch_integer(fields, keys)

  defp fetch_integer(fields, keys) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(fields, key) do
        {:ok, value} when is_integer(value) and value >= 0 -> value
        _other -> nil
      end
    end)
  end

  defp normalize_target(target, threshold) do
    target =
      case target do
        value when is_integer(value) and value >= 0 -> value
        _other -> div(threshold, 2)
      end

    target
    |> max(0)
    |> min(max(threshold - 1, 0))
  end

  defp fields(%Context{} = context), do: Map.from_struct(context)

  defp fields(%{} = map) do
    case Map.fetch(map, :context) do
      {:ok, context} ->
        fields(context)

      :error ->
        case Map.fetch(map, "context") do
          {:ok, context} -> fields(context)
          :error -> map
        end
    end
  end

  defp fields(_source), do: %{}
end
