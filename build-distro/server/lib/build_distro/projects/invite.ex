defmodule BuildDistro.Projects.Invite do
  use Ecto.Schema
  import Ecto.Changeset

  schema "invites" do
    belongs_to :project, BuildDistro.Projects.Project
    field :label, :string
    field :token_hash, :binary, redact: true
    field :last_used_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(invite, attrs) do
    invite
    |> cast(attrs, [:label])
    |> validate_required([:label])
    |> validate_length(:label, max: 80)
  end
end
