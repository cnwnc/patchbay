defmodule Patchbay.Config do
  @moduledoc """
  Runtime paths for the manager.

  Paths are resolved from explicit options, then the environment, then
  defaults relative to the working directory:

    * `home` from `PATCHBAY_HOME`, default the working directory
    * `config_dir` from `PATCHBAY_CONFIG_DIR`, default `home/config`
    * `state_dir` from `PATCHBAY_STATE_DIR` or `STATE_DIR`, default
      `home/state`
    * `runtime_dir` from `PATCHBAY_RUNTIME_DIR` or `RUNTIME_DIR`, default
      `state_dir/runtime`
    * `workspace_dir` from `PATCHBAY_WORKSPACE_DIR`, default `home/workspaces`
    * `result_dir` from `PATCHBAY_RESULT_DIR`, default `home/results`

  All returned paths are absolute. `PATCHBAY_HOME` therefore determines the
  config, state, workspace, and result roots together.
  """

  defstruct [:home, :config_dir, :state_dir, :runtime_dir, :workspace_dir, :result_dir]

  @type t :: %__MODULE__{
          home: Path.t(),
          config_dir: Path.t(),
          state_dir: Path.t(),
          runtime_dir: Path.t(),
          workspace_dir: Path.t(),
          result_dir: Path.t()
        }

  @home_variables ["PATCHBAY_HOME"]
  @config_variables ["PATCHBAY_CONFIG_DIR"]
  @state_variables ["PATCHBAY_STATE_DIR", "STATE_DIR"]
  @runtime_variables ["PATCHBAY_RUNTIME_DIR", "RUNTIME_DIR"]
  @workspace_variables ["PATCHBAY_WORKSPACE_DIR"]
  @result_variables ["PATCHBAY_RESULT_DIR"]

  @doc """
  Resolves runtime paths.

  Options override the process environment. Pass `:env` with a string-keyed
  map to resolve from an explicit environment instead of `System.get_env/0`.
  """
  @spec load(keyword()) :: t()
  def load(opts \\ []) when is_list(opts) do
    env = Keyword.get(opts, :env, System.get_env())

    home = resolve(opts, :home, env, @home_variables, Path.expand("."))

    config_dir =
      resolve(opts, :config_dir, env, @config_variables, Path.join(home, "config"))

    state_dir = resolve(opts, :state_dir, env, @state_variables, Path.join(home, "state"))

    runtime_dir =
      resolve(
        opts,
        :runtime_dir,
        env,
        @runtime_variables,
        Path.join(state_dir, "runtime")
      )

    workspace_dir =
      resolve(opts, :workspace_dir, env, @workspace_variables, Path.join(home, "workspaces"))

    result_dir =
      resolve(opts, :result_dir, env, @result_variables, Path.join(home, "results"))

    %__MODULE__{
      home: home,
      config_dir: config_dir,
      state_dir: state_dir,
      runtime_dir: runtime_dir,
      workspace_dir: workspace_dir,
      result_dir: result_dir
    }
  end

  defp resolve(opts, key, env, variables, default) do
    opts
    |> Keyword.get(key)
    |> case do
      nil -> env_value(env, variables) || default
      path -> path
    end
    |> Path.expand()
  end

  defp env_value(env, variables) do
    Enum.find_value(variables, fn variable ->
      case Map.fetch(env, variable) do
        {:ok, value} when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
  end
end
