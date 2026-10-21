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
    </Layouts.app>
    """
  end
end
