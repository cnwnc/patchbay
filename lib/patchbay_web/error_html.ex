defmodule PatchbayWeb.ErrorHTML do
  @moduledoc false

  def render("404.html", _assigns), do: "Not Found"
  def render("500.html", _assigns), do: "Internal Server Error"
  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)
end
