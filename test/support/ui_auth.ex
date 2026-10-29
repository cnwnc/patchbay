defmodule PatchbayWeb.AuthTestHelper do
  @moduledoc false

  import Phoenix.ConnTest

  @spec authenticated_conn(String.t()) :: Plug.Conn.t()
  def authenticated_conn(token \\ PatchbayWeb.Auth.token()) do
    build_conn()
    |> Plug.Conn.put_req_header("authorization", basic_header(token))
  end

  @spec basic_header(String.t()) :: String.t()
  def basic_header(token), do: "Basic " <> Base.encode64("patchbay:" <> token)
end
