defmodule Patchbay.Toolkit.Native do
  @moduledoc """
  Behaviour for built-in toolkits implemented in Elixir.

  A native toolkit is registered in code with `Patchbay.Toolkit.Registry` and
  referenced by identifier from a TOML manifest. Manifests never name modules,
  so configuration cannot load arbitrary Elixir code.

  A tool is a map with `:name`, `:description`, and `:schema` (a JSON Schema
  object for the tool arguments). `execute/3` receives the tool name, the
  model-supplied arguments, and a runtime context containing at least
  `:definition` and `:variables`.
  """

  @type tool :: %{
          required(:name) => String.t(),
          required(:description) => String.t(),
          required(:schema) => map()
        }

  @type context :: map()

  @callback id() :: String.t()
  @callback tools(context()) :: [tool()]
  @callback execute(String.t(), map(), context()) :: {:ok, map()} | {:error, term()}

  # A module exporting these runs its tools in the agent worker. The request
  # must fit the worker wire format, and the result is decoded back in the
  # manager.
  @callback worker_operation() :: String.t()
  @callback worker_request(String.t(), map(), context()) :: {:ok, map()} | {:error, term()}
  @callback worker_result(term()) :: {:ok, map()} | {:error, term()}

  @optional_callbacks tools: 1,
                      worker_operation: 0,
                      worker_request: 3,
                      worker_result: 1
end
