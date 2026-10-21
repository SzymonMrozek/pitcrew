defmodule BuildDistroWeb.JoinHTML do
  use BuildDistroWeb, :html

  def new(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <form method="post" action={~p"/#{@project.slug}/join/#{@token}"} class="card narrow">
        <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
        <h1>{@project.name}</h1>
        <p class="muted">
          You've been invited to install test builds. Enter the passcode you were given.
        </p>
        <label class="field">
          <span class="field-label">Passcode</span>
          <input type="password" name="passcode" autocomplete="current-password" required autofocus />
          <span :if={@error} class="field-error">{@error}</span>
        </label>
        <.button>Continue</.button>
      </form>
    </Layouts.app>
    """
  end

  def invalid(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="empty">
        <p class="empty-title">This invite link doesn't work anymore</p>
        <p class="muted">Ask the person who sent it for a new one.</p>
      </div>
    </Layouts.app>
    """
  end
end
