defmodule BuildDistroWeb.BuildsLive do
  @moduledoc "A project's builds, updated live as CI uploads and processes them."

  use BuildDistroWeb, :live_view

  alias BuildDistro.Builds

  @impl true
  def mount(_params, _session, socket) do
    # Subscribe before loading, so no update can fall between the two.
    if connected?(socket), do: Builds.subscribe(socket.assigns.project)
    {:ok, assign(socket, page_title: socket.assigns.project.name)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filter =
      case params["filter"] do
        nil -> :all
        "" -> :all
        "pull-requests" -> :pull_requests
        branch -> branch
      end

    {:noreply, socket |> assign(:filter, filter) |> load()}
  end

  @impl true
  def handle_info({:build, _build_id}, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    project = socket.assigns.project

    assign(socket,
      builds: Builds.list_builds(project, socket.assigns.filter),
      branches: Builds.list_branches(project)
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} project={@project} admin?={@admin?}>
      <nav class="filters" aria-label="Filter builds">
        <.link patch={~p"/#{@project.slug}"} class="chip" aria-current={@filter == :all && "true"}>
          All
        </.link>
        <.link
          :for={branch <- Enum.take(@branches, 4)}
          patch={~p"/#{@project.slug}?#{[filter: branch]}"}
          class="chip"
          aria-current={@filter == branch && "true"}
        >
          {branch}
        </.link>
        <.link
          patch={~p"/#{@project.slug}?#{[filter: "pull-requests"]}"}
          class="chip"
          aria-current={@filter == :pull_requests && "true"}
        >
          Pull requests
        </.link>
      </nav>

      <ol :if={@builds != []} class="build-list">
        <li :for={build <- @builds} id={"build-#{build.id}"}>
          <.link navigate={~p"/#{@project.slug}/builds/#{build.number}"} class="build-row">
            <.app_icon project={@project} build={build} size={44} />
            <span class="build-row-main">
              <span class="build-row-title">
                {version_label(build)}
                <span class="muted">#{build.number}</span>
              </span>
              <span class="build-row-meta">
                <span :if={build.pr_number}>PR #{build.pr_number}</span>
                <span :if={build.branch && !build.pr_number}>{build.branch}</span>
                <span :if={build.commit_message} class="truncate">{first_line(build.commit_message)}</span>
              </span>
              <.progress_bar :if={build.state == "uploading"} build={build} />
            </span>
            <span class="build-row-side">
              <.state_badge build={build} />
              <.relative_time id={"build-#{build.id}-time"} at={build.inserted_at} />
            </span>
          </.link>
        </li>
      </ol>

      <div :if={@builds == []} class="empty">
        <p class="empty-title">No builds yet</p>
        <p class="muted">Builds appear here the moment CI starts uploading them.</p>
      </div>
    </Layouts.app>
    """
  end
end
