defmodule BuildDistroWeb.AuthHTML do
  use BuildDistroWeb, :html

  def new(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="card narrow">
        <h1>Admin</h1>
        <p class="muted">Admins sign in with GitHub to manage projects, invites and links.</p>
        <p :if={@error} class="field-error">{@error}</p>
        <a :if={@configured?} href={~p"/auth/github"} class="button">Sign in with GitHub</a>
        <p :if={!@configured?} class="warning">
          GitHub sign-in isn't configured. Set GITHUB_CLIENT_ID and GITHUB_CLIENT_SECRET on the server.
        </p>
      </div>
    </Layouts.app>
    """
  end
end
