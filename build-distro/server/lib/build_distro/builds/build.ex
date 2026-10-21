defmodule BuildDistro.Builds.Build do
  use Ecto.Schema
  import Ecto.Changeset

  @states ~w(uploading processing ready failed expired)

  schema "builds" do
    belongs_to :project, BuildDistro.Projects.Project
    has_many :artifacts, BuildDistro.Builds.Artifact

    field :number, :integer
    field :idempotency_key, :string
    field :state, :string, default: "uploading"
    field :failure_reason, :string
    field :commit_sha, :string
    field :branch, :string
    field :pr_number, :integer
    field :run_url, :string
    field :commit_message, :string
    field :release_notes, :string
    field :bundle_id, :string
    field :version, :string
    field :build_version, :string
    field :display_name, :string
    field :minimum_os, :string
    field :profile, :map
    field :icon_key, :string
    field :ready_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def states, do: @states

  def create_changeset(build, attrs) do
    build
    |> cast(attrs, [
      :idempotency_key,
      :commit_sha,
      :branch,
      :pr_number,
      :run_url,
      :commit_message,
      :release_notes
    ])
    |> validate_required([:idempotency_key])
    |> validate_length(:idempotency_key, max: 200)
    |> validate_format(:commit_sha, ~r/^[0-9a-f]{7,64}$/)
    |> validate_length(:branch, max: 255)
    |> validate_number(:pr_number, greater_than: 0)
    |> validate_format(:run_url, ~r{^https://})
    |> update_change(:commit_message, &truncate(&1, 4_000))
    |> update_change(:release_notes, &truncate(&1, 10_000))
  end

  def metadata_changeset(build, attrs) do
    cast(build, attrs, [
      :bundle_id,
      :version,
      :build_version,
      :display_name,
      :minimum_os,
      :profile,
      :icon_key
    ])
  end

  defp truncate(nil, _), do: nil
  defp truncate(text, max), do: String.slice(text, 0, max)
end
