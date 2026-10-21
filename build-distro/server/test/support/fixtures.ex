defmodule BuildDistro.Fixtures do
  @moduledoc "Projects, IPAs and the CI side of the upload protocol."

  alias BuildDistro.{Builds, Projects}

  @fixtures Path.expand("../fixtures", __DIR__)

  def fixture_path(name), do: Path.join(@fixtures, name)

  def project_fixture(attrs \\ %{}) do
    slug = "app#{System.unique_integer([:positive])}"

    {:ok, {project, api_key}} =
      attrs
      |> Enum.into(%{"slug" => slug, "name" => "My App", "passcode" => "secret-passcode"})
      |> Projects.create_project()

    %{project: project, api_key: api_key}
  end

  @doc "An IPA built from the fixtures: binary Info.plist, signed-looking profile, crushed icon."
  def ipa_fixture(opts \\ []) do
    app = Keyword.get(opts, :app, "Payload/MyApp.app")

    files =
      Keyword.get(opts, :files, [
        {"#{app}/Info.plist", File.read!(fixture_path("Info.plist"))},
        {"#{app}/embedded.mobileprovision", File.read!(fixture_path("embedded.mobileprovision"))},
        {"#{app}/AppIcon60x60@2x.png", File.read!(fixture_path("AppIcon60x60@2x.png"))},
        {"#{app}/PlugIns/Widget.appex/Info.plist", "not the app's"},
        {"#{app}/MyApp", Keyword.get(opts, :binary, :crypto.strong_rand_bytes(2048))}
      ])

    entries = for {name, data} <- files, do: {String.to_charlist(name), data}
    {:ok, {_, zip}} = :zip.create(~c"app.ipa", entries, [:memory])
    zip
  end

  def start_attrs(artifacts, overrides \\ %{}) do
    Enum.into(overrides, %{
      "idempotency_key" => "run-#{System.unique_integer([:positive])}",
      "commit_sha" => "0123456789abcdef0123456789abcdef01234567",
      "branch" => "main",
      "commit_message" => "Add the thing\n\nLonger description.",
      "artifacts" =>
        Enum.map(artifacts, fn {kind, data} -> %{"kind" => kind, "size" => byte_size(data)} end)
    })
  end

  @doc "Uploads the given parts of an artifact the way the CI client does."
  def upload_parts(build, kind, data, numbers \\ :all) do
    artifact = Builds.artifact(build, kind)
    count = BuildDistro.Builds.Artifact.part_count(artifact)
    numbers = if numbers == :all, do: Enum.to_list(1..count), else: numbers
    {:ok, %{urls: urls}} = Builds.part_urls(build, kind, numbers)

    for {number, url} <- urls do
      offset = (number - 1) * artifact.part_size
      part = binary_part(data, offset, min(artifact.part_size, byte_size(data) - offset))
      %{status: 200} = Req.put!(url, body: part, retry: false, receive_timeout: 60_000)
      :ok = Builds.report_part(build, kind, number, byte_size(part))
    end

    :ok
  end

  @doc "Runs the whole upload: start, every part, complete."
  def upload_build(project, artifacts, overrides \\ %{}) do
    {:ok, build} = Builds.start_upload(project, start_attrs(artifacts, overrides))
    for {kind, data} <- artifacts, do: upload_parts(build, kind, data)
    {:ok, build} = Builds.complete(build)
    build
  end

  @doc "A ready build: uploaded and processed."
  def ready_build(project, overrides \\ %{}) do
    build = upload_build(project, [{"ipa", ipa_fixture()}], overrides)

    :ok =
      BuildDistro.Workers.ProcessBuild.perform(%Oban.Job{
        args: %{"build_id" => build.id},
        attempt: 1,
        max_attempts: 5
      })

    Builds.get_build!(build.id)
  end
end
