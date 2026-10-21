defmodule BuildDistro.Builds.Artifact do
  use Ecto.Schema

  @kinds ~w(ipa dsyms)

  schema "artifacts" do
    belongs_to :build, BuildDistro.Builds.Build
    field :kind, :string
    field :filename, :string
    field :size, :integer
    field :part_size, :integer
    field :object_key, :string
    field :upload_id, :string
    field :uploaded_at, :utc_datetime_usec
    field :uploaded_bytes, :integer, virtual: true, default: 0

    timestamps(type: :utc_datetime_usec)
  end

  def kinds, do: @kinds

  def content_type("ipa"), do: "application/octet-stream"
  def content_type("dsyms"), do: "application/zip"

  def part_count(%__MODULE__{size: size, part_size: part_size}),
    do: max(1, div(size + part_size - 1, part_size))
end
