defmodule BuildDistroWeb.AdminSessionController do
  use BuildDistroWeb, :controller

  alias BuildDistro.RateLimiter
  alias BuildDistroWeb.{Access, JoinController}

  @attempts 5
  @window :timer.minutes(10)

  def new(conn, _params), do: render(conn, :new, error: nil)

  def create(conn, %{"password" => password}) do
    expected = Application.fetch_env!(:build_distro, :admin_password)

    cond do
      RateLimiter.hit({:admin, JoinController.client_ip(conn)}, @attempts, @window) == :error ->
        conn
        |> put_status(:too_many_requests)
        |> render(:new, error: "Too many attempts. Try again later.")

      Plug.Crypto.secure_compare(password, expected) ->
        conn |> Access.sign_in_admin() |> redirect(to: ~p"/admin")

      true ->
        conn |> put_status(:unauthorized) |> render(:new, error: "Wrong password.")
    end
  end

  def delete(conn, _params) do
    conn |> Access.sign_out_admin() |> redirect(to: ~p"/")
  end
end
