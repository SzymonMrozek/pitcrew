defmodule BuildDistro.Projects.Project do
  use Ecto.Schema
  import Ecto.Changeset

  # Top-level paths the router owns, so no project can take them.
  @reserved_slugs ~w(admin api assets i health images favicon.ico robots.txt live)

  schema "projects" do
    field :slug, :string
    field :name, :string
    field :github_repo, :string
    field :passcode_hash, :string, redact: true
    field :passcode, :string, virtual: true, redact: true

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(project, attrs) do
    project
    |> cast(attrs, [:slug, :name, :github_repo, :passcode])
    |> validate_required([:slug, :name, :passcode])
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9-]{0,39}$/,
      message: "use lowercase letters, digits and dashes"
    )
    |> validate_exclusion(:slug, @reserved_slugs)
    |> validate_github_repo()
    |> validate_passcode()
    |> unique_constraint(:slug)
  end

  def update_changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :github_repo])
    |> validate_required([:name])
    |> validate_github_repo()
  end

  def passcode_changeset(project, attrs) do
    project
    |> cast(attrs, [:passcode])
    |> validate_required([:passcode])
    |> validate_passcode()
  end

  defp validate_github_repo(changeset) do
    validate_format(changeset, :github_repo, ~r{^[\w.-]+/[\w.-]+$}, message: "use owner/name")
  end

  defp validate_passcode(changeset) do
    changeset = validate_length(changeset, :passcode, min: 6, max: 128)

    case get_change(changeset, :passcode) do
      passcode when changeset.valid? and is_binary(passcode) ->
        put_change(changeset, :passcode_hash, BuildDistro.Secrets.hash_passcode(passcode))

      _ ->
        changeset
    end
  end
end
