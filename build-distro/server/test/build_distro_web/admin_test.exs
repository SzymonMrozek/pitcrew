defmodule BuildDistroWeb.AdminTest do
  use BuildDistroWeb.ConnCase

  setup %{conn: conn} do
    %{conn: conn |> post(~p"/admin/login", %{"password" => "admin"}) |> recycle()}
  end

  test "the admin password is required" do
    assert {:error, {:redirect, %{to: "/admin/login"}}} = live(build_conn(), ~p"/admin")
    assert build_conn() |> post(~p"/admin/login", %{"password" => "nope"}) |> html_response(401)
  end

  test "creating a project shows its API key once", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/admin")

    html =
      view
      |> form("form", project: %{name: "Demo", slug: "demo", passcode: "longenough"})
      |> render_submit()

    assert [_, key] = Regex.run(~r/(bd_demo_[\w-]+)/, html)
    assert {:ok, %{slug: "demo"}} = BuildDistro.Projects.project_for_api_key(key)
    assert html =~ "BUILD_DISTRO_API_KEY"
  end

  test "reserved slugs are refused", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/admin")

    html =
      view
      |> form("form", project: %{name: "X", slug: "admin", passcode: "longenough"})
      |> render_submit()

    assert html =~ "is reserved"
  end

  test "invites are created, shown once and revoked", %{conn: conn} do
    %{project: project} = project_fixture()
    {:ok, view, _} = live(conn, ~p"/admin/projects/#{project.slug}")

    html =
      view |> form("form[phx-submit=create_invite]", invite: %{label: "Anna"}) |> render_submit()

    assert [_, url] = Regex.run(~r{(http://[^<"]+/join/inv_[\w-]+)}, html)

    path = URI.parse(url).path
    assert build_conn() |> get(path) |> html_response(200)

    [invite] = BuildDistro.Projects.list_invites(project)
    view |> element("button[phx-value-id='#{invite.id}']") |> render_click()
    assert build_conn() |> get(path) |> html_response(404)
  end
end
