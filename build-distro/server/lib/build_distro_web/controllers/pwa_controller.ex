defmodule BuildDistroWeb.PwaController do
  use BuildDistroWeb, :controller

  alias BuildDistroWeb.Viewer

  def manifest(conn, params) do
    viewer = conn.assigns[:viewer]
    buckets = if viewer, do: viewer.buckets, else: ["main"]
    bucket = if params["bucket"] in buckets, do: params["bucket"], else: hd(buckets)
    start_url = if viewer, do: Viewer.bucket_path(viewer, bucket), else: "/"

    manifest = %{
      id: start_url,
      name: if(viewer, do: viewer.project.name <> " · builds", else: "build-distro"),
      short_name: if(viewer, do: viewer.project.name, else: "build-distro"),
      start_url: start_url,
      scope: "/",
      display: "standalone",
      background_color: "#171717",
      theme_color: "#FFB224",
      icons: [
        %{src: "/images/pwa-192.png", sizes: "192x192", type: "image/png"},
        %{src: "/images/pwa-512.png", sizes: "512x512", type: "image/png"}
      ]
    }

    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_content_type("application/manifest+json")
    |> send_resp(200, Jason.encode!(manifest))
  end
end
