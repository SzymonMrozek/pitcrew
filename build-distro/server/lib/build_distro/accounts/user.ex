defmodule BuildDistro.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :github_id, :integer
    field :login, :string
    field :name, :string
    field :avatar_url, :string
    field :last_sign_in_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:github_id, :login, :name, :avatar_url, :last_sign_in_at])
    |> validate_required([:github_id, :login])
    |> unique_constraint(:github_id)
  end
end
