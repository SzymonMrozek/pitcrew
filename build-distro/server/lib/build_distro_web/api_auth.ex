defmodule BuildDistroWeb.ApiAuth do
  @moduledoc "Authenticates CI with a project API key: `Authorization: Bearer bd_...`."

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, project} <- BuildDistro.Projects.project_for_api_key(String.trim(token)) do
      assign(conn, :project, project)
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, ~s({"error":"invalid API key"}))
        |> halt()
    end
  end
end
