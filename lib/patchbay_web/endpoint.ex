defmodule PatchbayWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :patchbay

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: {__MODULE__, :session_options, []}]],
    longpoll: [connect_info: [session: {__MODULE__, :session_options, []}]]
  )

  plug(PatchbayWeb.Assets)

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(:put_session)
  plug(PatchbayWeb.Router)

  @doc """
  Returns the runtime session options, including the signing salt.
  """
  @spec session_options() :: keyword()
  def session_options do
    config(:session) ||
      raise ArgumentError, "PatchbayWeb.Endpoint session options are not configured"
  end

  defp put_session(conn, _opts) do
    Plug.Session.call(conn, Plug.Session.init(session_options()))
  end
end
