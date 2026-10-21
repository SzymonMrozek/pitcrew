defmodule BuildDistroWeb.BuildsLive do
  @moduledoc """
  A project's builds by bucket: Main, Pull requests and Manual. Pull requests
  show their newest build, with the count of earlier ones. Updated live as CI
  uploads and processes builds.
  """

  use BuildDistroWeb, :live_view

  alias BuildDistro.Builds
  alias BuildDistro.Builds.Build
  alias BuildDistroWeb.Viewer

  @impl true
  def mount(_params, _session, socket) do
    # Subscribe before loading, so no update can fall between the two.
    if connected?(socket), do: Builds.subscribe(socket.assigns.project)
    {:ok, assign(socket, page_title: Layouts.title(socket.assigns.project.name))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    buckets = socket.assigns.viewer.buckets
    bucket = if params["bucket"] in buckets, do: params["bucket"], else: hd(buckets)
    {:noreply, socket |> assign(:bucket, bucket) |> load()}
  end

  @impl true
  def handle_info({:build, _build_id}, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    %{project: project, bucket: bucket} = socket.assigns
    builds = Builds.list_builds(project, bucket)

    assign(socket,
      rows: rows(bucket, builds),
      counts: Builds.bucket_counts(project)
    )
  end

  # A pull request is one row: its newest build and how many came before.
  defp rows("pull_requests", builds) do
    builds
    |> Enum.group_by(& &1.pr_number)
    |> Enum.map(fn {_pr, [newest | older]} -> {newest, length(older)} end)
    |> Enum.sort_by(fn {build, _} -> build.number end, :desc)
  end

  defp rows(_bucket, builds), do: Enum.map(builds, &{&1, 0})

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} project={@project} admin?={@admin?} home={Viewer.home_path(@viewer)}>
      <nav :if={length(@viewer.buckets) > 1} class="tabs" aria-label="Buckets">
        <.link
          :for={bucket <- @viewer.buckets}
          patch={Viewer.bucket_path(@viewer, bucket)}
          class="tab"
          aria-current={@bucket == bucket && "page"}
        >
          {Build.bucket_label(bucket)}
          <span class="tab-count">{Map.get(@counts, bucket, 0)}</span>
        </.link>
      </nav>
      <h1 :if={@viewer.kind == :public} class="bucket-title">{Build.bucket_label(@bucket)} builds</h1>

      <ol :if={@rows != []} class="build-list">
        <li :for={{build, older} <- @rows} id={"build-#{build.id}"}>
          <.link navigate={Viewer.build_path(@viewer, build)} class="build-row">
            <.app_icon
              project={@project}
              build={build}
              size={44}
              src={Viewer.icon_path(@viewer, build)}
            />
            <span class="build-row-main">
              <span class="build-row-title">
                <span :if={build.pr_number}>PR #{build.pr_number}</span>
                <span :if={!build.pr_number}>{version_label(build)}</span>
                <span class="muted">#{build.number}</span>
              </span>
              <span class="build-row-meta">
                <span :if={build.pr_number}>{version_label(build)}</span>
                <span :if={build.bucket == "manual" && build.branch}>{build.branch}</span>
                <span :if={build.commit_message} class="truncate">{first_line(build.commit_message)}</span>
              </span>
              <span :if={older > 0} class="build-row-meta">
                {older} earlier {if older == 1, do: "build", else: "builds"}
              </span>
              <.progress_bar :if={build.state == "uploading"} build={build} />
            </span>
            <span class="build-row-side">
              <.signing_badge build={build} />
              <.state_badge build={build} />
              <.relative_time id={"build-#{build.id}-time"} at={build.inserted_at} />
            </span>
          </.link>
        </li>
      </ol>

      <div :if={@rows == []} class="empty">
        <p class="empty-title">No {String.downcase(Build.bucket_label(@bucket))} builds yet</p>
        <p class="muted">Builds appear here the moment CI starts uploading them.</p>
      </div>
    </Layouts.app>
    """
  end
end
