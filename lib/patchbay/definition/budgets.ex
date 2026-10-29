defmodule Patchbay.Definition.Budgets do
  @moduledoc """
  Limits for a single agent run.
  """

  alias Patchbay.Definition.Parse

  defstruct run_seconds: nil, tokens: nil

  @type t :: %__MODULE__{
          run_seconds: non_neg_integer() | nil,
          tokens: non_neg_integer() | nil
        }

  @spec from_map(term(), Parse.errors()) :: {t(), Parse.errors()}
  def from_map(nil, errors), do: {%__MODULE__{}, errors}

  def from_map(raw, errors) when is_map(raw) do
    {run_seconds, errors} =
      Parse.optional_integer(raw, "run-seconds", ["budgets", "run-seconds"], errors)

    {tokens, errors} = Parse.optional_integer(raw, "tokens", ["budgets", "tokens"], errors)

    {%__MODULE__{run_seconds: run_seconds, tokens: tokens}, errors}
  end

  def from_map(_raw, errors) do
    {%__MODULE__{}, Parse.error(errors, ["budgets"], "must be a table")}
  end
end
