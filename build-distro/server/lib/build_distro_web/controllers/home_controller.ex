defmodule BuildDistroWeb.HomeController do
  use BuildDistroWeb, :controller

  def index(conn, _params) do
    if BuildDistroWeb.Access.admin?(get_session(conn)),
      do: redirect(conn, to: ~p"/admin"),
      else: render(conn, :index)
  end
end
