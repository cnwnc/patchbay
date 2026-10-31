defmodule Patchbay.Toolkit.Native.SecretEnv do
  @moduledoc """
  Declaration-only toolkit for secret environment injection.

  This toolkit exposes no tools. Its manifest exists so an agent can declare
  `toolkit = "secret-env"` and put `env = {VAR = "secret://name"}` in the
  toolkit config. `Patchbay.Secrets.Env` reads that config when the runtime
  starts the agent's worker.
  """

  @behaviour Patchbay.Toolkit.Native

  alias Patchbay.Secrets.Env

  @impl true
  def id, do: "secret-env"

  @impl true
  def tools(_context), do: []

  @impl true
  def execute(name, _arguments, _context), do: {:error, {:secret_env_has_no_tools, name}}

  @doc "Validates the `env` table at definition load time."
  @spec validate_config(term()) :: :ok | {:error, [String.t() | integer()], String.t()}
  def validate_config(config), do: Env.validate_config(config)
end
