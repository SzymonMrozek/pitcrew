defmodule BuildDistro.Repo.Migrations.AddPushSubscriptions do
  use Ecto.Migration

  def change do
    create table(:push_subscriptions) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :bucket, :string, null: false
      add :endpoint_hash, :binary, null: false
      add :encrypted_subscription, :text, null: false
      add :user_id, references(:users, on_delete: :delete_all)
      add :invite_id, references(:invites, on_delete: :delete_all)
      add :public_link_id, references(:public_links, on_delete: :delete_all)
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:push_subscriptions, [:project_id, :bucket, :endpoint_hash])
  end
end
