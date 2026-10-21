defmodule BuildDistroWeb.AccessTest do
  use BuildDistroWeb.ConnCase

  alias BuildDistro.Projects

  setup do
    %{project: project} = project_fixture()
    {:ok, invite, token} = Projects.create_invite(project, %{"label" => "Anna"})
    %{project: project, invite: invite, token: token}
  end

  test "pages need an invite", %{conn: conn, project: project} do
    assert conn |> get(~p"/#{project.slug}/latest") |> response(404)
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/#{project.slug}")
  end

  test "an invite plus the passcode opens the project", %{
    conn: conn,
    project: project,
    token: token
  } do
    assert conn |> get(~p"/#{project.slug}/join/#{token}") |> html_response(200) =~ "passcode"

    conn = post(conn, ~p"/#{project.slug}/join/#{token}", %{"passcode" => "secret-passcode"})
    assert redirected_to(conn) == ~p"/#{project.slug}"

    assert {:ok, _view, html} = conn |> recycle() |> live(~p"/#{project.slug}")
    assert html =~ "No main builds yet"
  end

  test "a wrong passcode doesn't", %{conn: conn, project: project, token: token} do
    conn = post(conn, ~p"/#{project.slug}/join/#{token}", %{"passcode" => "wrong"})
    assert html_response(conn, 401) =~ "isn&#39;t right"
  end

  test "guessing is rate limited", %{conn: conn, project: project, token: token} do
    for _ <- 1..10, do: post(conn, ~p"/#{project.slug}/join/#{token}", %{"passcode" => "wrong"})

    conn = post(conn, ~p"/#{project.slug}/join/#{token}", %{"passcode" => "secret-passcode"})
    assert html_response(conn, 429) =~ "Too many attempts"
  end

  test "revoking an invite ends access at once", %{
    conn: conn,
    project: project,
    invite: invite,
    token: token
  } do
    conn =
      conn
      |> post(~p"/#{project.slug}/join/#{token}", %{"passcode" => "secret-passcode"})
      |> recycle()

    assert {:ok, _, _} = live(conn, ~p"/#{project.slug}")

    :ok = Projects.revoke_invite(project, invite.id)

    assert {:error, {:redirect, _}} = live(conn, ~p"/#{project.slug}")

    assert build_conn() |> get(~p"/#{project.slug}/join/#{token}") |> html_response(404) =~
             "doesn"
  end

  test "an invite only opens its own project", %{conn: conn, project: project, token: token} do
    %{project: other} = project_fixture()

    conn =
      conn
      |> post(~p"/#{project.slug}/join/#{token}", %{"passcode" => "secret-passcode"})
      |> recycle()

    assert {:error, {:redirect, _}} = live(conn, ~p"/#{other.slug}")
    assert conn |> get(~p"/#{other.slug}/join/#{token}") |> html_response(404)
  end

  test "admins see every project", %{conn: conn, project: project} do
    conn = sign_in_admin(conn)

    assert {:ok, _, html} = live(conn, ~p"/admin")
    assert html =~ project.name
    assert {:ok, _, _} = live(conn, ~p"/#{project.slug}")
  end
end
