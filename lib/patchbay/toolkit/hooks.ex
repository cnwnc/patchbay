defmodule Patchbay.Toolkit.Hooks do
  @moduledoc """
  Expands and runs lifecycle init/finalize hooks.

  Hooks are fixed argv operations declared under `[[lifecycle.init]]` or
  `[[lifecycle.finalize]]`. They may reference fixed variables only. Execution
  uses the same argv rendering rules as fixed operations and never goes
  through a shell.
  """

  alias Patchbay.Definition.Toolkit.Operation
  alias Patchbay.Toolkit.Variables
  alias Patchbay.Worker.Exec

  @type expanded :: %{name: String.t() | nil, executable: String.t(), argv: [String.t()]}
  @type outcome :: {String.t() | nil, {:ok, Exec.result()} | {:error, term()}}

  @doc "Returns the declared hooks for `:init` or `:finalize`."
  @spec hooks(map() | nil, :init | :finalize) :: [Operation.t()]
  def hooks(nil, _phase), do: []
  def hooks(lifecycle, phase) when phase in [:init, :finalize], do: Map.get(lifecycle, phase, [])

  @doc "Renders hook argv with the supplied fixed variables."
  @spec expand(map() | nil, :init | :finalize, map()) ::
          {:ok, [expanded()]} | {:error, {String.t() | nil, term()}}
  def expand(lifecycle, phase, variables) do
    lifecycle
    |> hooks(phase)
    |> Enum.reduce_while({:ok, []}, fn operation, {:ok, acc} ->
      case expand_hook(operation, variables) do
        {:ok, hook} -> {:cont, {:ok, [hook | acc]}}
        {:error, reason} -> {:halt, {:error, {Map.get(operation, :name), reason}}}
      end
    end)
    |> case do
      {:ok, hooks} -> {:ok, Enum.reverse(hooks)}
      error -> error
    end
  end

  @doc "Runs every declared hook, reporting one outcome per hook."
  @spec run(map() | nil, :init | :finalize, map(), keyword()) :: [outcome()]
  def run(lifecycle, phase, variables, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    max_output_bytes = Keyword.get(opts, :max_output_bytes, 262_144)
    cd = variables["workspace"]

    lifecycle
    |> hooks(phase)
    |> Enum.map(fn operation ->
      name = Map.get(operation, :name)

      outcome =
        with {:ok, hook} <- expand_hook(operation, variables),
             exec_opts <- [timeout: timeout, max_output_bytes: max_output_bytes] ++ cd_option(cd),
             {:ok, result} <- Exec.run(hook.executable, hook.argv, exec_opts) do
          if result.exit_status == 0 do
            {:ok, result}
          else
            {:error, {:exit_status, result.exit_status, result.output}}
          end
        end

      {name, outcome}
    end)
  end

  @doc "Runs one expanded hook."
  @spec execute(expanded(), keyword()) :: {:ok, Exec.result()} | {:error, term()}
  def execute(%{executable: executable, argv: argv}, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    max_output_bytes = Keyword.get(opts, :max_output_bytes, 262_144)
    cd = Keyword.get(opts, :cd)

    exec_opts =
      [timeout: timeout, max_output_bytes: max_output_bytes] ++ cd_option(cd)

    case Exec.run(executable, argv, exec_opts) do
      {:ok, result} ->
        if result.exit_status == 0 do
          {:ok, result}
        else
          {:error, {:exit_status, result.exit_status, result.output}}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp expand_hook(%Operation{} = operation, variables) do
    {executable, args} =
      case operation.executable do
        nil -> {List.first(operation.argv), Enum.drop(operation.argv, 1)}
        executable -> {executable, operation.argv}
      end

    with true <- is_binary(executable) and Path.type(executable) == :absolute,
         {:ok, argv} <- Variables.render_argv(args, variables, %{}) do
      {:ok, %{name: operation.name, executable: executable, argv: argv}}
    else
      false -> {:error, :invalid_executable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp expand_hook(_operation, _variables), do: {:error, :invalid_hook}

  defp cd_option(nil), do: []
  defp cd_option(cd) when is_binary(cd), do: [cd: cd]
end
