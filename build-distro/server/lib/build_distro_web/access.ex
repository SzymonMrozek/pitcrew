defmodule BuildDistroWeb.Access do
  @moduledoc """
  Who may see what. Admins sign in with GitHub; testers hold accepted invites
  per project in their session; anyone with a public link sees that link's
  bucket. Every request and every LiveView mount checks again, so removing an
  admin login or revoking an invite or link takes effect at once.
  """

  import Plug.Conn
  import Phoenix.Controller

  alias BuildDistro.{Accounts, Projects}
  alias BuildDistroWeb.Viewer

  @refresh_after_seconds 24 * 60 * 60

  ## Session contents

  def accept_invite(conn, project, invite) do
    invites = conn |> get_session("invites", %{}) |> Map.put(to_string(project.id), invite.id)
    conn |> put_session("invites", invites) |> configure_session(renew: true)
  end

  def sign_in_admin(conn, user) do
    conn |> put_session("user_id", user.id) |> configure_session(renew: true)
  end

  def sign_out_admin(conn), do: delete_session(conn, "user_id")

  def current_admin(session), do: Accounts.get_admin(session["user_id"])

  def admin?(session), do: current_admin(session) != nil

  @doc "What a session may see of a project, or nil."
  def session_viewer(session, project) do
    cond do
      user = current_admin(session) ->
        Viewer.new(project, :admin, admin: user)

      invite_id = get_in(session, ["invites", to_string(project.id)]) ->
        if Projects.invite_active?(project, invite_id), do: Viewer.new(project, :tester)

      true ->
        nil
    end
  end

  @doc "What a public link shows, or nil."
  def public_viewer(project, token) do
    case Projects.find_active_public_link(project, token) do
      nil -> nil
      link -> Viewer.new(project, :public, bucket: link.bucket, token: token)
    end
  end

  ## Plugs

  @doc "Rewrites the session cookie once a day, so its expiry slides."
  def refresh_session(conn, _opts) do
    now = System.system_time(:second)

    case get_session(conn, "refreshed_at") do
      at when is_integer(at) and now - at < @refresh_after_seconds -> conn
      _ -> put_session(conn, "refreshed_at", now)
    end
  end

  def require_project_access(conn, _opts) do
    project = Projects.get_project_by_slug(conn.path_params["project"])

    viewer =
      project &&
        case conn.path_params do
          %{"token" => token} -> public_viewer(project, token)
          _ -> session_viewer(get_session(conn), project)
        end

    if viewer do
      conn |> assign(:project, project) |> assign(:viewer, viewer)
    else
      conn
      |> put_status(:not_found)
      |> put_view(BuildDistroWeb.ErrorHTML)
      |> render(:"404")
      |> halt()
    end
  end

  ## LiveView

  def on_mount(:admin, _params, session, socket) do
    case current_admin(session) do
      nil -> {:halt, Phoenix.LiveView.redirect(socket, to: "/admin/login")}
      user -> {:cont, Phoenix.Component.assign(socket, current_admin: user, admin?: true)}
    end
  end

  def on_mount(kind, %{"project" => slug} = params, session, socket)
      when kind in [:project, :public] do
    project = Projects.get_project_by_slug(slug)

    viewer =
      project &&
        case kind do
          :project -> session_viewer(session, project)
          :public -> public_viewer(project, params["token"])
        end

    if viewer do
      {:cont,
       Phoenix.Component.assign(socket,
         project: project,
         viewer: viewer,
         admin?: viewer.kind == :admin
       )}
    else
      message =
        if kind == :public,
          do: "That link doesn't work anymore.",
          else: "That page needs an invite link."

      {:halt,
       socket |> Phoenix.LiveView.put_flash(:error, message) |> Phoenix.LiveView.redirect(to: "/")}
    end
  end
end
