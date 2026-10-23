defmodule BuildDistro.Notifications.Subscription do
  use Ecto.Schema

  schema "push_subscriptions" do
    field :project_id, :integer
    field :bucket, :string
    field :endpoint_hash, :binary, redact: true
    field :encrypted_subscription, :string, redact: true
    field :user_id, :integer
    field :invite_id, :integer
    field :public_link_id, :integer
    timestamps(type: :utc_datetime_usec)
  end
end
