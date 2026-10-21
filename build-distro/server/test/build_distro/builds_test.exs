defmodule BuildDistro.BuildsTest do
  use BuildDistro.DataCase

  alias BuildDistro.{Builds, Storage}
  alias BuildDistro.Builds.Build
  alias BuildDistro.Workers.{ProcessBuild, Reconcile, Retention}

  setup do
    %{project: project} = project_fixture()
    %{project: project, ipa: ipa_fixture()}
  end

  describe "starting an upload" do
    test "creates a numbered build with one multipart upload per artifact", %{
      project: project,
      ipa: ipa
    } do
      {:ok, build} =
        Builds.start_upload(project, start_attrs([{"ipa", ipa}, {"dsyms", "dsym-bytes"}]))

      assert build.state == "uploading"
      assert build.number == 1
      assert Enum.map(build.artifacts, & &1.kind) == ["ipa", "dsyms"]
      assert Enum.all?(build.artifacts, & &1.upload_id)
    end

    test "returns the same build for the same idempotency key", %{project: project, ipa: ipa} do
      attrs = start_attrs([{"ipa", ipa}])
      {:ok, first} = Builds.start_upload(project, attrs)
      {:ok, second} = Builds.start_upload(project, attrs)

      assert second.id == first.id
      assert Builds.artifact(second, "ipa").upload_id == Builds.artifact(first, "ipa").upload_id
    end

    test "numbers builds per project", %{project: project, ipa: ipa} do
      {:ok, one} = Builds.start_upload(project, start_attrs([{"ipa", ipa}]))
      {:ok, two} = Builds.start_upload(project, start_attrs([{"ipa", ipa}]))
      %{project: other} = project_fixture()
      {:ok, other_build} = Builds.start_upload(other, start_attrs([{"ipa", ipa}]))

      assert {one.number, two.number, other_build.number} == {1, 2, 1}
    end

    test "starts over when the artifacts changed under the same key", %{
      project: project,
      ipa: ipa
    } do
      attrs = start_attrs([{"ipa", ipa}])
      {:ok, first} = Builds.start_upload(project, attrs)
      changed = Map.put(attrs, "artifacts", [%{"kind" => "ipa", "size" => byte_size(ipa) + 1}])
      {:ok, second} = Builds.start_upload(project, changed)

      assert second.id == first.id
      assert Builds.artifact(second, "ipa").size == byte_size(ipa) + 1
      refute Builds.artifact(second, "ipa").object_key == Builds.artifact(first, "ipa").object_key
    end

    test "validates the artifacts", %{project: project} do
      assert {:error, {:invalid, "artifacts", _}} = Builds.start_upload(project, start_attrs([]))

      assert {:error, {:invalid, "artifacts", _}} =
               Builds.start_upload(project, start_attrs([{"dsyms", "x"}]))

      assert {:error, {:invalid, "artifacts", _}} =
               Builds.start_upload(project, start_attrs([{"apk", "x"}]))

      assert {:error, %Ecto.Changeset{}} =
               Builds.start_upload(
                 project,
                 start_attrs([{"ipa", "x"}], %{"commit_sha" => "nope"})
               )
    end
  end

  test "part size keeps every upload within one ListParts page" do
    assert Builds.part_size(1) == 5 * 1024 * 1024
    big = 30 * 1024 * 1024 * 1024
    assert div(big + Builds.part_size(big) - 1, Builds.part_size(big)) <= 1000
  end

  describe "resuming" do
    test "part URLs skip the parts the bucket already has", %{project: project} do
      data = :crypto.strong_rand_bytes(Builds.part_size(1) + 10)
      {:ok, build} = Builds.start_upload(project, start_attrs([{"ipa", data}]))
      :ok = upload_parts(build, "ipa", data, [1])

      {:ok, result} = Builds.part_urls(build, "ipa", [1, 2])

      assert result.uploaded == [1]
      assert Map.keys(result.urls) == [2]
      assert result.part_count == 2
    end

    # R2 answers NoSuchUpload for an aborted upload, SeaweedFS an empty list;
    # either way CI can still finish.
    test "an upload aborted in the bucket can still be finished", %{project: project, ipa: ipa} do
      {:ok, build} = Builds.start_upload(project, start_attrs([{"ipa", ipa}]))
      artifact = Builds.artifact(build, "ipa")
      :ok = Storage.abort_multipart_upload(artifact.object_key, artifact.upload_id)

      :ok = upload_parts(build, "ipa", ipa)

      assert {:ok, %Build{state: "processing"}} = Builds.complete(build)
    end

    test "an upload the bucket no longer knows gets a new one", %{project: project, ipa: ipa} do
      {:ok, build} = Builds.start_upload(project, start_attrs([{"ipa", ipa}]))
      Repo.update_all(BuildDistro.Builds.Artifact, set: [upload_id: "gone"])

      {:ok, %{uploaded: [], urls: %{1 => _}}} = Builds.part_urls(build, "ipa", [1])

      refute Builds.artifact(Builds.get_build!(build.id), "ipa").upload_id == "gone"
    end

    test "rejects part numbers outside the artifact", %{project: project, ipa: ipa} do
      {:ok, build} = Builds.start_upload(project, start_attrs([{"ipa", ipa}]))

      assert {:error, {:invalid, "part_numbers", _}} = Builds.part_urls(build, "ipa", [2])
      assert {:error, {:invalid, "part_numbers", _}} = Builds.part_urls(build, "ipa", "1")
      assert {:error, :not_found} = Builds.part_urls(build, "dsyms", [1])
    end
  end

  describe "progress" do
    test "counts each part once, however often it's reported", %{project: project} do
      data = :crypto.strong_rand_bytes(Builds.part_size(1) + 1024)
      {:ok, build} = Builds.start_upload(project, start_attrs([{"ipa", data}]))

      :ok = Builds.report_part(build, "ipa", 2, 1024)
      :ok = Builds.report_part(build, "ipa", 2, 1024)

      assert Builds.artifact(Builds.get_build!(build.id), "ipa").uploaded_bytes == 1024
      assert {:error, {:invalid, _, _}} = Builds.report_part(build, "ipa", 3, 1)
      assert {:error, {:invalid, _, _}} = Builds.report_part(build, "ipa", "2", 1)
    end

    test "is broadcast to subscribers", %{project: project, ipa: ipa} do
      Builds.subscribe(project)
      {:ok, build} = Builds.start_upload(project, start_attrs([{"ipa", ipa}]))
      assert_receive {:build, id} when id == build.id

      :ok = Builds.report_part(build, "ipa", 1, 10)
      assert_receive {:build, ^id}
    end
  end

  describe "completing" do
    test "moves the build to processing and enqueues processing once", %{
      project: project,
      ipa: ipa
    } do
      build = upload_build(project, [{"ipa", ipa}, {"dsyms", "symbols"}])

      assert build.state == "processing"
      assert Enum.all?(build.artifacts, & &1.uploaded_at)
      assert {:ok, %Build{state: "processing"}} = Builds.complete(build)
      assert [_] = all_enqueued(worker: ProcessBuild)

      assert Storage.object_size(Builds.artifact(build, "ipa").object_key) ==
               {:ok, byte_size(ipa)}
    end

    test "names the missing parts", %{project: project} do
      data = :crypto.strong_rand_bytes(2 * Builds.part_size(1) + 5)
      {:ok, build} = Builds.start_upload(project, start_attrs([{"ipa", data}]))
      :ok = upload_parts(build, "ipa", data, [2])

      assert Builds.complete(build) == {:error, {:incomplete, "ipa", [1, 3]}}
    end

    test "survives a crash between completing in the bucket and recording it", %{
      project: project,
      ipa: ipa
    } do
      {:ok, build} = Builds.start_upload(project, start_attrs([{"ipa", ipa}]))
      :ok = upload_parts(build, "ipa", ipa)
      artifact = Builds.artifact(build, "ipa")
      {:ok, parts} = Storage.list_parts(artifact.object_key, artifact.upload_id)
      :ok = Storage.complete_multipart_upload(artifact.object_key, artifact.upload_id, parts)

      assert {:ok, %Build{state: "processing"}} = Builds.complete(build)
    end

    test "a failed build retried with its key starts over", %{project: project, ipa: ipa} do
      attrs = start_attrs([{"ipa", ipa}])
      {:ok, build} = Builds.start_upload(project, attrs)
      {:ok, _} = Builds.mark_failed(build, "boom")

      {:ok, retried} = Builds.start_upload(project, attrs)

      assert retried.id == build.id
      assert retried.state == "uploading"
      assert retried.failure_reason == nil
    end
  end

  describe "processing" do
    test "reads the IPA and makes the build ready", %{project: project} do
      build = ready_build(project)

      assert build.state == "ready"
      assert build.bundle_id == "com.example.myapp"
      assert build.version == "1.4.0"
      assert build.profile["device_count"] == 2
      assert {:ok, <<0x89, "PNG", _::binary>>} = Storage.read(build.icon_key)
      assert build.ready_at
    end

    test "fails the build for an upload that isn't an IPA", %{project: project} do
      build = upload_build(project, [{"ipa", "definitely not a zip"}])

      assert {:cancel, _} = perform_job(ProcessBuild, %{build_id: build.id})
      assert %Build{state: "failed", failure_reason: reason} = Builds.get_build!(build.id)
      assert reason =~ "valid IPA"
    end

    test "runs again safely after the build is ready", %{project: project} do
      build = ready_build(project)
      assert :ok = perform_job(ProcessBuild, %{build_id: build.id})
    end
  end

  describe "reconciling" do
    test "re-enqueues builds stuck in processing", %{project: project, ipa: ipa} do
      build = upload_build(project, [{"ipa", ipa}])
      Repo.delete_all(Oban.Job)

      :ok = perform_job(Reconcile, %{})
      assert_enqueued(worker: ProcessBuild, args: %{build_id: build.id})

      :ok = perform_job(Reconcile, %{})
      assert [_] = all_enqueued(worker: ProcessBuild)
    end

    test "fails uploads that stopped moving", %{project: project, ipa: ipa} do
      {:ok, build} = Builds.start_upload(project, start_attrs([{"ipa", ipa}]))
      {:ok, fresh} = Builds.start_upload(project, start_attrs([{"ipa", ipa}]))

      Repo.update_all(from(b in Build, where: b.id == ^build.id),
        set: [updated_at: DateTime.add(DateTime.utc_now(), -7, :hour)]
      )

      :ok = perform_job(Reconcile, %{})

      assert Builds.get_build!(build.id).state == "failed"
      assert Builds.get_build!(fresh.id).state == "uploading"
    end
  end

  describe "retention" do
    test "expires old builds but keeps the newest ready build of each branch", %{project: project} do
      old_main = ready_build(project, %{"branch" => "main"})
      newest_main = ready_build(project, %{"branch" => "main"})
      only_feature = ready_build(project, %{"branch" => "feature"})
      recent = ready_build(project, %{"branch" => "main"})
      long_ago = DateTime.add(DateTime.utc_now(), -60, :day)

      Repo.update_all(
        from(b in Build, where: b.id in ^[old_main.id, newest_main.id, only_feature.id]),
        set: [inserted_at: long_ago]
      )

      :ok = perform_job(Retention, %{})

      assert Builds.get_build!(old_main.id).state == "expired"
      assert Builds.get_build!(newest_main.id).state == "expired"
      assert Builds.get_build!(only_feature.id).state == "ready"
      assert Builds.get_build!(recent.id).state == "ready"

      assert Storage.object_size(Builds.artifact(old_main, "ipa").object_key) ==
               {:error, :not_found}
    end
  end
end
