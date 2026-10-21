defmodule BuildDistroWeb.LatestController do
  @moduledoc "A stable link to the newest ready build of a branch: `/:project/latest?branch=main`."

  use BuildDistroWeb, :controller

  alias BuildDistro.Builds

  def show(conn, params) do
    project = conn.assigns.project

    case Builds.latest_ready(project, params["branch"] || "main") do
      nil ->
        conn
        |> put_flash(:error, "No ready build on that branch yet.")
        |> redirect(to: ~p"/#{project.slug}")

      build ->
        redirect(conn, to: ~p"/#{project.slug}/builds/#{build.number}")
    end
  end
end
