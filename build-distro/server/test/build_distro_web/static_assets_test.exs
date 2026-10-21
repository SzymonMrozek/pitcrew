defmodule BuildDistroWeb.StaticAssetsTest do
  use BuildDistroWeb.ConnCase

  # In production, `phx.digest` fingerprints every file (favicon-85f3….svg).
  # Plug.Static only matches the first path segment against `static_paths`,
  # so a fingerprinted file is found inside a listed directory but never at
  # the root. Pages must reference assets in directories.
  test "pages reference static files only inside static directories", %{conn: conn} do
    html = conn |> get(~p"/admin/login") |> html_response(200)

    paths =
      ~r/(?:href|src)="(\/[^"?#]+\.(?:svg|png|ico|css|js))/
      |> Regex.scan(html, capture: :all_but_first)
      |> List.flatten()

    assert paths != []

    for path <- paths do
      [first | rest] = path |> String.trim_leading("/") |> String.split("/")

      assert rest != [] and first in BuildDistroWeb.static_paths(),
             "#{path} must live in a static directory"

      assert conn |> recycle() |> get(path) |> response(200)
    end
  end

  test "browsers' conventional icon paths are served", %{conn: conn} do
    assert conn |> get("/favicon.ico") |> response(200)
    assert conn |> recycle() |> get("/apple-touch-icon.png") |> response(200)
  end

  test "tabs are titled with the product first", %{conn: conn} do
    assert conn |> get(~p"/admin/login") |> html_response(200) =~
             "build-distro · Admin sign-in</title>"
  end
end
