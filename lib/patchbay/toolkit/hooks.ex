defmodule Patchbay.Toolkit.Hooks do
  @moduledoc """
  Declares lifecycle init/finalize hooks and how they reach the agent worker.

  Hooks are fixed argv operations declared under `[[lifecycle.init]]` or
  `[[lifecycle.finalize]]`. They may reference fixed variables only. They run
  inside the agent's worker as fixed operations, using the worker protocol:
  the worker owns the agent workspace across the UID boundary, so a hook can
  create files there while the manager cannot. The worker renders hook argv
  with the variable map supplied per execution and runs with the workspace as
  the working directory when one exists. Execution never goes through a shell.
  """

  alias Patchbay.Definition.Toolkit.Operation

  @worker_prefix "patchbay-lifecycle-"
  @phases [:init, :finalize]

  @type phase :: :init | :finalize

  @type entry :: %{
          required(:declared) => String.t() | nil,
          required(:worker_name) => String.t(),
          required(:argv) => [String.t()],
          optional(:executable) => String.t()
        }

  @type plan :: %{
          required(:init) => [entry()],
          required(:finalize) => [entry()],
          required(:operations) => [map()]
        }

  @doc "Returns the declared hooks for `:init` or `:finalize`."
  @spec hooks(map() | nil, phase()) :: [Operation.t()]
  def hooks(nil, _phase), do: []
  def hooks(lifecycle, phase) when phase in @phases, do: Map.get(lifecycle, phase, [])

  @doc """
  One plan entry per declared hook, in declaration order, for both phases.

  `reserved` must list every operation name already declared for the agent;
  synthesized names never collide with one. Planning the same lifecycle and
  reserved list yields the same names, so the operations sent at worker start
  and the operations executed later stay in sync.
  """
  @spec plan(map() | nil, [String.t()]) :: plan()
  def plan(lifecycle, reserved \\ []) do
    {entries, _reserved} =
      @phases
      |> Enum.reduce({%{}, MapSet.new(List.wrap(reserved))}, fn phase, {entries, reserved} ->
        {phase_entries, reserved} = plan_entries(hooks(lifecycle, phase), phase, reserved)
        {Map.put(entries, phase, phase_entries), reserved}
      end)

    %{
      init: Map.fetch!(entries, :init),
      finalize: Map.fetch!(entries, :finalize),
      operations: Enum.flat_map(@phases, &worker_operations(Map.fetch!(entries, &1)))
    }
  end

  defp plan_entries(operations, phase, reserved) do
    operations
    |> Enum.with_index()
    |> Enum.reduce({[], reserved}, fn {operation, index}, {entries, reserved} ->
      name = unique_name("#{@worker_prefix}#{phase}-#{index}", reserved)
      reserved = MapSet.put(reserved, name)

      entry = %{declared: Map.get(operation, :name), worker_name: name, argv: argv(operation)}

      entry =
        case Map.get(operation, :executable) do
          nil -> entry
          executable -> Map.put(entry, :executable, executable)
        end

      {[entry | entries], reserved}
    end)
    |> then(fn {entries, reserved} -> {Enum.reverse(entries), reserved} end)
  end

  defp argv(%Operation{argv: argv}) when is_list(argv), do: argv
  defp argv(_operation), do: []

  defp unique_name(candidate, reserved) do
    if MapSet.member?(reserved, candidate) do
      unique_name("#{candidate}-2", reserved)
    else
      candidate
    end
  end

  defp worker_operations(entries) do
    Enum.map(entries, fn entry ->
      operation = %{name: entry.worker_name, argv: entry.argv}

      case Map.get(entry, :executable) do
        nil -> operation
        executable -> Map.put(operation, :executable, executable)
      end
    end)
  end
end
