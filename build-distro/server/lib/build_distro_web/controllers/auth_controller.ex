defmodule BuildDistroWeb.AuthController do
  @moduledoc "Admin sign-in with GitHub."

  use BuildDistroWeb, :controller

  alias BuildDistro.{Accounts, GitHubOAuth}
  alias BuildDistroWeb.Access

  def new(conn, _params) do
    if Access.admin?(get_session(conn)),
      do: redirect(conn, to: ~p"/admin"),
      else:
        render(conn, :new,
          configured?: GitHubOAuth.configured?(),
          error: nil,
          page_title: title()
        )
  end

  # The state ties the callback to this browser, so a forged callback can't
  # sign someone in.
  def request(conn, _params) do
    state = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

    conn
    |> put_session("oauth_state", state)
    |> redirect(external: GitHubOAuth.authorize_url(state, url(~p"/auth/github/callback")))
  end

  def callback(conn, %{"code" => code, "state" => state}) do
    expected = get_session(conn, "oauth_state")
    conn = delete_session(conn, "oauth_state")

    with true <- is_binary(expected) and Plug.Crypto.secure_compare(state, expected),
         {:ok, profile} <- GitHubOAuth.fetch_profile(code, url(~p"/auth/github/callback")),
         {:ok, user} <- Accounts.sign_in(profile) do
      conn |> Access.sign_in_admin(user) |> redirect(to: ~p"/admin")
    else
      {:error, :not_admin} -> failed(conn, "That GitHub account isn't an admin here.")
      _ -> failed(conn, "Signing in with GitHub didn't work. Try again.")
    end
  end

  def callback(conn, _params), do: failed(conn, "GitHub sign-in was cancelled.")

  def delete(conn, _params), do: conn |> Access.sign_out_admin() |> redirect(to: ~p"/")

  # Development only: signs in as a listed admin without GitHub.
  def dev(conn, %{"login" => login}) do
    {:ok, user} = Accounts.sign_in(%{"id" => :erlang.phash2(login), "login" => login})
    conn |> Access.sign_in_admin(user) |> redirect(to: ~p"/admin")
  end

  defp failed(conn, message) do
    conn
    |> put_status(:unauthorized)
    |> render(:new, configured?: GitHubOAuth.configured?(), error: message, page_title: title())
  end

  defp title, do: BuildDistroWeb.Layouts.title("Admin sign-in")
end
