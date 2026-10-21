defmodule BuildDistroWeb.AuthTest do
  use BuildDistroWeb.ConnCase

  setup do
    Application.put_env(:build_distro, :github_oauth_req_options, plug: {Req.Test, __MODULE__})
    on_exit(fn -> Application.delete_env(:build_distro, :github_oauth_req_options) end)
  end

  defp github_returns(profile) do
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/login/oauth/access_token" -> Req.Test.json(conn, %{access_token: "gho_temporary"})
        "/user" -> Req.Test.json(conn, profile)
      end
    end)
  end

  defp start_sign_in(conn) do
    conn = get(conn, ~p"/auth/github")
    location = redirected_to(conn)
    assert location =~ "https://github.com/login/oauth/authorize?"
    %{"state" => state} = location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    {recycle(conn), state}
  end

  test "a listed GitHub login signs in and gets an account", %{conn: conn} do
    github_returns(%{id: 7, login: "admin-login", name: "Admin", avatar_url: "https://avatars/7"})
    {conn, state} = start_sign_in(conn)

    conn = get(conn, ~p"/auth/github/callback?#{[code: "abc", state: state]}")
    assert redirected_to(conn) == ~p"/admin"

    assert {:ok, _view, html} = conn |> recycle() |> live(~p"/admin")
    assert html =~ "@admin-login"

    assert %{login: "admin-login", name: "Admin"} =
             BuildDistro.Repo.get_by(BuildDistro.Accounts.User, github_id: 7)
  end

  test "other GitHub accounts are refused and get no account", %{conn: conn} do
    github_returns(%{id: 8, login: "someone-else"})
    {conn, state} = start_sign_in(conn)

    conn = get(conn, ~p"/auth/github/callback?#{[code: "abc", state: state]}")
    assert html_response(conn, 401) =~ "isn&#39;t an admin"
    refute BuildDistro.Repo.get_by(BuildDistro.Accounts.User, github_id: 8)
  end

  test "a callback without this browser's state is rejected", %{conn: conn} do
    github_returns(%{id: 7, login: "admin-login"})
    {conn, _state} = start_sign_in(conn)

    assert conn
           |> get(~p"/auth/github/callback?#{[code: "abc", state: "forged"]}")
           |> html_response(401)
  end

  test "removing a login from the allow list ends that admin's access", %{conn: conn} do
    conn = sign_in_admin(conn)
    assert {:ok, _, _} = live(conn, ~p"/admin")

    Application.put_env(:build_distro, :admin_github_logins, ["someone-else"])
    on_exit(fn -> Application.put_env(:build_distro, :admin_github_logins, ["Admin-Login"]) end)

    assert {:error, {:redirect, %{to: "/admin/login"}}} = live(conn, ~p"/admin")
  end
end
