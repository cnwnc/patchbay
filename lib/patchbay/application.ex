defmodule Patchbay.Application do
  @moduledoc false

  use Application

  alias Patchbay.Boot
  alias Patchbay.CLI.Manager
  alias Patchbay.Config
  alias Patchbay.DefinitionRegistry
  alias Patchbay.Runtime
  alias Patchbay.Worker.Token

  @impl true
  def start(_type, _args) do
    config = Config.load()
    children = children(Boot.role(), config)

    Supervisor.start_link(children, strategy: :one_for_one, name: Patchbay.Supervisor)
  end

  @spec children(Boot.role(), Config.t()) :: [Supervisor.child_spec() | {module(), term()}]
  def children(role, config) do
    case role do
      :app -> web_children() ++ manager_children(config) ++ service_children(config)
      :manager -> web_children() ++ service_children(config)
      :worker -> []
      :worker_supervisor -> []
      :cli -> []
    end
  end

  defp web_children do
    [
      PatchbayWeb.Telemetry,
      {Phoenix.PubSub, name: Patchbay.PubSub},
      PatchbayWeb.Endpoint
    ]
  end

  defp service_children(config) do
    if start_services?() do
      [
        {DefinitionRegistry, name: DefinitionRegistry, config: config},
        {Runtime,
         name: Runtime,
         definitions: {DefinitionRegistry, DefinitionRegistry},
         manager: Manager,
         state_dir: config.state_dir,
         workspace_dir: config.workspace_dir,
         result_dir: config.result_dir,
         provider: Patchbay.Provider.OpenAI},
        {Patchbay.Scheduler, name: Patchbay.Scheduler, state_dir: config.state_dir}
      ]
    else
      []
    end
  end

  defp manager_children(config) do
    if start_services?() do
      [{Manager, manager_options(config)}]
    else
      []
    end
  end

  defp start_services? do
    Application.get_env(:patchbay, :start_services, true)
  end

  defp manager_options(config) do
    settings = Application.get_env(:patchbay, :manager, [])

    [
      name: Manager,
      supervisor_host:
        Keyword.get(settings, :supervisor_host) ||
          System.get_env("PATCHBAY_SUPERVISOR_HOST", "127.0.0.1"),
      supervisor_port:
        Keyword.get(settings, :supervisor_port) ||
          env_integer("PATCHBAY_SUPERVISOR_PORT", 7001),
      control_token: Token.resolve_control_token(settings) || generated_token(),
      transcript_dir: Path.join(config.state_dir, "transcripts"),
      listen_port: Keyword.get(settings, :listen_port, 0)
    ]
  end

  defp env_integer(name, default) do
    case System.get_env(name) do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {integer, ""} -> integer
          _other -> default
        end
    end
  end

  defp generated_token do
    Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
  end
end
