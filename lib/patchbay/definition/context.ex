defmodule Patchbay.Definition.Context do
  @moduledoc """
  Policy for what context an agent receives at activation boundaries.

  Values are kept as declared strings because the context vocabulary is still
  being defined; the loader validates their shape, not their meaning.
  """

  alias Patchbay.Definition.Parse

  defstruct between_runs: nil,
            prior_runs: nil,
            restore_interrupted: nil,
            threshold: nil,
            target: nil

  @type t :: %__MODULE__{
          between_runs: String.t() | nil,
          prior_runs: String.t() | nil,
          restore_interrupted: String.t() | nil,
          threshold: non_neg_integer() | nil,
          target: non_neg_integer() | nil
        }

  @spec from_map(term(), Parse.errors()) :: {t(), Parse.errors()}
  def from_map(nil, errors), do: {%__MODULE__{}, errors}

  def from_map(raw, errors) when is_map(raw) do
    {between_runs, errors} =
      Parse.optional_string(raw, "between-runs", ["context", "between-runs"], errors)

    {prior_runs, errors} =
      Parse.optional_string(raw, "prior-runs", ["context", "prior-runs"], errors)

    {restore_interrupted, errors} =
      Parse.optional_string(
        raw,
        "restore-interrupted",
        ["context", "restore-interrupted"],
        errors
      )

    {threshold, errors} =
      optional_integer_alias(raw, ~w(threshold compact-threshold compact-at), errors)

    {target, errors} = optional_integer_alias(raw, ~w(target compact-target compact-to), errors)

    {%__MODULE__{
       between_runs: between_runs,
       prior_runs: prior_runs,
       restore_interrupted: restore_interrupted,
       threshold: threshold,
       target: target
     }, errors}
  end

  def from_map(_raw, errors) do
    {%__MODULE__{}, Parse.error(errors, ["context"], "must be a table")}
  end

  defp optional_integer_alias(raw, keys, errors) do
    case Enum.find(keys, &Map.has_key?(raw, &1)) do
      nil -> {nil, errors}
      key -> Parse.optional_integer(raw, key, ["context", key], errors)
    end
  end
end
