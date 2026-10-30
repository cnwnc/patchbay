defmodule Patchbay.DefinitionRegistry do
  @moduledoc """
  An in-memory registry of validated agent definitions.

  The registry reads `config/agents/<id>/agent.toml`, validates each definition
  with `Patchbay.Definition.load/2`, and keeps the last good definition for
  every agent. Each snapshot carries a monotonically increasing revision that
  starts at 1 and advances when the validated definition changes.

  `reload/1` rescans the config tree and only re-reads directories whose
  contents changed since the previous scan. Shared prompts and scripts are
  included in that check. A changed directory that fails validation is
  reported but does not replace its previous snapshot. Directories without a
  regular `agent.toml` are reported as failures. Symlinked agent directories
  and symlinked `agent.toml` files are ignored.

  There is no file watcher; callers drive refresh with `reload/1`.

      {:ok, registry} = Patchbay.DefinitionRegistry.start_link(config_dir: "/srv/patchbay/config")

      [%Patchbay.DefinitionRegistry.Snapshot{}] =
        Patchbay.DefinitionRegistry.list(registry)

      {:ok, snapshot} = Patchbay.DefinitionRegistry.get("researcher", registry)
      {:ok, report} = Patchbay.DefinitionRegistry.reload(registry)

  """

  use GenServer

  alias Patchbay.Config
  alias Patchbay.Definition
  alias Patchbay.Definition.Error

  defmodule Snapshot do
    @moduledoc """
    One validated definition and its revision.
    """

    @enforce_keys [:id, :revision, :definition, :fingerprint, :loaded_at]
    defstruct [:id, :revision, :definition, :fingerprint, :loaded_at]

    @type t :: %__MODULE__{
            id: String.t(),
            revision: pos_integer(),
            definition: Patchbay.Definition.t(),
            fingerprint: binary(),
            loaded_at: DateTime.t()
          }
  end

  defmodule Failure do
    @moduledoc """
    The validation failure for a changed agent directory.

    The failing definition is not installed. If a previous snapshot exists it
    remains available through `get/2` and `list/1`.
    """

    @enforce_keys [:id, :error, :fingerprint, :attempted_at]
    defstruct [:id, :error, :fingerprint, :attempted_at]

    @type t :: %__MODULE__{
            id: String.t(),
            error: Error.t(),
            fingerprint: binary(),
            attempted_at: DateTime.t()
          }
  end

  defmodule Report do
    @moduledoc """
    The outcome of one `reload/1` call.
    """

    defstruct loaded: [], unchanged: [], removed: [], rejected: []

    @type t :: %__MODULE__{
            loaded: [Snapshot.t()],
            unchanged: [Snapshot.t()],
            removed: [String.t()],
            rejected: [Failure.t()]
          }
  end

  @type server :: GenServer.server()

  @doc """
  Starts a registry.

  Options:

    * `:name` - registered name, default `#{inspect(__MODULE__)}`; pass `nil`
      to start an unnamed process
    * `:config_dir` - config root, default from `Patchbay.Config`
    * `:config` - an existing `Patchbay.Config` struct
    * `:env` - environment map used when resolving defaults
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, init_opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.get(opts, :name, __MODULE__)},
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @doc """
  Lists snapshots ordered by agent ID.
  """
  @spec list(server()) :: [Snapshot.t()]
  def list(server \\ __MODULE__), do: GenServer.call(server, :list)

  @doc """
  Fetches one snapshot by agent ID.
  """
  @spec get(String.t(), server()) :: {:ok, Snapshot.t()} | {:error, :not_found}
  def get(id, server \\ __MODULE__)

  def get(id, server) when is_binary(id), do: GenServer.call(server, {:get, id})

  def get(server, id) when is_binary(id), do: GenServer.call(server, {:get, id})

  @doc """
  Fetches one definition by agent ID, without its revision metadata.
  """
  @spec definition(String.t(), server()) ::
          {:ok, Definition.t()} | {:error, :not_found}
  def definition(id, server \\ __MODULE__) do
    case get(id, server) do
      {:ok, snapshot} -> {:ok, snapshot.definition}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Lists current definitions ordered by agent ID.

  Use `list/1` when the revision or load time is needed.
  """
  @spec definitions(server()) :: [Definition.t()]
  def definitions(server \\ __MODULE__) do
    server
    |> list()
    |> Enum.map(& &1.definition)
  end

  @doc """
  Fetches the revision of one agent.
  """
  @spec revision(String.t(), server()) ::
          {:ok, pos_integer()} | {:error, :not_found}
  def revision(id, server \\ __MODULE__) do
    case get(id, server) do
      {:ok, snapshot} -> {:ok, snapshot.revision}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Lists the current validation failures, ordered by agent ID.
  """
  @spec errors(server()) :: [Failure.t()]
  def errors(server \\ __MODULE__), do: GenServer.call(server, :errors)

  @doc """
  Returns the registry's resolved `Patchbay.Config`.
  """
  @spec config(server()) :: Config.t()
  def config(server \\ __MODULE__), do: GenServer.call(server, :config)

  @doc """
  Rescans the agents directory, re-reading only changed agent directories.

  Returns a report. Rejected directories are included in `report.rejected`;
  their previous snapshots remain available.
  """
  @spec reload(server()) :: {:ok, Report.t()}
  def reload(server \\ __MODULE__), do: GenServer.call(server, :reload, :infinity)

  @doc """
  Re-reads one agent directory even when its fingerprint is unchanged.

  Returns the current snapshot when the definition is valid. On validation
  failure the previous snapshot is kept and the error is returned.
  """
  @spec reload_agent(String.t(), server()) ::
          {:ok, Snapshot.t()} | {:error, Error.t()} | {:error, :not_found}
  def reload_agent(id, server \\ __MODULE__) when is_binary(id) do
    GenServer.call(server, {:reload_agent, id}, :infinity)
  end

  @impl true
  def init(opts) do
    config =
      case Keyword.get(opts, :config) do
        %Config{} = config -> config
        nil -> Config.load(opts)
      end

    state = %{
      config: config,
      entries: %{},
      failures: %{},
      revisions: %{}
    }

    {state, _report} = scan(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:list, _from, state) do
    {:reply, sorted_snapshots(state), state}
  end

  def handle_call({:get, id}, _from, state) do
    reply =
      case Map.fetch(state.entries, id) do
        {:ok, snapshot} -> {:ok, snapshot}
        :error -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call(:errors, _from, state) do
    {:reply, sorted_failures(state), state}
  end

  def handle_call(:config, _from, state) do
    {:reply, state.config, state}
  end

  def handle_call(:reload, _from, state) do
    {state, report} = scan(state)
    {:reply, {:ok, report}, state}
  end

  def handle_call({:reload_agent, id}, _from, state) do
    case Map.fetch(agent_directories(state.config), id) do
      {:ok, directory} ->
        shared = shared_fingerprint(state.config.config_dir)
        {state, outcome} = refresh(state, id, directory, shared, true)

        reply =
          case outcome do
            {:loaded, snapshot} -> {:ok, snapshot}
            {:unchanged, snapshot} -> {:ok, snapshot}
            {:rejected, failure} -> {:error, failure.error}
          end

        {:reply, reply, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  defp scan(state) do
    directories = agent_directories(state.config)
    invalid = invalid_agent_directories(state.config)
    shared = shared_fingerprint(state.config.config_dir)

    ids =
      directories
      |> Map.keys()
      |> Kernel.++(Map.keys(invalid))
      |> Kernel.++(Map.keys(state.entries))
      |> Kernel.++(Map.keys(state.failures))
      |> Enum.uniq()
      |> Enum.sort()

    Enum.reduce(ids, {state, %Report{}}, fn id, {state, report} ->
      cond do
        Map.has_key?(directories, id) ->
          {state, outcome} = refresh(state, id, directories[id], shared, false)
          {state, add_outcome(report, outcome)}

        Map.has_key?(invalid, id) ->
          {state, outcome} = record_invalid(state, id, invalid[id], shared)
          {state, add_outcome(report, outcome)}

        true ->
          state = remove(state, id)
          {state, %{report | removed: report.removed ++ [id]}}
      end
    end)
  end

  defp refresh(state, id, directory, shared, force) do
    fingerprint = agent_fingerprint(directory, shared)
    entry = Map.get(state.entries, id)
    failure = Map.get(state.failures, id)

    cond do
      not force and match?(%Snapshot{fingerprint: ^fingerprint}, entry) ->
        {clear_failure(state, id), {:unchanged, entry}}

      not force and match?(%Failure{fingerprint: ^fingerprint}, failure) ->
        {state, {:rejected, failure}}

      true ->
        install(state, id, directory, fingerprint, entry)
    end
  end

  defp install(state, id, directory, fingerprint, entry) do
    case load_definition(state.config, directory) do
      {:ok, definition} ->
        revision = next_revision(state, id, entry, definition)

        snapshot = %Snapshot{
          id: id,
          revision: revision,
          definition: definition,
          fingerprint: fingerprint,
          loaded_at: DateTime.utc_now()
        }

        state = %{
          state
          | entries: Map.put(state.entries, id, snapshot),
            failures: Map.delete(state.failures, id),
            revisions: Map.put(state.revisions, id, revision)
        }

        {state, {:loaded, snapshot}}

      {:error, %Error{} = error} ->
        failure = %Failure{
          id: id,
          error: error,
          fingerprint: fingerprint,
          attempted_at: DateTime.utc_now()
        }

        state = %{state | failures: Map.put(state.failures, id, failure)}
        {state, {:rejected, failure}}
    end
  end

  defp next_revision(state, id, %Snapshot{} = entry, definition) do
    if entry.definition == definition do
      entry.revision
    else
      Map.get(state.revisions, id, entry.revision) + 1
    end
  end

  defp next_revision(state, id, nil, _definition) do
    Map.get(state.revisions, id, 0) + 1
  end

  defp record_invalid(state, id, {directory, error}, shared) do
    fingerprint = :erlang.md5(:erlang.term_to_binary({:invalid, directory, error.errors, shared}))

    state = %{state | entries: Map.delete(state.entries, id)}

    case Map.get(state.failures, id) do
      %Failure{fingerprint: ^fingerprint} = failure ->
        {state, {:rejected, failure}}

      _other ->
        failure = %Failure{
          id: id,
          error: error,
          fingerprint: fingerprint,
          attempted_at: DateTime.utc_now()
        }

        state = %{state | failures: Map.put(state.failures, id, failure)}
        {state, {:rejected, failure}}
    end
  end

  defp load_definition(config, directory) do
    Definition.load(directory, config_root: config.config_dir)
  rescue
    exception ->
      {:error,
       %Error{
         errors: [
           Error.issue(
             [directory],
             "cannot load agent definition: #{Exception.message(exception)}"
           )
         ]
       }}
  end

  defp add_outcome(report, {:loaded, snapshot}) do
    %{report | loaded: report.loaded ++ [snapshot]}
  end

  defp add_outcome(report, {:unchanged, snapshot}) do
    %{report | unchanged: report.unchanged ++ [snapshot]}
  end

  defp add_outcome(report, {:rejected, failure}) do
    %{report | rejected: report.rejected ++ [failure]}
  end

  defp remove(state, id) do
    %{
      state
      | entries: Map.delete(state.entries, id),
        failures: Map.delete(state.failures, id)
    }
  end

  defp clear_failure(state, id) do
    %{state | failures: Map.delete(state.failures, id)}
  end

  defp sorted_snapshots(state) do
    state.entries
    |> Map.values()
    |> Enum.sort_by(& &1.id)
  end

  defp sorted_failures(state) do
    state.failures
    |> Map.values()
    |> Enum.sort_by(& &1.id)
  end

  defp agent_directories(%Config{} = config) do
    directory = Path.join(config.config_dir, "agents")

    case File.ls(directory) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.reduce(%{}, fn entry, directories ->
          path = Path.join(directory, entry)

          if agent_directory?(path) do
            Map.put(directories, entry, path)
          else
            directories
          end
        end)

      {:error, _reason} ->
        %{}
    end
  end

  defp agent_directory?(path) do
    with {:ok, %File.Stat{type: :directory}} <- File.lstat(path),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(Path.join(path, "agent.toml")) do
      true
    else
      _other -> false
    end
  end

  defp invalid_agent_directories(%Config{} = config) do
    directory = Path.join(config.config_dir, "agents")

    case File.ls(directory) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.reduce(%{}, fn entry, invalid ->
          path = Path.join(directory, entry)

          case invalid_agent_directory(path) do
            nil -> invalid
            error -> Map.put(invalid, entry, {path, error})
          end
        end)

      {:error, _reason} ->
        %{}
    end
  end

  defp invalid_agent_directory(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        invalid_agent_source(path)

      _other ->
        nil
    end
  end

  defp invalid_agent_source(directory) do
    source = Path.join(directory, "agent.toml")

    case File.lstat(source) do
      {:ok, %File.Stat{type: :regular}} ->
        nil

      {:ok, %File.Stat{type: :symlink}} ->
        nil

      {:ok, %File.Stat{}} ->
        %Error{errors: [Error.issue([source], "agent.toml must be a regular file")]}

      {:error, :enoent} ->
        %Error{errors: [Error.issue([source], "agent.toml is missing")]}

      {:error, _reason} ->
        nil
    end
  end

  defp shared_fingerprint(config_dir) do
    paths =
      files_under(Path.join([config_dir, "shared", "prompts"])) ++
        files_under(Path.join(config_dir, "scripts")) ++
        files_under(Path.join(config_dir, "toolkits"))

    digest_files(config_dir, paths)
  end

  defp agent_fingerprint(directory, shared) do
    own = digest_files(directory, files_under(directory))
    :erlang.md5(:erlang.term_to_binary({own, shared}))
  end

  defp digest_files(root, paths) do
    entries =
      Enum.map(paths, fn path ->
        content =
          case File.read(path) do
            {:ok, content} -> :erlang.md5(content)
            {:error, _reason} -> :unreadable
          end

        {Path.relative_to(path, root), content}
      end)

    :erlang.md5(:erlang.term_to_binary(entries))
  end

  defp files_under(root) do
    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.flat_map(fn entry -> collect_file(entry, root) end)

      {:error, _reason} ->
        []
    end
  end

  defp collect_file(entry, root) do
    path = Path.join(root, entry)

    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} -> [path]
      {:ok, %File.Stat{type: :directory}} -> files_under(path)
      _other -> []
    end
  end
end
