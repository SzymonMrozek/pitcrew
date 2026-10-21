defmodule BuildDistroWeb.InstallController do
  use BuildDistroWeb, :controller

  alias BuildDistro.{Builds, Storage}
  alias BuildDistroWeb.InstallLinks

  def manifest(conn, %{"token" => token}) do
    with {:ok, build_id} <- InstallLinks.verify(token),
         %{state: "ready"} = build <- Builds.get_build!(build_id),
         %{} = ipa <- Builds.artifact(build, "ipa") do
      ipa_url = Storage.presigned_download_url(ipa.object_key, InstallLinks.max_age())
      icon_url = if build.icon_key, do: InstallLinks.icon_url(build)

      conn
      |> put_resp_content_type("application/xml")
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(200, manifest_xml(build, ipa_url, icon_url))
    else
      _ -> send_resp(conn, 404, "This install link expired. Reload the build page.")
    end
  end

  def icon(conn, %{"token" => token}) do
    with {:ok, build_id} <- InstallLinks.verify(token),
         %{icon_key: key} when is_binary(key) <- Builds.get_build!(build_id),
         {:ok, png} <- Storage.read(key) do
      conn |> put_resp_content_type("image/png") |> send_resp(200, png)
    else
      _ -> send_resp(conn, 404, "")
    end
  end

  # Presigned URLs contain `&`, which must be escaped in XML, or iOS reports
  # only "Unable to download app".
  defp manifest_xml(build, ipa_url, icon_url) do
    images =
      if icon_url do
        for kind <- ["display-image", "full-size-image"] do
          """
                  <dict>
                    <key>kind</key><string>#{kind}</string>
                    <key>needs-shine</key><false/>
                    <key>url</key><string>#{escape(icon_url)}</string>
                  </dict>
          """
        end
      else
        []
      end

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
      <dict>
        <key>items</key>
        <array>
          <dict>
            <key>assets</key>
            <array>
              <dict>
                <key>kind</key><string>software-package</string>
                <key>url</key><string>#{escape(ipa_url)}</string>
              </dict>
    #{images}
            </array>
            <key>metadata</key>
            <dict>
              <key>bundle-identifier</key><string>#{escape(build.bundle_id || "")}</string>
              <key>bundle-version</key><string>#{escape(build.version || "")}</string>
              <key>kind</key><string>software</string>
              <key>title</key><string>#{escape(build.display_name || "App")}</string>
            </dict>
          </dict>
        </array>
      </dict>
    </plist>
    """
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
