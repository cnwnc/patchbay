defmodule PatchbayWeb.ArtifactsController do
  @moduledoc """
  Serves published artifacts over the management endpoint.

  The route sits behind the same UI authentication as the Console and
  Configuration routes, so `curl -u patchbay:"$PATCHBAY_UI_TOKEN"` downloads
  an agent's published files. Only the manager-owned copies under
  `<state_dir>/artifacts/<agent-id>/` are served, never workspace bytes, and
  the content type and disposition come from the extension allowlist in
  `Patchbay.ArtifactStore`.
  """

  import Plug.Conn

  alias Patchbay.Runtime

  @runtime_unavailable_body "Runtime unavailable\n"
  @not_found_body "Not found\n"

  # Artifact bytes are agent-controlled. `nosniff` keeps a browser from
  # promoting them to another type, and the sandboxed CSP gives a directly
  # opened document an opaque origin with scripts and subresources disabled.
  # Inline types stay downloadable from curl; the headers apply to every
  # response from this route, including misses.
  @security_headers [
    {"x-content-type-options", "nosniff"},
    {"content-security-policy", "default-src 'none'; sandbox; frame-ancestors 'none'"},
    {"x-frame-options", "DENY"},
    {"referrer-policy", "no-referrer"},
    {"cross-origin-resource-policy", "same-origin"}
  ]

  @doc false
  def init(opts), do: opts

  # Router plugs call the module directly; Phoenix controllers normally come
  # with this from `use Phoenix.Controller`, which this project does not use.
  def call(conn, opts) do
    conn = put_security_headers(conn)

    case opts do
      :show -> show(conn, conn.params)
      _other -> conn
    end
  end

  defp put_security_headers(conn) do
    Enum.reduce(@security_headers, conn, fn {name, value}, conn ->
      put_resp_header(conn, name, value)
    end)
  end

  def show(conn, %{"agent_id" => agent_id, "filename" => filename}) do
    case runtime_server() do
      nil ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(503, @runtime_unavailable_body)

      runtime ->
        serve(conn, runtime, agent_id, filename)
    end
  end

  defp serve(conn, runtime, agent_id, filename) do
    case Runtime.artifact(runtime, agent_id, filename) do
      {:ok, artifact} ->
        conn
        |> put_artifact_content_type(artifact.content_type)
        |> put_resp_header("content-disposition", disposition(artifact))
        |> send_file(200, artifact.path, 0, artifact.size)

      {:error, _reason} ->
        send_resp(conn, 404, @not_found_body)
    end
  end

  defp put_artifact_content_type(conn, "text/" <> _rest = type),
    do: put_resp_content_type(conn, type)

  defp put_artifact_content_type(conn, "application/json" = type),
    do: put_resp_content_type(conn, type)

  defp put_artifact_content_type(conn, type), do: put_resp_content_type(conn, type, nil)

  defp disposition(%{disposition: :inline}) do
    "inline"
  end

  defp disposition(%{name: name}) do
    "attachment; filename=\"#{name}\""
  end

  defp runtime_server do
    Process.whereis(Runtime)
  end
end
