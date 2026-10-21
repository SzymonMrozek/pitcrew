defmodule BuildDistro.Repo.Migrations.AddAccountsBucketsAndChangelogs do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :github_id, :integer, null: false
      add :login, :string, null: false
      add :name, :string
      add :avatar_url, :string
      add :last_sign_in_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:github_id])

    alter table(:projects) do
      add :main_branch, :string, null: false, default: "main"
      add :tooling_types, :string
      add :tooling_scopes, :string
    end

    alter table(:builds) do
      add :bucket, :string, null: false, default: "manual"
      add :changelog, :map
    end

    execute(
      """
      UPDATE builds SET bucket = CASE
        WHEN pr_number IS NOT NULL THEN 'pull_requests'
        WHEN branch = (SELECT main_branch FROM projects WHERE projects.id = builds.project_id) THEN 'main'
        ELSE 'manual'
      END
      """,
      ""
    )

    create index(:builds, [:project_id, :bucket, :number])

    create table(:public_links) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :bucket, :string, null: false
      add :token_hash, :binary, null: false
      add :last_used_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:public_links, [:token_hash])
    create index(:public_links, [:project_id])
  end
end
