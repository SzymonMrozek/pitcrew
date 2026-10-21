defmodule BuildDistroWeb.AdminTest do
  use BuildDistroWeb.ConnCase

  setup %{conn: conn} do
    %{conn: sign_in_admin(conn)}
  end

  test "admin pages need a signed-in admin" do
    assert {:error, {:redirect, %{to: "/admin/login"}}} = live(build_conn(), ~p"/admin")
  end

  test "public links show once and can be revoked", %{conn: conn} do
    %{project: project} = project_fixture()
    {:ok, view, _} = live(conn, ~p"/admin/projects/#{project.slug}")

    html = view |> element("button", "New Main link") |> render_click()
    assert [_, path] = Regex.run(~r{http://[^/]+(/#{project.slug}/p/pub_[\w-]+)}, html)
    assert {:ok, _, _} = live(build_conn(), path)

    [link] = BuildDistro.Projects.list_public_links(project)
    view |> element("button[phx-value-id='#{link.id}']", "Revoke") |> render_click()
    assert {:error, {:redirect, %{to: "/"}}} = live(build_conn(), path)
  end

  test "settings hold the main branch and tooling rules", %{conn: conn} do
    %{project: project} = project_fixture()
    {:ok, view, _} = live(conn, ~p"/admin/projects/#{project.slug}")

    view
    |> form("#settings-form",
      settings: %{main_branch: "trunk", tooling_types: "chore, ci", tooling_scopes: "infra"}
    )
    |> render_submit()

    project = BuildDistro.Projects.get_project!(project.id)

    assert {project.main_branch, project.tooling_types, project.tooling_scopes} ==
             {"trunk", "chore, ci", "infra"}
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
