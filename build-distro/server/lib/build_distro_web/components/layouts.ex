defmodule BuildDistroWeb.Layouts do
  @moduledoc "The page skeleton and the header every page shares."

  use BuildDistroWeb, :html

  embed_templates "layouts/*"

  @doc "A tab title that starts with the product: `build-distro · Admin`."
  def title(page), do: "build-distro · " <> page

  attr :flash, :map, required: true
  attr :project, :map, default: nil
  attr :admin?, :boolean, default: false
  attr :home, :string, default: nil, doc: "where the brand links; the project's builds by default"
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="topbar">
      <a href={@home || if(@project, do: ~p"/#{@project.slug}", else: ~p"/")} class="brand">
        <img src={~p"/images/favicon.svg"} class="brand-mark" alt="" />
        <span>{if @project, do: @project.name, else: "build-distro"}</span>
      </a>
      <nav class="topbar-links">
        <a :if={@admin?} href={~p"/admin"}>Admin</a>
      </nav>
    </header>
    <p class="connection" role="status">Reconnecting…</p>
    <.flash_group flash={@flash} />
    <main class="page">
      {render_slot(@inner_block)}
    </main>
    """
  end
end
