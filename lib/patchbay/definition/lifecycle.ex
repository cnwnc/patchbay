defmodule Patchbay.Definition.Lifecycle do
  @moduledoc """
  How an agent is activated and how overlapping activations are handled.

  `kind` is required. A `:scheduled` lifecycle also requires `schedule` and
  accepts `overlap` and `catch_up`. The only supported overlap policy is
  `forbid`; `allow` and `queue` are rejected until the scheduler implements
  them. `:one_shot` and `:perpetual` lifecycles do not accept those scheduling
  fields.
  """

  alias Patchbay.Definition.Parse
  alias Patchbay.Definition.Toolkit.Operation

  @kinds %{
    "one-shot" => :one_shot,
    "one_shot" => :one_shot,
    "scheduled" => :scheduled,
    "perpetual" => :perpetual
  }

  @overlaps %{"forbid" => :forbid}
  @catch_ups %{"once" => :once, "none" => :none, "all" => :all}

  defstruct kind: nil, schedule: nil, overlap: nil, catch_up: nil, init: [], finalize: []

  @type kind :: :one_shot | :scheduled | :perpetual
  @type overlap :: :forbid | nil
  @type catch_up :: :once | :none | :all | nil

  @type t :: %__MODULE__{
          kind: kind() | nil,
          schedule: String.t() | nil,
          overlap: overlap(),
          catch_up: catch_up(),
          init: [Operation.t()],
          finalize: [Operation.t()]
        }

  @spec from_map(term(), Parse.errors()) :: {t() | nil, Parse.errors()}
  def from_map(nil, errors) do
    {nil, Parse.error(errors, ["lifecycle"], "is required")}
  end

  def from_map(raw, errors) when is_map(raw) do
    {kind, errors} =
      Parse.required_enum(raw, "kind", ["lifecycle", "kind"], @kinds, errors)

    {schedule, errors} =
      Parse.optional_string(raw, "schedule", ["lifecycle", "schedule"], errors)

    {overlap, errors} =
      Parse.optional_enum(raw, "overlap", ["lifecycle", "overlap"], @overlaps, errors)

    {catch_up, errors} =
      Parse.optional_enum(raw, "catch-up", ["lifecycle", "catch-up"], @catch_ups, errors)

    {init, errors} = hooks_from(raw, "init", errors)
    {finalize, errors} = hooks_from(raw, "finalize", errors)

    errors = validate_variant(kind, raw, schedule, errors)

    lifecycle = %__MODULE__{
      kind: kind,
      schedule: schedule,
      overlap: overlap,
      catch_up: catch_up,
      init: init,
      finalize: finalize
    }

    {lifecycle, errors}
  end

  def from_map(_raw, errors) do
    {nil, Parse.error(errors, ["lifecycle"], "must be a table")}
  end

  defp validate_variant(:scheduled, raw, schedule, errors) do
    if is_nil(schedule) and not Map.has_key?(raw, "schedule") do
      Parse.error(errors, ["lifecycle", "schedule"], "is required for a scheduled lifecycle")
    else
      errors
    end
  end

  defp validate_variant(kind, raw, _schedule, errors) when kind in [:one_shot, :perpetual] do
    Enum.reduce(["schedule", "overlap", "catch-up"], errors, fn field, errors ->
      if Map.has_key?(raw, field) do
        Parse.error(
          errors,
          ["lifecycle", field],
          "is only valid for a scheduled lifecycle"
        )
      else
        errors
      end
    end)
  end

  defp validate_variant(_kind, _raw, _schedule, errors), do: errors

  defp hooks_from(raw, field, errors) do
    case Map.fetch(raw, field) do
      :error ->
        {[], errors}

      {:ok, list} when is_list(list) ->
        list
        |> Enum.with_index()
        |> Enum.reduce({[], errors}, fn {raw_hook, index}, {hooks, errors} ->
          {hook, errors} =
            Operation.from_hook_map(raw_hook, errors, ["lifecycle", field, index])

          {[hook | hooks], errors}
        end)
        |> then(fn {hooks, errors} ->
          {hooks |> Enum.reverse() |> Enum.reject(&is_nil/1), errors}
        end)

      {:ok, _value} ->
        {[], Parse.error(errors, ["lifecycle", field], "must be an array of tables")}
    end
  end
end
