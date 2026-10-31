defmodule Patchbay.Worker.Native do
  @moduledoc """
  Reserved worker operations for native toolkits that execute in the agent
  worker.

  The filesystem toolkit is the current member. Its roots are usually the
  agent-owned workspace or result directory, which the manager cannot traverse
  across the UID split, and the manager must never follow a symlink the agent
  controls there. The runtime therefore sends a rendered request to the
  worker; the worker resolves the root and confines every model path in the
  process that owns the tree.

  Operation names are reserved: agent definitions cannot declare them.
  """

  alias Patchbay.Toolkit.Native.Filesystem

  @filesystem_operation "patchbay-filesystem"

  @operations %{@filesystem_operation => Filesystem}

  @doc "Reserved operation name for the filesystem toolkit."
  @spec operation() :: binary()
  def operation, do: @filesystem_operation

  @doc "Every reserved worker operation name."
  @spec operations() :: [binary()]
  def operations, do: Map.keys(@operations)

  @doc "Returns true for a reserved worker operation name."
  @spec reserved?(term()) :: boolean()
  def reserved?(name) when is_binary(name), do: Map.has_key?(@operations, name)
  def reserved?(_name), do: false

  @doc """
  Runs a reserved operation from a manager request.

  Returns the worker result shape the protocol carries back.
  """
  @spec execute(binary(), term()) :: {:ok, map()} | {:error, term()}
  def execute(name, arguments) do
    case Map.fetch(@operations, name) do
      {:ok, module} -> module.worker_execute(arguments)
      :error -> {:error, {:unknown_operation, name}}
    end
  end
end
