defmodule BuildDistroWeb.AdminProjectLive do
  @moduledoc "Invites, passcode, settings and the CI key of one project."

  use BuildDistroWeb, :live_view

  import BuildDistroWeb.AdminLive, only: [secret: 1]

  alias BuildDistro.{Changelog, Projects}
  alias BuildDistro.Builds.Build

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    case Projects.get_project_by_slug(slug) do
      nil ->
        {:ok, socket |> put_flash(:error, "No such project.") |> push_navigate(to: ~p"/admin")}

      project ->
        {:ok,
         socket
         |> assign(
           page_title: Layouts.title("Admin · #{project.name}"),
           new_invite_url: nil,
           new_api_key: nil,
           new_public_url: nil
         )
         |> assign_project(project)}
    end
  end

  defp assign_project(socket, project) do
    assign(socket,
      project: project,
      invites: Projects.list_invites(project),
      invite_form: to_form(Projects.change_invite(), as: :invite),
      passcode_form: to_form(%{"passcode" => ""}, as: :passcode),
      settings_form: to_form(Ecto.Changeset.change(project), as: :settings),
      public_links: Projects.list_public_links(project)
    )
  end

  @impl true
  def handle_event("create_invite", %{"invite" => params}, socket) do
    project = socket.assigns.project

    case Projects.create_invite(project, params) do
      {:ok, _invite, token} ->
        {:noreply,
         socket
         |> assign_project(project)
         |> assign(new_invite_url: BuildDistroWeb.Links.invite_url(project, token))}

      {:error, changeset} ->
        {:noreply, assign(socket, invite_form: to_form(changeset, as: :invite, action: :insert))}
    end
  end

  def handle_event("revoke_invite", %{"id" => id}, socket) do
    :ok = Projects.revoke_invite(socket.assigns.project, String.to_integer(id))
    {:noreply, assign_project(socket, socket.assigns.project)}
  end

  def handle_event("change_passcode", %{"passcode" => params}, socket) do
    case Projects.change_passcode(socket.assigns.project, params) do
      {:ok, project} ->
        {:noreply, socket |> assign_project(project) |> put_flash(:info, "Passcode changed.")}

      {:error, changeset} ->
        {:noreply,
         assign(socket, passcode_form: to_form(changeset, as: :passcode, action: :update))}
    end
  end

  def handle_event("save_settings", %{"settings" => params}, socket) do
    case Projects.update_project(socket.assigns.project, params) do
      {:ok, project} ->
        {:noreply, socket |> assign_project(project) |> put_flash(:info, "Saved.")}

      {:error, changeset} ->
        {:noreply,
         assign(socket, settings_form: to_form(changeset, as: :settings, action: :update))}
    end
  end

  def handle_event("create_public_link", %{"bucket" => bucket}, socket) do
    project = socket.assigns.project

    case Projects.create_public_link(project, bucket) do
      {:ok, _link, token} ->
        {:noreply,
         socket
         |> assign_project(project)
         |> assign(new_public_url: BuildDistroWeb.Endpoint.url() <> "/#{project.slug}/p/#{token}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Unknown bucket.")}
    end
  end

  def handle_event("revoke_public_link", %{"id" => id}, socket) do
    :ok = Projects.revoke_public_link(socket.assigns.project, String.to_integer(id))
    {:noreply, assign_project(socket, socket.assigns.project)}
  end

  def handle_event("rotate_api_key", _params, socket) do
    {:ok, api_key} = Projects.rotate_api_key(socket.assigns.project)
    {:noreply, assign(socket, new_api_key: api_key)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} admin?={true}>
      <.link navigate={~p"/admin"} class="back">Projects</.link>
      <div class="admin-header">
        <h1>{@project.name}</h1>
        <.link navigate={~p"/#{@project.slug}"}>Open builds</.link>
      </div>

      <section class="card">
        <h2>Invites</h2>
        <p class="muted">
          Each tester gets their own link, so you can revoke one without the others.
          They also need the project passcode.
        </p>

        <div :if={@new_invite_url} class="secret">
          <p>Send this link with the passcode. It isn't shown again.</p>
          <.secret id="new-invite" value={@new_invite_url} />
        </div>

        <.form for={@invite_form} id="invite-form" phx-submit="create_invite" class="inline-form">
          <.input
            field={@invite_form[:label]}
            label="Who is it for?"
            placeholder="Anna's iPhone"
            required
          />
          <.button>Create invite</.button>
        </.form>

        <ul class="invite-list">
          <li :for={invite <- @invites} class={invite.revoked_at && "revoked"}>
            <span>
              {invite.label}
              <span class="muted">
                <%= cond do %>
                  <% invite.revoked_at -> %>
                    · revoked
                  <% invite.last_used_at -> %>
                    · last used
                    <.relative_time id={"invite-#{invite.id}-used"} at={invite.last_used_at} />
                  <% true -> %>
                    · not used yet
                <% end %>
              </span>
            </span>
            <button
              :if={!invite.revoked_at}
              type="button"
              class="button button-small button-danger"
              phx-click="revoke_invite"
              phx-value-id={invite.id}
              data-confirm={"Revoke #{invite.label}'s access?"}
            >
              Revoke
            </button>
          </li>
        </ul>
      </section>

      <.form for={@passcode_form} id="passcode-form" phx-submit="change_passcode" class="card">
        <h2>Passcode</h2>
        <p class="muted">Changing it doesn't sign out testers who already joined.</p>
        <.input
          field={@passcode_form[:passcode]}
          type="password"
          label="New passcode"
          autocomplete="new-password"
          required
        />
        <.button>Change passcode</.button>
      </.form>

      <.form for={@settings_form} id="settings-form" phx-submit="save_settings" class="card">
        <h2>Project</h2>
        <.input field={@settings_form[:name]} label="Name" required />
        <.input
          field={@settings_form[:github_repo]}
          label="GitHub repository"
          placeholder="owner/name"
          hint="Optional. Links builds to their commits and pull requests."
        />
        <.input
          field={@settings_form[:main_branch]}
          label="Main branch"
          hint="Builds of this branch go to Main; other branches without a pull request go to Manual."
          required
        />
        <.input
          field={@settings_form[:tooling_types]}
          label="Tooling commit types"
          placeholder={Changelog.default_tooling_types()}
          hint="Conventional Commit types listed last in changelogs. Empty uses the placeholder."
        />
        <.input
          field={@settings_form[:tooling_scopes]}
          label="Tooling scopes"
          placeholder={Changelog.default_tooling_scopes()}
          hint="Scopes listed last whatever the type, like fix(tooling). Empty uses the placeholder."
        />
        <.button>Save</.button>
      </.form>

      <section class="card">
        <h2>Public links</h2>
        <p class="muted">
          Anyone with a public link can see and install that bucket's builds, without an invite or
          passcode. Revoke a link to stop it working.
        </p>

        <div :if={@new_public_url} class="secret">
          <p>Copy the link now; it isn't shown again.</p>
          <.secret id="new-public-link" value={@new_public_url} />
        </div>

        <div class="inline-form">
          <button
            :for={bucket <- Build.buckets()}
            type="button"
            class="button button-small"
            phx-click="create_public_link"
            phx-value-bucket={bucket}
          >
            New {Build.bucket_label(bucket)} link
          </button>
        </div>

        <ul class="invite-list">
          <li :for={link <- @public_links}>
            <span>
              {Build.bucket_label(link.bucket)}
              <span class="muted">
                · created <.relative_time id={"public-#{link.id}-created"} at={link.inserted_at} />
                <span :if={link.last_used_at}>
                  · last used <.relative_time id={"public-#{link.id}-used"} at={link.last_used_at} />
                </span>
              </span>
            </span>
            <button
              type="button"
              class="button button-small button-danger"
              phx-click="revoke_public_link"
              phx-value-id={link.id}
              data-confirm={"Stop this #{Build.bucket_label(link.bucket)} link working?"}
            >
              Revoke
            </button>
          </li>
        </ul>
      </section>

      <section class="card">
        <h2>CI API key</h2>
        <div :if={@new_api_key} class="secret">
          <p>The old key stopped working. Update the CI secret with this one.</p>
          <.secret id="new-api-key" value={@new_api_key} />
        </div>
        <button
          type="button"
          class="button button-danger"
          phx-click="rotate_api_key"
          data-confirm="The current key stops working immediately. Continue?"
        >
          Replace API key
        </button>
      </section>
    </Layouts.app>
    """
  end
end
