defmodule BuildDistroWeb.AdminSessionHTML do
  use BuildDistroWeb, :html

  def new(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <form method="post" action={~p"/admin/login"} class="card narrow">
        <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
        <h1>Admin</h1>
        <label class="field">
          <span class="field-label">Password</span>
          <input type="password" name="password" autocomplete="current-password" required autofocus />
          <span :if={@error} class="field-error">{@error}</span>
        </label>
        <.button>Sign in</.button>
      </form>
    </Layouts.app>
    """
  end
end
