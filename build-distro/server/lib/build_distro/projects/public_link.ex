defmodule BuildDistro.Projects.PublicLink do
  use Ecto.Schema

  schema "public_links" do
    belongs_to :project, BuildDistro.Projects.Project
    field :bucket, :string
    field :token_hash, :binary, redact: true
    field :last_used_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end
end
