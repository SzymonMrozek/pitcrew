defmodule BuildDistroWeb.HealthController do
  use BuildDistroWeb, :controller

  # Checks the database only. A bucket outage shouldn't restart the server.
  def show(conn, _params) do
    case Ecto.Adapters.SQL.query(BuildDistro.Repo, "SELECT 1", []) do
      {:ok, _} -> send_resp(conn, 200, "ok")
      {:error, _} -> send_resp(conn, 503, "database unavailable")
    end
  end
end
