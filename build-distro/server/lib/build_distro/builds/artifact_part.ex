defmodule BuildDistro.Builds.ArtifactPart do
  use Ecto.Schema

  @primary_key false
  schema "artifact_parts" do
    belongs_to :artifact, BuildDistro.Builds.Artifact
    field :number, :integer
    field :size, :integer
  end
end
