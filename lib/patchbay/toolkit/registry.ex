defmodule Patchbay.Toolkit.Registry do
  @moduledoc """
  Registry of native toolkits implemented in Elixir.

  Built-ins are listed in `@builtins`. Additional modules can be registered at
  runtime with `register/2`; this is the extension point for toolkits such as
  a disk toolkit that ships in code but is not present in every build.

  Manifests reference a registered identifier. They never reference a module
  name.
  """

  alias Patchbay.Toolkit.Manifest

  @builtins %{
    "filesystem" => Patchbay.Toolkit.Native.Filesystem,
    "terminal" => Patchbay.Toolkit.Native.Terminal
  }

  @registered_key {__MODULE__, :registered}

  @doc "Identifiers of every registered native toolkit."
  @spec ids() :: [String.t()]
  def ids do
    @builtins |> Map.keys() |> Enum.concat(Map.keys(registered())) |> Enum.uniq() |> Enum.sort()
  end

  @doc "Returns the native toolkit module for `id`, or `nil`."
  @spec native_module(term()) :: module() | nil
  def native_module(id) when is_binary(id) do
    Map.get(@builtins, id) || Map.get(registered(), id)
  end

  def native_module(_id), do: nil

  @doc "Registers a native toolkit module under `id`."
  @spec register(String.t(), module()) :: :ok | {:error, term()}
  def register(id, module) when is_binary(id) and is_atom(module) do
    cond do
      not Regex.match?(~r/\A[a-z0-9][a-z0-9._-]{0,63}\z/, id) ->
        {:error, {:invalid_native_toolkit_id, id}}

      module in Map.values(@builtins) ->
        {:error, {:builtin_native_toolkit, id}}

      not Code.ensure_loaded?(module) ->
        {:error, {:native_toolkit_not_loaded, module}}

      function_exported?(module, :execute, 3) and function_exported?(module, :id, 0) ->
        :persistent_term.put(@registered_key, Map.put(registered(), id, module))
        :ok

      true ->
        {:error, {:invalid_native_toolkit, module}}
    end
  end

  @doc "Removes a runtime-registered native toolkit."
  @spec unregister(String.t()) :: :ok
  def unregister(id) when is_binary(id) do
    :persistent_term.put(@registered_key, Map.delete(registered(), id))
    :ok
  end

  @doc "Removes all runtime registrations. Intended for tests."
  @spec reset() :: :ok
  def reset do
    :persistent_term.erase(@registered_key)
    :ok
  end

  @doc """
  Returns tool specs for a native module, optionally filtered to `selection`.

  A `nil` or empty selection means every tool the module provides.
  """
  @spec tools(module() | String.t(), map(), [String.t()] | nil) :: [
          Patchbay.Toolkit.Native.tool()
        ]
  def tools(module_or_id, context, selection \\ nil) do
    module =
      if is_binary(module_or_id), do: native_module(module_or_id), else: module_or_id

    tools =
      case module do
        nil ->
          []

        module ->
          if Code.ensure_loaded?(module) and function_exported?(module, :tools, 1),
            do: module.tools(context),
            else: []
      end

    filter_tools(tools, selection)
  end

  @doc "Tool specs from implicit manifests, in manifest-name order."
  @spec implicit_tools(map(), keyword()) :: [Patchbay.Toolkit.Native.tool()]
  def implicit_tools(context, opts \\ []) do
    opts
    |> Manifest.implicit()
    |> Enum.sort_by(& &1.name)
    |> Enum.flat_map(fn manifest ->
      tools(manifest.native, context, manifest.tools)
    end)
    |> Enum.reduce(%{}, fn tool, acc -> Map.put_new(acc, tool.name, tool) end)
    |> Map.values()
  end

  @doc "Executes a tool on a native module."
  @spec execute(module(), String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def execute(module, tool_name, arguments, context) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :execute, 3) do
      module.execute(tool_name, arguments, context)
    else
      {:error, {:native_toolkit_not_executable, module}}
    end
  end

  defp filter_tools(tools, selection) do
    case selection do
      selection when is_list(selection) and selection != [] ->
        Enum.filter(tools, &(Map.get(&1, :name) in selection))

      _other ->
        tools
    end
  end

  defp registered do
    :persistent_term.get(@registered_key, %{})
  end
end
