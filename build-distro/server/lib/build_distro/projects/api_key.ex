defmodule BuildDistro.Projects.ApiKey do
  use Ecto.Schema

  schema "api_keys" do
    belongs_to :project, BuildDistro.Projects.Project
    field :token_hash, :binary, redact: true
    field :last_used_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end
end
