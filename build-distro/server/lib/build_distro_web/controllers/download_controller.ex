defmodule BuildDistroWeb.DownloadController do
  use BuildDistroWeb, :controller

  alias BuildDistro.{Builds, Storage}
  alias BuildDistroWeb.Viewer

  def show(conn, %{"number" => number, "kind" => kind}) do
    with true <- Viewer.downloads?(conn.assigns.viewer),
         %{state: "ready"} = build <- fetch(conn, number),
         %{} = artifact <- Builds.artifact(build, kind) do
      redirect(conn,
        external: Storage.presigned_download_url(artifact.object_key, 600, artifact.filename)
      )
    else
      _ -> send_resp(conn, 404, "Not found")
    end
  end

  # Icons never change for a build, so browsers may keep them.
  def icon(conn, %{"number" => number}) do
    with %{icon_key: key} when is_binary(key) <- fetch(conn, number),
         {:ok, png} <- Storage.read(key) do
      conn
      |> put_resp_content_type("image/png")
      |> put_resp_header("cache-control", "private, max-age=31536000, immutable")
      |> send_resp(200, png)
    else
      _ -> send_resp(conn, 404, "")
    end
  end

  # Public links only reach builds of their own bucket.
  defp fetch(conn, number) do
    with {number, ""} <- Integer.parse(number),
         %{} = build <- Builds.get_build(conn.assigns.project, number),
         true <- Viewer.can_see?(conn.assigns.viewer, build) do
      build
    else
      _ -> nil
    end
  end
end
