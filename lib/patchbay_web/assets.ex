defmodule PatchbayWeb.Assets do
  @moduledoc """
  Serves the console's static assets from data embedded at compile time.

  Escripts do not carry application `priv` directories, and dependency
  `priv/static` paths do not exist at runtime. Reading the stylesheet and the
  prebuilt Phoenix/LiveView JavaScript during compilation keeps the packaged
  escript self-contained without writing to disk or reaching a CDN.
  """

  import Plug.Conn

  @app_css_path Path.expand("../../priv/static/assets/app.css", __DIR__)
  @phoenix_js_path Path.join(:code.priv_dir(:phoenix), "static/phoenix.js")
  @live_view_js_path Path.join(:code.priv_dir(:phoenix_live_view), "static/phoenix_live_view.js")

  @external_resource @app_css_path
  @external_resource @phoenix_js_path
  @external_resource @live_view_js_path

  @assets %{
    "app.css" => {File.read!(@app_css_path), "text/css"},
    "phoenix.js" => {File.read!(@phoenix_js_path), "text/javascript"},
    "phoenix_live_view.js" => {File.read!(@live_view_js_path), "text/javascript"}
  }

  def init(opts), do: opts

  def call(%Plug.Conn{method: method, path_info: ["assets", name]} = conn, _opts)
      when method in ["GET", "HEAD"] do
    case Map.fetch(@assets, name) do
      {:ok, {body, content_type}} ->
        conn
        |> put_resp_content_type(content_type)
        |> put_resp_header("cache-control", "public, max-age=86400")
        |> send_resp(200, if(method == "HEAD", do: "", else: body))
        |> halt()

      :error ->
        conn
    end
  end

  def call(conn, _opts), do: conn
end
