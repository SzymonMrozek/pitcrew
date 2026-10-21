defmodule BuildDistroWeb.Access do
  @moduledoc """
  Who may see what. Testers hold accepted invites per project in their
  session; admins sign in with the admin password. Every request and every
  LiveView mount checks again, so revoking an invite takes effect at once.
  """

  import Plug.Conn
  import Phoenix.Controller

  alias BuildDistro.Projects

  @refresh_after_seconds 24 * 60 * 60

  ## Session contents

  def accept_invite(conn, project, invite) do
    invites = conn |> get_session("invites", %{}) |> Map.put(to_string(project.id), invite.id)
    conn |> put_session("invites", invites) |> configure_session(renew: true)
  end

  def sign_in_admin(conn) do
    conn |> put_session("admin", admin_fingerprint()) |> configure_session(renew: true)
  end

  def sign_out_admin(conn), do: delete_session(conn, "admin")

  def admin?(session), do: Plug.Crypto.secure_compare(session["admin"] || "", admin_fingerprint())

  # Sessions name the password they were created with, so changing
  # ADMIN_PASSWORD signs every admin out.
  defp admin_fingerprint do
    password = Application.fetch_env!(:build_distro, :admin_password)
    :crypto.hash(:sha256, "admin:" <> password) |> Base.url_encode64() |> binary_part(0, 22)
  end

  def project_access?(session, project) do
    admin?(session) or
      case get_in(session, ["invites", to_string(project.id)]) do
        nil -> false
        invite_id -> Projects.invite_active?(project, invite_id)
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

    if project && project_access?(get_session(conn), project) do
      assign(conn, :project, project)
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
    if admin?(session) do
      {:cont, Phoenix.Component.assign(socket, :admin?, true)}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: "/admin/login")}
    end
  end

  def on_mount(:project, %{"project" => slug}, session, socket) do
    project = Projects.get_project_by_slug(slug)

    if project && project_access?(session, project) do
      {:cont,
       socket
       |> Phoenix.Component.assign(:project, project)
       |> Phoenix.Component.assign(:admin?, admin?(session))}
    else
      {:halt,
       socket
       |> Phoenix.LiveView.put_flash(:error, "That page needs an invite link.")
       |> Phoenix.LiveView.redirect(to: "/")}
    end
  end
end
