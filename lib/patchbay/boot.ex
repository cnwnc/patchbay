defmodule Patchbay.Boot do
  @moduledoc """
  Classifies the process entry point from the command line.

  The application starts before a release or escript dispatches to
  `Patchbay.CLI`. Boot-sensitive infrastructure is selected from this role so a
  worker VM never starts the web endpoint, definition registry, manager, or
  runtime.
  """

  @type role :: :app | :manager | :worker_supervisor | :worker | :cli

  @doc """
  Returns the role implied by `argv`.

  An escript that is invoked bare or with an unknown command is a CLI
  invocation and must print usage instead of booting the application.
  `opts[:escript]` overrides escript detection.
  """
  @spec role([binary()], keyword()) :: role()
  def role(argv \\ System.argv(), opts \\ []) do
    case classify(argv) do
      :unknown -> if escript?(opts), do: :cli, else: :app
      role -> role
    end
  end

  @doc "Returns true when the current VM was started by `escript`."
  @spec escript?(keyword()) :: boolean()
  def escript?(opts \\ []) do
    case Keyword.fetch(opts, :escript) do
      {:ok, escript?} -> escript?
      :error -> escript_runtime?()
    end
  end

  @doc "Returns true when this role owns the web endpoint."
  @spec web?(role() | [binary()]) :: boolean()
  def web?(role) when is_atom(role), do: role in [:app, :manager]
  def web?(argv) when is_list(argv), do: web?(role(argv))

  defp classify(["run-manager" | _rest]), do: :manager
  defp classify(["run-worker-supervisor" | _rest]), do: :worker_supervisor
  defp classify(["run-worker" | _rest]), do: :worker
  defp classify(["secrets" | _rest]), do: :cli
  defp classify(["help" | _rest]), do: :cli
  defp classify(["--help" | _rest]), do: :cli
  defp classify(_argv), do: :unknown

  defp escript_runtime? do
    match?({:ok, _}, :init.get_argument(:patchbay_escript))
  end
end
