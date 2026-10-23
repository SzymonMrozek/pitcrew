defmodule BuildDistroWeb.JoinController do
  @moduledoc "Accepts an invite link: the passcode turns it into access for this browser."

  use BuildDistroWeb, :controller

  alias BuildDistro.{Projects, RateLimiter}
  alias BuildDistroWeb.Access

  @attempts 10
  @window :timer.minutes(10)

  # Installed web apps may have a different cookie jar from the browser that accepted the invite.
  def open(conn, %{"invite_url" => url}) when is_binary(url) and byte_size(url) <= 2048 do
    origin = URI.parse(BuildDistroWeb.Endpoint.url())

    with {:ok, %URI{scheme: scheme, host: host, port: port, path: path}} <-
           URI.new(String.trim(url)),
         true <- {scheme, host, port} == {origin.scheme, origin.host, origin.port},
         ["", project, "join", token] <- String.split(path || "", "/"),
         true <- project != "" and token != "" do
      redirect(conn, to: ~p"/#{project}/join/#{token}")
    else
      _ -> invalid_url(conn)
    end
  end

  def open(conn, _), do: invalid_url(conn)

  defp invalid_url(conn) do
    conn
    |> put_flash(:error, "Paste the invite link for this build-distro server.")
    |> redirect(to: ~p"/")
  end

  def new(conn, %{"project" => slug, "token" => token}) do
    with %{} = project <- Projects.get_project_by_slug(slug),
         %{} <- Projects.find_active_invite(project, token) do
      render(conn, :new,
        project: project,
        token: token,
        error: nil,
        page_title: BuildDistroWeb.Layouts.title(project.name)
      )
    else
      _ -> invalid(conn)
    end
  end

  def create(conn, %{"project" => slug, "token" => token, "passcode" => passcode}) do
    with %{} = project <- Projects.get_project_by_slug(slug),
         %{} = invite <- Projects.find_active_invite(project, token) do
      cond do
        RateLimiter.hit({:join, client_ip(conn)}, @attempts, @window) == :error ->
          conn
          |> put_status(:too_many_requests)
          |> render(:new,
            project: project,
            token: token,
            error: "Too many attempts. Try again in a few minutes.",
            page_title: BuildDistroWeb.Layouts.title(project.name)
          )

        Projects.verify_passcode(project, passcode) ->
          conn
          |> Access.accept_invite(project, invite)
          |> redirect(to: ~p"/#{project.slug}")

        true ->
          conn
          |> put_status(:unauthorized)
          |> render(:new,
            project: project,
            token: token,
            error: "That passcode isn't right.",
            page_title: BuildDistroWeb.Layouts.title(project.name)
          )
      end
    else
      _ -> invalid(conn)
    end
  end

  defp invalid(conn) do
    conn |> put_status(:not_found) |> render(:invalid)
  end

  # Only the Cloudflare Tunnel reaches the server, so its header is trustworthy.
  @doc false
  def client_ip(conn) do
    case get_req_header(conn, "cf-connecting-ip") do
      [ip | _] -> ip
      [] -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end
end
