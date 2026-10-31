defmodule PatchbayWeb.AuthTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn

  alias PatchbayWeb.Auth
  alias PatchbayWeb.AuthTestHelper

  @endpoint PatchbayWeb.Endpoint

  test "unauthenticated HTTP routes are challenged without exposing the UI" do
    for path <- [
          "/",
          "/console",
          "/config",
          "/config/researcher",
          "/toolkits",
          "/toolkits/filesystem"
        ] do
      conn = get(build_conn(), path)

      assert conn.status == 401
      assert get_resp_header(conn, "www-authenticate") == [~s(Basic realm="Patchbay")]
      refute conn.resp_body =~ "PATCHBAY"
    end
  end

  test "valid Basic credentials authenticate and record the session marker" do
    conn = get(AuthTestHelper.authenticated_conn(), "/")

    assert conn.status == 200
    assert get_session(conn, "patchbay_ui_authenticated") == true
  end

  test "the session marker authenticates later HTTP requests" do
    conn = get(AuthTestHelper.authenticated_conn(), "/")
    conn = conn |> recycle() |> delete_req_header("authorization")

    assert get(conn, "/config").status == 200
  end

  test "an incorrect token is rejected" do
    conn =
      build_conn()
      |> put_req_header("authorization", AuthTestHelper.basic_header("wrong-token"))

    assert get(conn, "/").status == 401
  end

  test "malformed credentials are rejected" do
    for header <- [
          "Basic",
          "Basic !!!",
          "Bearer test-ui-token",
          "Basic " <> Base.encode64("nope")
        ] do
      conn = build_conn() |> put_req_header("authorization", header)
      assert get(conn, "/").status == 401
    end
  end

  test "static assets remain public" do
    assert get(build_conn(), "/assets/app.css").status == 200
  end

  test "an authenticated LiveView connects" do
    {:ok, _view, html} = live(AuthTestHelper.authenticated_conn(), "/")

    assert html =~ "PATCHBAY"
    assert html =~ "CONSOLE"
  end

  test "LiveView mount rejects absent, forged, or false session markers" do
    socket = %Phoenix.LiveView.Socket{}

    for session <- [
          %{},
          %{"patchbay_ui_authenticated" => "true"},
          %{"patchbay_ui_authenticated" => false}
        ] do
      assert {:halt, halted} = Auth.on_mount(:default, %{}, session, socket)
      assert {:redirect, %{to: "/"}} = halted.redirected
    end
  end

  test "LiveView mount accepts the authenticated session marker" do
    socket = %Phoenix.LiveView.Socket{}

    assert {:cont, mounted} =
             Auth.on_mount(:default, %{}, %{"patchbay_ui_authenticated" => true}, socket)

    assert mounted.assigns.ui_authenticated
  end
end
