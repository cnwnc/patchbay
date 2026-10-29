defmodule PatchbayWeb.AssetsTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest

  @endpoint PatchbayWeb.Endpoint

  test "serves the embedded stylesheet" do
    conn = get(build_conn(), "/assets/app.css")

    assert conn.status == 200
    assert conn.resp_body =~ "--paper"
    assert Plug.Conn.get_resp_header(conn, "content-type") |> hd() =~ "text/css"
  end

  test "serves the embedded Phoenix and LiveView JavaScript" do
    for {path, marker} <- [
          {"/assets/phoenix.js", "var Phoenix"},
          {"/assets/phoenix_live_view.js", "var LiveView"}
        ] do
      conn = get(build_conn(), path)

      assert conn.status == 200
      assert conn.resp_body =~ marker
      assert Plug.Conn.get_resp_header(conn, "content-type") |> hd() =~ "javascript"
    end
  end

  test "does not serve unknown assets" do
    conn = get(build_conn(), "/assets/missing.css")

    assert conn.status == 404
  end
end
