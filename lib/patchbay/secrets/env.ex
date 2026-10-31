defmodule Patchbay.Secrets.Env do
  @moduledoc """
  Agent-declared environment injection from the named secret store.

  A declaration is a toolkit whose manifest resolves to the built-in
  `secret-env` native toolkit:

      [[toolkits]]
      toolkit = "secret-env"

      [toolkits.config.env]
      GH_TOKEN = "secret://github-main"

  `env` maps an environment variable name to a `secret://<name>` reference.
  Bare names, absolute paths, values read from another environment variable,
  and inline literal values are rejected, so an agent manifest never contains
  secret bytes. Validation errors name the variable but never echo the
  reference string, which also keeps a mistakenly pasted value out of logs.

  The runtime resolves the references only while starting that agent's worker.
  Workers receive the selected values in their own environment; their
  operation children receive the same names; nothing is added to argv, tool
  schemas, or the general environment.
  """

  alias Patchbay.Secrets

  @scheme "secret://"
  @max_declarations 64

  @type declarations :: %{String.t() => String.t()}

  @doc """
  Reads and validates `secret-env` declarations from an agent definition.

  Returns a map of environment variable name to secret store name. Toolkits
  that do not resolve to `secret-env` are ignored.
  """
  @spec declarations(term()) :: {:ok, declarations()} | {:error, term()}
  def declarations(%{toolkits: toolkits}) when is_list(toolkits) do
    toolkits
    |> Enum.filter(&secret_toolkit?/1)
    |> Enum.reduce_while({:ok, %{}}, fn toolkit, {:ok, acc} ->
      case config_entries(Map.get(toolkit, :config, %{})) do
        {:ok, entries} ->
          case merge_entries(acc, entries) do
            {:ok, merged} -> {:cont, {:ok, merged}}
            {:error, _reason} = error -> {:halt, error}
          end

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  def declarations(_definition), do: {:ok, %{}}

  @doc "Parses one `secret://name` reference. Anything else is an error."
  @spec reference(term()) :: {:ok, String.t()} | :error
  def reference(@scheme <> name) do
    if Secrets.valid_name?(name), do: {:ok, name}, else: :error
  end

  def reference(_value), do: :error

  @doc """
  Validates a toolkit `config` at definition load time.

  Returns `{:error, path, message}` with a TOML-relative path below the
  toolkit `config` table. The message never includes the reference value.
  """
  @spec validate_config(term()) :: :ok | {:error, [String.t() | integer()], String.t()}
  def validate_config(config) when is_map(config) do
    case config_entries(config) do
      {:ok, _entries} -> :ok
      {:error, {path, message}} -> {:error, path, message}
      {:error, :invalid_config} -> {:error, ["env"], "must be a table"}
    end
  end

  def validate_config(_config), do: {:error, [], "must be a table"}

  @doc """
  Loads secret values for `declarations` from the store at `root`.

  An empty declaration map returns an empty map without touching the store.
  Any missing or unreadable secret fails resolution, so a worker is never
  started with a partially applied environment.
  """
  @spec resolve(declarations(), Path.t()) :: {:ok, %{String.t() => binary()}} | {:error, term()}
  def resolve(declarations, _root) when is_map(declarations) and map_size(declarations) == 0 do
    {:ok, %{}}
  end

  def resolve(declarations, root) when is_map(declarations) and is_binary(root) do
    declarations
    |> Enum.sort_by(fn {variable, _name} -> variable end)
    |> Enum.reduce_while({:ok, %{}}, fn {variable, name}, {:ok, values} ->
      case Secrets.fetch(root, name) do
        {:ok, value} ->
          {:cont, {:ok, Map.put(values, variable, value)}}

        {:error, :not_found} ->
          {:halt, {:error, {:missing_secret, name}}}

        {:error, :invalid_secret_name} ->
          {:halt, {:error, {:invalid_secret_reference, variable}}}

        {:error, :invalid_secret_file} ->
          {:halt, {:error, {:invalid_secret_file, name}}}

        {:error, _reason} ->
          {:halt, {:error, {:secret_unavailable, name}}}
      end
    end)
  end

  def resolve(_declarations, _root), do: {:error, :invalid_secret_store}

  defp config_entries(config) when is_map(config) do
    case fetch(config, :env) do
      nil -> {:ok, []}
      env when is_map(env) -> env_entries(env)
      _other -> {:error, :invalid_config}
    end
  end

  defp config_entries(_config), do: {:error, :invalid_config}

  defp env_entries(env) do
    env
    |> Enum.sort_by(fn {variable, _reference} -> to_string(variable) end)
    |> Enum.reduce_while({:ok, []}, fn {variable, reference}, {:ok, entries} ->
      cond do
        not is_binary(variable) or not Secrets.valid_variable?(variable) ->
          {:halt,
           {:error, {["env", to_string(variable)], "is not an injectable environment variable"}}}

        not is_binary(reference) ->
          {:halt, {:error, {["env", variable], "must reference a secret as secret://<name>"}}}

        true ->
          case reference(reference) do
            {:ok, name} ->
              {:cont, {:ok, [{variable, name} | entries]}}

            :error ->
              {:halt, {:error, {["env", variable], "must reference a secret as secret://<name>"}}}
          end
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, _reason} = error -> error
    end
  end

  defp merge_entries(acc, entries) do
    Enum.reduce_while(entries, {:ok, acc}, fn {variable, name}, {:ok, acc} ->
      cond do
        map_size(acc) >= @max_declarations ->
          {:halt, {:error, :too_many_declarations}}

        Map.has_key?(acc, variable) ->
          {:halt, {:error, {:duplicate_variable, variable}}}

        true ->
          {:cont, {:ok, Map.put(acc, variable, name)}}
      end
    end)
  end

  defp secret_toolkit?(toolkit) do
    case Map.get(toolkit, :native) do
      "secret-env" -> true
      nil -> Map.get(toolkit, :toolkit) == "secret-env"
      _other -> false
    end
  end

  defp fetch(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key))
    end
  end

  defp fetch(_map, _key), do: nil
end
