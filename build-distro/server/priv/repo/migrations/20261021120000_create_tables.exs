defmodule BuildDistro.Repo.Migrations.CreateTables do
  use Ecto.Migration

  def change do
    create table(:projects) do
      add :slug, :string, null: false
      add :name, :string, null: false
      add :github_repo, :string
      add :passcode_hash, :string, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:projects, [:slug])

    create table(:api_keys) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :token_hash, :binary, null: false
      add :last_used_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:api_keys, [:token_hash])

    create table(:invites) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :label, :string, null: false
      add :token_hash, :binary, null: false
      add :last_used_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:invites, [:token_hash])
    create index(:invites, [:project_id])

    create table(:builds) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :number, :integer, null: false
      add :idempotency_key, :string, null: false
      add :state, :string, null: false
      add :failure_reason, :string
      add :commit_sha, :string
      add :branch, :string
      add :pr_number, :integer
      add :run_url, :string
      add :commit_message, :text
      add :release_notes, :text
      add :bundle_id, :string
      add :version, :string
      add :build_version, :string
      add :display_name, :string
      add :minimum_os, :string
      add :profile, :map
      add :icon_key, :string
      add :ready_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:builds, [:project_id, :number])
    create unique_index(:builds, [:project_id, :idempotency_key])
    create index(:builds, [:project_id, :branch, :state])
    create index(:builds, [:state, :updated_at])

    create table(:artifacts) do
      add :build_id, references(:builds, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :filename, :string, null: false
      add :size, :integer, null: false
      add :part_size, :integer, null: false
      add :object_key, :string, null: false
      add :upload_id, :string
      add :uploaded_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:artifacts, [:build_id, :kind])

    create table(:artifact_parts, primary_key: false) do
      add :artifact_id, references(:artifacts, on_delete: :delete_all), null: false
      add :number, :integer, null: false
      add :size, :integer, null: false
    end

    create unique_index(:artifact_parts, [:artifact_id, :number])
  end
end
