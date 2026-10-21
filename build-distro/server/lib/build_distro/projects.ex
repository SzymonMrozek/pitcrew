defmodule BuildDistro.Projects do
  @moduledoc "Projects and who may use them: CI API keys and tester invites."

  import Ecto.Query

  alias BuildDistro.Projects.{ApiKey, Invite, Project}
  alias BuildDistro.{Repo, Secrets}

  def list_projects, do: Repo.all(from p in Project, order_by: p.name)

  def get_project_by_slug(slug), do: Repo.get_by(Project, slug: slug)

  def get_project!(id), do: Repo.get!(Project, id)

  def change_project(project \\ %Project{}, attrs \\ %{}),
    do: Project.create_changeset(project, attrs)

  @doc "Creates a project and its first API key, which is returned only here."
  def create_project(attrs) do
    Repo.transact(fn ->
      with {:ok, project} <- %Project{} |> Project.create_changeset(attrs) |> Repo.insert(),
           {:ok, api_key} <- insert_api_key(project) do
        {:ok, {project, api_key}}
      end
    end)
  end

  def update_project(project, attrs),
    do: project |> Project.update_changeset(attrs) |> Repo.update()

  def change_passcode(project, attrs),
    do: project |> Project.passcode_changeset(attrs) |> Repo.update()

  def verify_passcode(%Project{passcode_hash: hash}, passcode),
    do: Secrets.verify_passcode(passcode, hash)

  @doc "Revokes every active API key and returns a new one."
  def rotate_api_key(project) do
    now = DateTime.utc_now()

    Repo.transact(fn ->
      from(k in ApiKey, where: k.project_id == ^project.id and is_nil(k.revoked_at))
      |> Repo.update_all(set: [revoked_at: now])

      insert_api_key(project)
    end)
  end

  @doc "The project an API key belongs to, if the key is active."
  def project_for_api_key(token) when is_binary(token) do
    hash = Secrets.hash_token(token)

    query =
      from k in ApiKey,
        join: p in assoc(k, :project),
        where: k.token_hash == ^hash and is_nil(k.revoked_at),
        select: {k, p}

    case Repo.one(query) do
      {key, project} ->
        touch(key)
        {:ok, project}

      nil ->
        :error
    end
  end

  def project_for_api_key(_), do: :error

  def list_invites(project) do
    Repo.all(
      from i in Invite,
        where: i.project_id == ^project.id,
        order_by: [asc: not is_nil(i.revoked_at), desc: i.inserted_at]
    )
  end

  def change_invite(attrs \\ %{}), do: Invite.changeset(%Invite{}, attrs)

  @doc "Creates an invite. The token is returned only here."
  def create_invite(project, attrs) do
    token = Secrets.generate_token("inv")

    %Invite{project_id: project.id, token_hash: Secrets.hash_token(token)}
    |> Invite.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, invite} -> {:ok, invite, token}
      error -> error
    end
  end

  def revoke_invite(project, invite_id) do
    from(i in Invite,
      where: i.id == ^invite_id and i.project_id == ^project.id and is_nil(i.revoked_at)
    )
    |> Repo.update_all(set: [revoked_at: DateTime.utc_now()])

    :ok
  end

  def find_active_invite(project, token) when is_binary(token) do
    hash = Secrets.hash_token(token)

    Repo.one(
      from i in Invite,
        where: i.project_id == ^project.id and i.token_hash == ^hash and is_nil(i.revoked_at)
    )
  end

  def find_active_invite(_, _), do: nil

  @doc "Whether an invite accepted earlier still grants access."
  def invite_active?(project, invite_id) do
    query =
      from i in Invite,
        where: i.id == ^invite_id and i.project_id == ^project.id and is_nil(i.revoked_at)

    case Repo.one(query) do
      nil ->
        false

      invite ->
        touch(invite)
        true
    end
  end

  defp insert_api_key(project) do
    token = Secrets.generate_token("bd_" <> project.slug)

    case Repo.insert(%ApiKey{project_id: project.id, token_hash: Secrets.hash_token(token)}) do
      {:ok, _} -> {:ok, token}
      error -> error
    end
  end

  # Usage timestamps are informational, so they're written at most once a minute.
  defp touch(%{last_used_at: last_used_at} = record) do
    now = DateTime.utc_now()

    if is_nil(last_used_at) or DateTime.diff(now, last_used_at) > 60 do
      record.__struct__
      |> where(id: ^record.id)
      |> Repo.update_all(set: [last_used_at: now])
    end
  end
end
