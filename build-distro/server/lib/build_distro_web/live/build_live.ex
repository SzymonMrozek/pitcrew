defmodule BuildDistroWeb.BuildLive do
  @moduledoc """
  One build. A link shared while CI is still uploading turns into an Install
  button by itself.
  """

  use BuildDistroWeb, :live_view

  alias BuildDistro.Builds
  alias BuildDistroWeb.InstallLinks

  # Install links live for an hour; the page renews them well before that.
  @refresh_links_every :timer.minutes(10)

  @impl true
  def mount(%{"number" => number}, _session, socket) do
    project = socket.assigns.project

    if connected?(socket) do
      Builds.subscribe(project)
      :timer.send_interval(@refresh_links_every, :refresh_links)
    end

    with {number, ""} <- Integer.parse(number),
         %{} = build <- Builds.get_build(project, number) do
      {:ok,
       socket
       |> assign_build(build)
       |> assign(:page_url, url(~p"/#{project.slug}/builds/#{number}"))}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "That build doesn't exist.")
         |> push_navigate(to: ~p"/#{project.slug}")}
    end
  end

  @impl true
  def handle_info({:build, build_id}, socket) do
    build = socket.assigns.build

    cond do
      build_id == build.id ->
        {:noreply, assign_build(socket, Builds.get_build!(build.id))}

      build.branch ->
        {:noreply, assign_newer(socket, build)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info(:refresh_links, socket), do: {:noreply, assign_links(socket)}

  defp assign_build(socket, build) do
    socket
    |> assign(
      build: build,
      page_title: "#{version_label(build)} ##{build.number} · #{socket.assigns.project.name}"
    )
    |> assign_newer(build)
    |> assign_links()
  end

  defp assign_newer(socket, build) do
    newer =
      with branch when is_binary(branch) <- build.branch,
           %{number: number} = latest when number > build.number <-
             Builds.latest_ready(socket.assigns.project, branch) do
        latest
      else
        _ -> nil
      end

    assign(socket, :newer, newer)
  end

  defp assign_links(socket) do
    case socket.assigns.build do
      %{state: "ready"} = build ->
        assign(socket, :install_url, InstallLinks.install_url(build))

      _ ->
        assign(socket, :install_url, nil)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} project={@project} admin?={@admin?}>
      <.link navigate={~p"/#{@project.slug}"} class="back">All builds</.link>

      <.link :if={@newer} navigate={~p"/#{@project.slug}/builds/#{@newer.number}"} class="notice">
        A newer build of {@build.branch} is ready: {version_label(@newer)} #{@newer.number}
      </.link>

      <section class="hero">
        <.app_icon project={@project} build={@build} size={88} />
        <div>
          <h1>{@build.display_name || @project.name}</h1>
          <p class="hero-version">
            {version_label(@build)} <span class="muted">#{@build.number}</span>
          </p>
          <.state_badge build={@build} />
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

      <section :if={@build.release_notes || @build.commit_message} class="card">
        <h2>What's in it</h2>
        <p class="notes">{@build.release_notes || @build.commit_message}</p>
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
          <div :if={@build.run_url}>
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
            <dt>Profile</dt>
            <dd>
              {@build.profile["name"]}
              <span class="muted">· {@build.profile["kind"]} · {@build.profile["device_count"]} devices</span>
            </dd>
          </div>
        </dl>
      </section>

      <section :if={@build.state == "ready"} class="card">
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
