defmodule BuildDistroWeb.AdminLive do
  @moduledoc "Projects, and creating new ones."

  use BuildDistroWeb, :live_view

  alias BuildDistro.Projects

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: Layouts.title("Admin"),
       projects: Projects.list_projects(),
       form: to_form(Projects.change_project()),
       created: nil
     )}
  end

  @impl true
  def handle_event("validate", %{"project" => params}, socket) do
    changeset = Projects.change_project(%BuildDistro.Projects.Project{}, params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("create", %{"project" => params}, socket) do
    case Projects.create_project(params) do
      {:ok, {project, api_key}} ->
        {:noreply,
         assign(socket,
           projects: Projects.list_projects(),
           form: to_form(Projects.change_project()),
           created: %{project: project, api_key: api_key}
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, action: :insert))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} admin?={true}>
      <div class="admin-header">
        <h1>Projects</h1>
        <span class="muted">
          @{@current_admin.login} · <.link href={~p"/admin/logout"} method="delete">Sign out</.link>
        </span>
      </div>

      <section :if={@created} class="card secret">
        <h2>{@created.project.name} is ready</h2>
        <p>Save the CI API key now; it isn't shown again.</p>
        <.secret id="new-api-key" value={@created.api_key} />
        <p class="muted">Add it to your CI as the <code>BUILD_DISTRO_API_KEY</code> secret.</p>
      </section>

      <ul :if={@projects != []} class="project-list">
        <li :for={project <- @projects}>
          <.link navigate={~p"/admin/projects/#{project.slug}"} class="project-row">
            <span>{project.name}</span>
            <span class="muted mono">/{project.slug}</span>
          </.link>
        </li>
      </ul>

      <.form for={@form} id="new-project" phx-change="validate" phx-submit="create" class="card">
        <h2>New project</h2>
        <.input field={@form[:name]} label="Name" placeholder="My App" required />
        <.input
          field={@form[:slug]}
          label="Slug"
          placeholder="myapp"
          hint="Appears in links: /myapp"
          required
        />
        <.input
          field={@form[:github_repo]}
          label="GitHub repository"
          placeholder="owner/name"
          hint="Optional. Links builds to their commits and pull requests."
        />
        <.input
          field={@form[:passcode]}
          type="password"
          label="Passcode for testers"
          autocomplete="new-password"
          required
        />
        <.button>Create project</.button>
      </.form>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :value, :string, required: true

  def secret(assigns) do
    ~H"""
    <div class="secret-value">
      <code id={@id}>{@value}</code>
      <button
        type="button"
        class="button button-small"
        phx-hook="Copy"
        id={"#{@id}-copy"}
        data-copy={@value}
      >
        Copy
      </button>
    </div>
    """
  end
end
