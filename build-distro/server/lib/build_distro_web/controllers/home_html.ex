defmodule BuildDistroWeb.HomeHTML do
  use BuildDistroWeb, :html

  def index(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="empty">
        <img src={~p"/images/pitcrew-mark.svg"} class="hero-mark" alt="" />
        <p class="empty-title">Builds are shared by invite</p>
        <p class="muted">Open the invite link you were sent to see a project's builds.</p>
        <p><a href={~p"/admin/login"} class="muted">Admin sign-in</a></p>
      </div>
      <form method="post" action={~p"/auth/invite"} class="card narrow">
        <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
        <h2>Open your invite</h2>
        <p class="muted">Using the Home Screen app? Paste your invite link here to continue.</p>
        <label class="field">
          <span class="field-label">Invite link</span>
          <input type="url" name="invite_url" autocomplete="off" required />
        </label>
        <.button>Continue</.button>
      </form>
    </Layouts.app>
    """
  end
end
