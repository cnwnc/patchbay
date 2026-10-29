defmodule PatchbayWeb.Auth do
  @moduledoc """
  Authentication for the Console and Configuration UI.

  Every UI route requires HTTP Basic credentials whose password is the
  operator-supplied `PATCHBAY_UI_TOKEN`. The username is ignored. Credentials
  are compared in constant time and are never written to the session, URLs, or
  logs. A successful request records a boolean marker in the signed session,
  and the LiveView `on_mount/4` hook requires that marker so a direct websocket
  connection cannot bypass the HTTP check.

  Static assets are served before this plug and remain public.
  """

  @behaviour Plug

  import Plug.Conn

  alias Plug.Crypto

  @session_key "patchbay_ui_authenticated"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if authenticated?(conn) do
      conn
      |> put_session(@session_key, true)
      |> assign(:ui_authenticated, true)
    else
      conn
      |> put_resp_header("www-authenticate", ~s(Basic realm="Patchbay"))
      |> send_resp(401, "Authentication required\n")
      |> halt()
    end
  end

  @doc """
  LiveView hook that admits only sockets carrying the authenticated session
  marker.

  Unauthenticated sockets are redirected to the root path, where the HTTP
  Basic plug issues the challenge.
  """
  def on_mount(:default, _params, session, socket) do
    if session[@session_key] == true do
      {:cont, Phoenix.Component.assign(socket, :ui_authenticated, true)}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: "/")}
    end
  end

  @doc """
  Returns the configured UI token, or `nil` when the UI is closed.

  The `:ui_token` application setting takes precedence; otherwise
  `PATCHBAY_UI_TOKEN` is read from the process environment.
  """
  @spec token() :: String.t() | nil
  def token do
    case Application.get_env(:patchbay, :ui_token) do
      value when is_binary(value) and value != "" ->
        value

      _other ->
        case System.get_env("PATCHBAY_UI_TOKEN") do
          value when is_binary(value) and value != "" -> value
          _missing -> nil
        end
    end
  end

  defp authenticated?(conn) do
    valid_basic?(conn) or get_session(conn, @session_key) == true
  end

  defp valid_basic?(conn) do
    with [header] <- get_req_header(conn, "authorization"),
         {:ok, decoded} <- decode_basic(header),
         {:ok, _username, password} <- split_credentials(decoded),
         token when is_binary(token) <- token() do
      Crypto.secure_compare(digest(password), digest(token))
    else
      _other -> false
    end
  end

  defp digest(value), do: :crypto.hash(:sha256, value)

  defp decode_basic("Basic " <> encoded) when encoded != "" do
    case Base.decode64(encoded, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> Base.decode64(encoded)
    end
  end

  defp decode_basic(_header), do: :error

  defp split_credentials(decoded) do
    case :binary.split(decoded, ":") do
      [username, password] -> {:ok, username, password}
      _other -> :error
    end
  end
end
