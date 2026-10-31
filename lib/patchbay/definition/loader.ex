defmodule Patchbay.Definition.Loader do
  @moduledoc false

  alias Patchbay.Definition.Agent
  alias Patchbay.Definition.Error
  alias Patchbay.Definition.Parse
  alias Patchbay.Definition.Prompt
  alias Patchbay.Toolkit.Manifest
  alias Patchbay.Toolkit.Native.Filesystem
  alias Patchbay.Toolkit.Native.PersonalMemory
  alias Patchbay.Toolkit.Native.SecretEnv

  @type option ::
          {:config_root, Path.t()}
          | {:path, Path.t()}
          | {:agent_dir, Path.t()}
          | {:toolkit_dirs, [Path.t()]}

  @spec load(Path.t(), [option()]) :: {:ok, Agent.t()} | {:error, Error.t()}
  def load(agent_dir, opts \\ []) do
    agent_dir = Path.expand(agent_dir)
    path = opts |> Keyword.get(:path, Path.join(agent_dir, "agent.toml")) |> Path.expand()
    config_root = config_root(opts, agent_dir)

    with {:ok, body} <- read(path),
         {:ok, raw} <- decode(body, path) do
      {agent, errors} = Agent.from_map(raw, [])

      case agent do
        nil ->
          finish(nil, errors)

        %Agent{} = agent ->
          {assets, errors} = read_assets(agent_dir, config_root, errors)
          {toolkits, errors} = resolve_toolkits(agent.toolkits, config_root, opts, errors)
          errors = validate_directory(agent, agent_dir, errors)

          agent = %{
            agent
            | path: path,
              agent_dir: agent_dir,
              config_root: config_root,
              toolkits: toolkits,
              prompts: assets.prompts,
              shared_scripts: assets.shared_scripts,
              agent_scripts: assets.agent_scripts
          }

          finish(agent, errors)
      end
    else
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  @spec load!(Path.t(), [option()]) :: Agent.t()
  def load!(agent_dir, opts \\ []) do
    case load(agent_dir, opts) do
      {:ok, agent} -> agent
      {:error, error} -> raise error
    end
  end

  @spec parse(String.t(), [option()]) :: {:ok, Agent.t()} | {:error, Error.t()}
  def parse(body, opts \\ []) do
    with {:ok, raw} <- decode(body, Keyword.get(opts, :path)) do
      {agent, errors} = Agent.from_map(raw, [])

      case agent do
        nil ->
          finish(nil, errors)

        %Agent{} = agent ->
          {toolkits, errors} = parse_toolkits(agent.toolkits, opts, errors)

          agent = %{
            agent
            | path: Keyword.get(opts, :path),
              agent_dir: Keyword.get(opts, :agent_dir),
              config_root: Keyword.get(opts, :config_root),
              toolkits: toolkits
          }

          finish(agent, errors)
      end
    else
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp finish(nil, errors) do
    {:error, %Error{errors: Enum.reverse(errors)}}
  end

  defp finish(%Agent{} = agent, errors) do
    case Enum.reverse(errors) do
      [] -> {:ok, agent}
      errors -> {:error, %Error{errors: errors}}
    end
  end

  defp config_root(opts, agent_dir) do
    case Keyword.fetch(opts, :config_root) do
      {:ok, nil} -> nil
      {:ok, root} -> Path.expand(root)
      :error -> infer_config_root(agent_dir)
    end
  end

  defp infer_config_root(agent_dir) do
    agents_dir = Path.dirname(agent_dir)

    if Path.basename(agents_dir) == "agents" do
      Path.dirname(agents_dir)
    end
  end

  defp parse_toolkits(toolkits, opts, errors) do
    if Keyword.has_key?(opts, :toolkit_dirs) do
      resolve_toolkits(toolkits, Keyword.get(opts, :config_root), opts, errors)
    else
      {toolkits, errors}
    end
  end

  defp resolve_toolkits(toolkits, config_root, opts, errors) do
    manifest_opts =
      [config_root: config_root]
      |> maybe_put_toolkit_dirs(Keyword.get(opts, :toolkit_dirs))

    toolkits
    |> Enum.with_index()
    |> Enum.map_reduce(errors, fn {toolkit, index}, errors ->
      resolve_toolkit(toolkit, index, config_root, manifest_opts, errors)
    end)
  end

  defp resolve_toolkit(%{toolkit: name} = toolkit, _index, _config_root, _opts, errors)
       when is_nil(name),
       do: {toolkit, errors}

  defp resolve_toolkit(%{toolkit: name} = toolkit, index, config_root, opts, errors)
       when is_binary(name) do
    case Manifest.load(name, opts) do
      {:ok, manifest} ->
        toolkit = Manifest.merge(toolkit, manifest)
        errors = validate_native_config(toolkit, index, config_root, errors)
        {toolkit, errors}

      {:error, %Error{errors: issues}} ->
        {toolkit, issues ++ errors}

      :error ->
        errors =
          Parse.error(
            errors,
            ["toolkits", index, "toolkit"],
            "unknown toolkit #{inspect(name)}"
          )

        {toolkit, errors}
    end
  end

  defp resolve_toolkit(toolkit, _index, _config_root, _opts, errors), do: {toolkit, errors}

  defp validate_native_config(%{native: "filesystem"} = toolkit, index, config_root, errors) do
    case Filesystem.validate_config(Map.get(toolkit, :config, %{}), config_root) do
      :ok ->
        errors

      {:error, message} ->
        Parse.error(errors, ["toolkits", index, "config", "root"], message)
    end
  end

  defp validate_native_config(%{native: "personal-memory"} = toolkit, index, config_root, errors) do
    case PersonalMemory.validate_config(Map.get(toolkit, :config, %{}), config_root) do
      :ok ->
        errors

      {:error, message} ->
        Parse.error(errors, ["toolkits", index, "config", "namespace"], message)
    end
  end

  defp validate_native_config(%{native: "secret-env"} = toolkit, index, _config_root, errors) do
    case SecretEnv.validate_config(Map.get(toolkit, :config, %{})) do
      :ok ->
        errors

      {:error, path, message} ->
        Parse.error(errors, ["toolkits", index, "config"] ++ path, message)
    end
  end

  defp validate_native_config(_toolkit, _index, _config_root, errors), do: errors

  defp maybe_put_toolkit_dirs(opts, nil), do: opts
  defp maybe_put_toolkit_dirs(opts, dirs), do: Keyword.put(opts, :toolkit_dirs, dirs)

  defp read(path) do
    case File.read(path) do
      {:ok, body} ->
        {:ok, body}

      {:error, reason} ->
        {:error,
         %Error{
           errors: [
             Error.issue(
               [path],
               "cannot read agent definition: #{:file.format_error(reason)}"
             )
           ]
         }}
    end
  end

  defp decode(body, path) do
    case TomlElixir.decode(body) do
      {:ok, raw} when is_map(raw) ->
        {:ok, raw}

      {:ok, _other} ->
        {:error, %Error{errors: [Error.issue(location(path), "must be a table")]}}

      {:error, exception} ->
        {:error,
         %Error{
           errors: [
             Error.issue(
               location(path),
               "invalid TOML: #{Exception.message(exception)}"
             )
           ]
         }}
    end
  rescue
    exception ->
      {:error,
       %Error{
         errors: [
           Error.issue(location(path), "invalid TOML: #{Exception.message(exception)}")
         ]
       }}
  end

  defp location(nil), do: []
  defp location(path), do: [path]

  defp read_assets(agent_dir, config_root, errors) do
    {shared_prompts, errors} =
      read_prompts(shared_prompts_path(config_root), :shared, errors)

    {agent_prompts, errors} = read_prompts(Path.join(agent_dir, "prompts"), :agent, errors)

    {shared_scripts, errors} = read_scripts(shared_scripts_path(config_root), errors)
    {agent_scripts, errors} = read_scripts(Path.join(agent_dir, "scripts"), errors)

    {%{
       prompts: shared_prompts ++ agent_prompts,
       shared_scripts: shared_scripts,
       agent_scripts: agent_scripts
     }, errors}
  end

  defp shared_prompts_path(nil), do: nil

  defp shared_prompts_path(config_root) do
    Path.join([config_root, "shared", "prompts"])
  end

  defp shared_scripts_path(nil), do: nil
  defp shared_scripts_path(config_root), do: Path.join(config_root, "scripts")

  defp read_prompts(nil, _source, errors), do: {[], errors}

  defp read_prompts(directory, source, errors) do
    case regular_files(directory) do
      {:ok, paths} ->
        paths
        |> Enum.filter(&prompt_file?/1)
        |> Enum.reduce({[], errors}, fn path, {prompts, errors} ->
          case Prompt.from_file(path, source) do
            {:ok, prompt} ->
              {[prompt | prompts], errors}

            {:error, reason} ->
              {prompts,
               Parse.error(
                 errors,
                 [path],
                 "cannot read prompt: #{:file.format_error(reason)}"
               )}
          end
        end)
        |> reverse_preserving_errors()

      {:error, issue} ->
        {[], [issue | errors]}
    end
  end

  defp read_scripts(nil, errors), do: {[], errors}

  defp read_scripts(directory, errors) do
    case regular_files(directory) do
      {:ok, paths} -> {paths, errors}
      {:error, issue} -> {[], [issue | errors]}
    end
  end

  defp regular_files(directory) do
    case File.ls(directory) do
      {:ok, entries} ->
        paths =
          entries
          |> Enum.sort()
          |> Enum.map(&Path.join(directory, &1))
          |> Enum.filter(&File.regular?/1)

        {:ok, paths}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error,
         Error.issue(
           [directory],
           "cannot list directory: #{:file.format_error(reason)}"
         )}
    end
  end

  defp prompt_file?(path), do: Path.extname(path) in [".md", ".markdown"]

  defp reverse_preserving_errors({items, errors}), do: {Enum.reverse(items), errors}

  defp validate_directory(%Agent{id: id}, agent_dir, errors) when is_binary(id) do
    directory_name = Path.basename(agent_dir)

    if directory_name == id do
      errors
    else
      Parse.error(
        errors,
        ["id"],
        "must match the agent directory name #{inspect(directory_name)}"
      )
    end
  end

  defp validate_directory(_agent, _agent_dir, errors), do: errors
end
