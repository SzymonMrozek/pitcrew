defmodule BuildDistroWeb.BuildLive do
  @moduledoc """
  One build. A link shared while CI is still uploading turns into an Install
  button by itself. The changelog lists app changes first and tooling last.
  """

  use BuildDistroWeb, :live_view

  alias BuildDistro.{Builds, Changelog}
  alias BuildDistro.Builds.Build
  alias BuildDistroWeb.{InstallLinks, Viewer}

  # Install links live for an hour; the page renews them well before that.
  @refresh_links_every :timer.minutes(10)

  @impl true
  def mount(%{"number" => number}, _session, socket) do
    %{project: project, viewer: viewer} = socket.assigns

    if connected?(socket) do
      Builds.subscribe(project)
      :timer.send_interval(@refresh_links_every, :refresh_links)
    end

    with {number, ""} <- Integer.parse(number),
         %{} = build <- Builds.get_build(project, number),
         true <- Viewer.can_see?(viewer, build) do
      {:ok,
       socket
       |> assign(:page_url, BuildDistroWeb.Endpoint.url() <> Viewer.build_path(viewer, build))
       |> assign_build(build)}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "That build doesn't exist.")
         |> push_navigate(to: Viewer.home_path(viewer))}
    end
  end

  @impl true
  def handle_info({:build, build_id}, socket) do
    build = socket.assigns.build

    if build_id == build.id,
      do: {:noreply, assign_build(socket, Builds.get_build!(build.id))},
      else: {:noreply, assign_related(socket, build)}
  end

  def handle_info(:refresh_links, socket), do: {:noreply, assign_links(socket)}

  defp assign_build(socket, build) do
    socket
    |> assign(
      build: build,
      changelog: Changelog.grouped(build, socket.assigns.project),
      page_title: "#{version_label(build)} ##{build.number} · #{socket.assigns.project.name}"
    )
    |> assign_related(build)
    |> assign_links()
  end

  # A newer ready build of the same branch, and the PR's other builds.
  defp assign_related(socket, build) do
    newer =
      with branch when is_binary(branch) <- build.branch,
           %{number: number} = latest when number > build.number <-
             Builds.latest_ready(socket.assigns.project, branch),
           true <- Viewer.can_see?(socket.assigns.viewer, latest) do
        latest
      else
        _ -> nil
      end

    assign(socket, newer: newer, pr_builds: Builds.pull_request_builds(build))
  end

  defp assign_links(socket) do
    case socket.assigns.build do
      %{state: "ready"} = build -> assign(socket, :install_url, InstallLinks.install_url(build))
      _ -> assign(socket, :install_url, nil)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} project={@project} admin?={@admin?} home={Viewer.home_path(@viewer)}>
      <.link navigate={Viewer.bucket_path(@viewer, @build.bucket)} class="back">
        {Build.bucket_label(@build.bucket)}
      </.link>

      <.link :if={@newer} navigate={Viewer.build_path(@viewer, @newer)} class="notice">
        A newer build of {@build.branch} is ready: {version_label(@newer)} #{@newer.number}
      </.link>

      <section class="hero">
        <.app_icon
          project={@project}
          build={@build}
          size={88}
          src={Viewer.icon_path(@viewer, @build)}
        />
        <div>
          <h1>{@build.display_name || @project.name}</h1>
          <p class="hero-version">
            {version_label(@build)} <span class="muted">#{@build.number}</span>
            <span :if={@build.pr_number}>· PR #{@build.pr_number}</span>
          </p>
          <div class="badges">
            <.state_badge build={@build} />
            <.signing_badge build={@build} />
          </div>
        </div>
      </section>

      <section class="status-card">
        <%= case @build.state do %>
          <% "uploading" -> %>
            <p class="status-title">Uploading from CI</p>
            <.progress_bar build={@build} />
            <p class="muted">
              {format_bytes(Enum.sum(Enum.map(@build.artifacts, & &1.uploaded_bytes)))} of {format_bytes(
                Enum.sum(Enum.map(@build.artifacts, & &1.size))
              )}. This page updates by itself.
            </p>
          <% "processing" -> %>
            <p class="status-title">
              <span class="spinner" aria-hidden="true"></span> Reading the app
            </p>
            <p class="muted">Install appears here in a few seconds.</p>
          <% "ready" -> %>
            <div class="install">
              <div class="install-main">
                <a href={@install_url} class="button button-install">Install</a>
                <p class="muted install-note">Open this page in Safari on your iPhone.</p>
                <p :if={signing(@build) == "enterprise"} class="muted install-note">
                  First install from this team? Open Settings → General → VPN &amp; Device Management,
                  tap {@build.profile["team"] || "the developer"} and trust it.
                </p>
              </div>
              <div class="qr" aria-label="QR code for this page">
                {Phoenix.HTML.raw(
                  @page_url
                  |> EQRCode.encode()
                  |> EQRCode.svg(width: 152, background_color: :transparent, color: "currentColor")
                )}
                <p class="muted">Scan to open on iPhone</p>
              </div>
            </div>
          <% "failed" -> %>
            <p class="status-title">This build failed</p>
            <p class="muted">{@build.failure_reason}</p>
          <% "expired" -> %>
            <p class="status-title">This build expired</p>
            <p class="muted">Its files were deleted. Newer builds are on the builds page.</p>
        <% end %>
      </section>

      <.profile_warning :if={@build.state == "ready"} build={@build} />

      <section :if={@build.release_notes} class="card">
        <h2>Release notes</h2>
        <p class="notes">{@build.release_notes}</p>
      </section>

      <.changelog :if={@changelog} changelog={@changelog} project={@project} />

      <section :if={!@changelog && @build.commit_message} class="card">
        <h2>What's in it</h2>
        <p class="notes">{@build.commit_message}</p>
      </section>

      <section :if={@pr_builds != []} class="card">
        <h2>Other builds of PR #{@build.pr_number}</h2>
        <ul class="related">
          <li :for={other <- @pr_builds}>
            <.link navigate={Viewer.build_path(@viewer, other)}>
              {version_label(other)} #{other.number}
            </.link>
            <span class="muted">{short_sha(other.commit_sha)} · {other.state}</span>
          </li>
        </ul>
      </section>

      <section class="card">
        <h2>Details</h2>
        <dl class="details">
          <div :if={@build.branch}>
            <dt>Branch</dt>
            <dd>{@build.branch}</dd>
          </div>
          <div :if={@build.pr_number}>
            <dt>Pull request</dt>
            <dd>
              <a
                :if={@project.github_repo}
                href={"https://github.com/#{@project.github_repo}/pull/#{@build.pr_number}"}
              >
                #{@build.pr_number}
              </a>
              <span :if={!@project.github_repo}>#{@build.pr_number}</span>
            </dd>
          </div>
          <div :if={@build.commit_sha}>
            <dt>Commit</dt>
            <dd>
              <a
                :if={@project.github_repo}
                href={"https://github.com/#{@project.github_repo}/commit/#{@build.commit_sha}"}
                class="mono"
              >
                {short_sha(@build.commit_sha)}
              </a>
              <span :if={!@project.github_repo} class="mono">{short_sha(@build.commit_sha)}</span>
            </dd>
          </div>
          <div :if={@build.run_url && @viewer.kind != :public}>
            <dt>CI run</dt>
            <dd><a href={@build.run_url}>View run</a></dd>
          </div>
          <div>
            <dt>Uploaded</dt>
            <dd><.relative_time id="uploaded-at" at={@build.inserted_at} /></dd>
          </div>
          <div :if={@build.bundle_id}>
            <dt>Bundle ID</dt>
            <dd class="mono">{@build.bundle_id}</dd>
          </div>
          <div :if={@build.minimum_os}>
            <dt>Requires</dt>
            <dd>iOS {@build.minimum_os} or later</dd>
          </div>
          <div :if={@build.profile}>
            <dt>Signing</dt>
            <dd>
              {signing_label(@build) || @build.profile["kind"]}
              <span :if={signing(@build) == "enterprise"} class="muted">· installs on any device</span>
              <span :if={signing(@build) != "enterprise"} class="muted">
                · {@build.profile["device_count"]} devices
              </span>
              <span :if={@build.profile["name"]} class="muted">· {@build.profile["name"]}</span>
            </dd>
          </div>
        </dl>
      </section>

      <section :if={@build.state == "ready" && Viewer.downloads?(@viewer)} class="card">
        <h2>Downloads</h2>
        <ul class="downloads">
          <li :for={artifact <- @build.artifacts}>
            <a href={~p"/#{@project.slug}/builds/#{@build.number}/download/#{artifact.kind}"} download>
              {artifact.filename}
            </a>
            <span class="muted">{format_bytes(artifact.size)}</span>
          </li>
        </ul>
      </section>
    </Layouts.app>
    """
  end

  attr :changelog, :map, required: true
  attr :project, :map, required: true

  defp changelog(assigns) do
    ~H"""
    <section class="card">
      <div class="card-header">
        <h2>
          <%= case @changelog.kind do %>
            <% "pull_request" -> %>
              Changes in this pull request
            <% "main" -> %>
              Changes since the previous build
            <% "first" -> %>
              First build on {@project.main_branch}
            <% _ -> %>
              Changes from {@project.main_branch}
          <% end %>
        </h2>
        <a
          :if={@project.github_repo && @changelog.base && @changelog.head}
          href={"https://github.com/#{@project.github_repo}/compare/#{@changelog.base}...#{@changelog.head}"}
          class="muted"
        >
          Compare
        </a>
      </div>

      <p :if={@changelog.app == [] && @changelog.tooling == []} class="muted">No new commits.</p>
      <ul :if={@changelog.app != []} class="changes">
        <.change :for={entry <- @changelog.app} entry={entry} project={@project} />
      </ul>

      <details :if={@changelog.tooling != []} class="tooling">
        <summary>Tooling and internal changes ({length(@changelog.tooling)})</summary>
        <ul class="changes">
          <.change :for={entry <- @changelog.tooling} entry={entry} project={@project} />
        </ul>
      </details>
      <p :if={@changelog.truncated} class="muted">Only the first 1,000 commits are listed.</p>
    </section>
    """
  end

  attr :entry, :map, required: true
  attr :project, :map, required: true

  defp change(assigns) do
    ~H"""
    <li class="change">
      <span class="change-subject">
        <span :if={@entry.scope} class="change-scope">{@entry.scope}</span>
        <span :if={@entry.breaking} class="change-breaking">breaking</span>
        {@entry.subject}
      </span>
      <span class="change-meta muted">
        <span :if={@entry.type}>{@entry.type}</span>
        <a
          :if={@project.github_repo}
          href={"https://github.com/#{@project.github_repo}/commit/#{@entry.sha}"}
          class="mono"
        >
          {short_sha(@entry.sha)}
        </a>
        <span :if={@entry.author}>{@entry.author}</span>
      </span>
    </li>
    """
  end

  attr :build, :map, required: true

  defp profile_warning(assigns) do
    expires_at =
      with %{"expires_at" => iso} when is_binary(iso) <- assigns.build.profile,
           {:ok, at, _} <- DateTime.from_iso8601(iso) do
        at
      else
        _ -> nil
      end

    days_left = expires_at && DateTime.diff(expires_at, DateTime.utc_now(), :day)
    assigns = assign(assigns, expires_at: expires_at, days_left: days_left)

    ~H"""
    <p :if={@days_left && @days_left < 0} class="warning">
      The provisioning profile expired on {format_datetime(@expires_at)}. This build won't install.
    </p>
    <p :if={@days_left && @days_left >= 0 && @days_left < 14} class="warning">
      The provisioning profile expires in {@days_left} days.
    </p>
    """
  end
end
