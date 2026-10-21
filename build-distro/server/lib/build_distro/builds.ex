defmodule BuildDistro.Builds do
  @moduledoc """
  The build state machine: `uploading → processing → ready`, or `failed`.

  Every function here is safe to call again with the same input. CI retries
  blindly, and the reconciler re-runs whatever a crash interrupted. The bucket
  decides which bytes exist; this module only records what it saw there.
  """

  import Ecto.Query

  alias BuildDistro.Builds.{Artifact, ArtifactPart, Build}
  alias BuildDistro.Projects.Project
  alias BuildDistro.{Repo, Storage}
  alias BuildDistro.Workers.ProcessBuild

  @max_parts 1_000
  @max_artifact_size 5 * 1024 * 1024 * 1024
  @max_urls_per_request 100
  @part_url_ttl 3_600

  ## Subscriptions

  def subscribe(%Project{id: project_id}),
    do: Phoenix.PubSub.subscribe(BuildDistro.PubSub, topic(project_id))

  defp broadcast(%Build{} = build) do
    Phoenix.PubSub.broadcast(BuildDistro.PubSub, topic(build.project_id), {:build, build.id})
    build
  end

  defp topic(project_id), do: "project:#{project_id}"

  ## Reading

  @doc "A bucket's builds, newest first."
  def list_builds(project, bucket, limit \\ 100) do
    Build
    |> where(project_id: ^project.id, bucket: ^bucket)
    |> where([b], b.state != "expired")
    |> order_by(desc: :number)
    |> limit(^limit)
    |> Repo.all()
    |> with_progress()
  end

  @doc "How many builds each bucket holds."
  def bucket_counts(project) do
    Repo.all(
      from b in Build,
        where: b.project_id == ^project.id and b.state != "expired",
        group_by: b.bucket,
        select: {b.bucket, count(b.id)}
    )
    |> Map.new()
  end

  @doc "The other builds of a build's pull request, newest first."
  def pull_request_builds(%Build{pr_number: nil}), do: []

  def pull_request_builds(%Build{} = build) do
    Repo.all(
      from b in Build,
        where:
          b.project_id == ^build.project_id and b.pr_number == ^build.pr_number and
            b.id != ^build.id and b.state != "expired",
        order_by: [desc: b.number],
        limit: 20
    )
  end

  @doc """
  The commit a main build's changelog starts after: that of the previous
  ready build on main. Commits of failed builds in between roll into the next
  one that testers can install.
  """
  def previous_main_commit(%Build{bucket: "main"} = build) do
    Repo.one(
      from b in Build,
        where:
          b.project_id == ^build.project_id and b.bucket == "main" and b.state == "ready" and
            b.number < ^build.number and not is_nil(b.commit_sha),
        order_by: [desc: b.number],
        limit: 1,
        select: b.commit_sha
    )
  end

  def previous_main_commit(_build), do: nil

  def get_build(project, number) do
    case Repo.get_by(Build, project_id: project.id, number: number) do
      nil -> nil
      build -> build |> List.wrap() |> with_progress() |> hd()
    end
  end

  def get_project_build(project, id) do
    case Repo.get_by(Build, project_id: project.id, id: id) do
      nil -> nil
      build -> build |> List.wrap() |> with_progress() |> hd()
    end
  end

  def get_build!(id), do: Build |> Repo.get!(id) |> List.wrap() |> with_progress() |> hd()

  def latest_ready(project, branch) do
    Repo.one(
      from b in Build,
        where: b.project_id == ^project.id and b.branch == ^branch and b.state == "ready",
        order_by: [desc: b.number],
        limit: 1
    )
  end

  defp with_progress(builds) do
    build_ids = Enum.map(builds, & &1.id)

    uploaded =
      Repo.all(
        from p in ArtifactPart,
          join: a in assoc(p, :artifact),
          where: a.build_id in ^build_ids and is_nil(a.uploaded_at),
          group_by: p.artifact_id,
          select: {p.artifact_id, sum(p.size)}
      )
      |> Map.new()

    artifacts =
      Repo.all(from a in Artifact, where: a.build_id in ^build_ids, order_by: [desc: a.kind])
      |> Enum.map(fn artifact ->
        bytes =
          if artifact.uploaded_at, do: artifact.size, else: Map.get(uploaded, artifact.id, 0)

        %{artifact | uploaded_bytes: min(bytes, artifact.size)}
      end)
      |> Enum.group_by(& &1.build_id)

    Enum.map(builds, &%{&1 | artifacts: Map.get(artifacts, &1.id, [])})
  end

  @doc "Upload progress from 0.0 to 1.0 across all artifacts."
  def progress(%Build{artifacts: artifacts}) when is_list(artifacts) do
    total = artifacts |> Enum.map(& &1.size) |> Enum.sum()
    done = artifacts |> Enum.map(& &1.uploaded_bytes) |> Enum.sum()
    if total == 0, do: 0.0, else: done / total
  end

  def artifact(%Build{artifacts: artifacts}, kind) when is_list(artifacts),
    do: Enum.find(artifacts, &(&1.kind == kind))

  ## Uploading

  @doc """
  Starts an upload, or returns the build an earlier call with the same
  idempotency key created. A failed build, or an upload whose artifacts
  changed, starts over with new multipart uploads.
  """
  def start_upload(%Project{} = project, attrs) do
    with {:ok, artifacts} <- validate_artifacts(attrs["artifacts"]),
         {:ok, {build, replaced}} <- find_or_create(project, attrs, artifacts),
         :ok <- abort_multipart_uploads(replaced),
         {:ok, build} <- ensure_multipart_uploads(build) do
      {:ok, broadcast(build)}
    end
  end

  defp validate_artifacts(artifacts) when is_list(artifacts) and artifacts != [] do
    artifacts
    |> Enum.reduce_while({:ok, []}, fn
      %{"kind" => kind, "size" => size} = artifact, {:ok, acc}
      when is_integer(size) and size > 0 and size <= @max_artifact_size ->
        if kind in Artifact.kinds() and not Enum.any?(acc, &(&1.kind == kind)) do
          filename = artifact["filename"] |> default_filename(kind) |> safe_filename()
          {:cont, {:ok, [%{kind: kind, size: size, filename: filename} | acc]}}
        else
          {:halt, {:error, {:invalid, "artifacts", "unknown or repeated kind #{inspect(kind)}"}}}
        end

      _, _ ->
        {:halt, {:error, {:invalid, "artifacts", "each needs a kind and a size up to 5 GiB"}}}
    end)
    |> case do
      {:ok, list} ->
        if Enum.any?(list, &(&1.kind == "ipa")),
          do: {:ok, Enum.reverse(list)},
          else: {:error, {:invalid, "artifacts", "an ipa is required"}}

      error ->
        error
    end
  end

  defp validate_artifacts(_), do: {:error, {:invalid, "artifacts", "is required"}}

  defp default_filename(nil, "ipa"), do: "app.ipa"
  defp default_filename(nil, "dsyms"), do: "dSYMs.zip"
  defp default_filename(name, _), do: name

  defp safe_filename(name) do
    name |> Path.basename() |> String.replace(~r/[^\w.\-]+/u, "_") |> String.slice(0, 120)
  end

  defp find_or_create(project, attrs, artifacts) do
    Repo.transact(fn ->
      case Repo.get_by(Build, project_id: project.id, idempotency_key: attrs["idempotency_key"]) do
        nil ->
          with {:ok, build} <- create_build(project, attrs, artifacts), do: {:ok, {build, []}}

        %Build{state: state} = build when state in ~w(processing ready) ->
          {:ok, {build, []}}

        %Build{state: "expired"} ->
          {:error, :expired}

        %Build{state: "failed"} = build ->
          restart(build, artifacts)

        %Build{state: "uploading"} = build ->
          existing = Repo.all(from a in Artifact, where: a.build_id == ^build.id)

          if same_artifacts?(existing, artifacts),
            do: {:ok, {build, []}},
            else: restart(build, artifacts)
      end
    end)
  end

  defp create_build(project, attrs, artifacts) do
    number =
      Repo.one(from b in Build, where: b.project_id == ^project.id, select: max(b.number)) || 0

    changeset = Build.create_changeset(%Build{project_id: project.id, number: number + 1}, attrs)

    changeset =
      Ecto.Changeset.put_change(
        changeset,
        :bucket,
        Build.bucket_for(Ecto.Changeset.apply_changes(changeset), project.main_branch)
      )

    with {:ok, build} <- Repo.insert(changeset),
         :ok <- insert_artifacts(build, artifacts) do
      {:ok, build}
    end
  end

  # Returns the replaced artifacts so their multipart uploads can be aborted
  # after the transaction, away from SQLite's write lock.
  defp restart(build, artifacts) do
    replaced = Repo.all(from a in Artifact, where: a.build_id == ^build.id)
    Repo.delete_all(from a in Artifact, where: a.build_id == ^build.id)

    with :ok <- insert_artifacts(build, artifacts),
         {:ok, build} <-
           build
           |> Ecto.Changeset.change(state: "uploading", failure_reason: nil, ready_at: nil)
           |> Repo.update() do
      {:ok, {build, replaced}}
    end
  end

  defp same_artifacts?(existing, requested) do
    key = fn list -> list |> Enum.map(&{&1.kind, &1.size}) |> Enum.sort() end
    key.(existing) == key.(requested)
  end

  # Keys get a random segment per attempt, so a retried upload, or IDs reused
  # after restoring an older database, never meet a stale object.
  defp insert_artifacts(build, artifacts) do
    attempt = Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

    Enum.each(artifacts, fn artifact ->
      Repo.insert!(%Artifact{
        build_id: build.id,
        kind: artifact.kind,
        filename: artifact.filename,
        size: artifact.size,
        part_size: part_size(artifact.size),
        object_key:
          "builds/#{build.project_id}/#{build.id}-#{attempt}/#{artifact.kind}/#{artifact.filename}"
      })
    end)
  end

  @doc false
  def part_size(size) do
    mib = 1024 * 1024
    needed = div(size + @max_parts - 1, @max_parts)
    max(min_part_size(), div(needed + mib - 1, mib) * mib)
  end

  # S3 requires at least 5 MiB for every part but the last. Larger parts mean
  # fewer requests; tests use the minimum to stay fast.
  defp min_part_size, do: Application.get_env(:build_distro, :min_part_size, 16 * 1024 * 1024)

  # Multipart uploads are created outside the database transaction so a slow
  # bucket never holds SQLite's write lock. An artifact without an upload ID
  # is picked up by the next call.
  defp ensure_multipart_uploads(%Build{state: "uploading"} = build) do
    Artifact
    |> where([a], a.build_id == ^build.id and is_nil(a.upload_id) and is_nil(a.uploaded_at))
    |> Repo.all()
    |> Enum.reduce_while(:ok, fn artifact, :ok ->
      case create_multipart_upload(artifact) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
    |> case do
      :ok -> {:ok, get_build!(build.id)}
      error -> error
    end
  end

  defp ensure_multipart_uploads(build), do: {:ok, get_build!(build.id)}

  defp create_multipart_upload(artifact) do
    with {:ok, upload_id} <-
           Storage.create_multipart_upload(
             artifact.object_key,
             Artifact.content_type(artifact.kind)
           ) do
      {updated, _} =
        Artifact
        |> where([a], a.id == ^artifact.id and is_nil(a.upload_id))
        |> Repo.update_all(set: [upload_id: upload_id, updated_at: DateTime.utc_now()])

      # A concurrent call won the race; its upload is the one CI will use.
      if updated == 0, do: Storage.abort_multipart_upload(artifact.object_key, upload_id)
      :ok
    end
  end

  @doc """
  Presigned URLs for the requested parts, and the parts the bucket already has
  so CI can skip them.
  """
  def part_urls(%Build{state: "uploading"} = build, kind, part_numbers)
      when is_list(part_numbers) do
    with {:ok, artifact} <- fetch_artifact(build, kind),
         :ok <- validate_part_numbers(artifact, part_numbers),
         {:ok, uploaded} <- uploaded_parts(artifact) do
      if is_nil(artifact.uploaded_at), do: record_parts(artifact, uploaded)
      touch(build)
      uploaded_numbers = MapSet.new(uploaded, & &1.number)

      urls =
        for number <- Enum.uniq(part_numbers), not MapSet.member?(uploaded_numbers, number) do
          {number,
           Storage.presigned_part_url(
             artifact.object_key,
             artifact.upload_id,
             number,
             @part_url_ttl
           )}
        end

      {:ok,
       %{
         uploaded: Enum.map(uploaded, & &1.number),
         urls: Map.new(urls),
         part_size: artifact.part_size,
         part_count: Artifact.part_count(artifact)
       }}
    end
  end

  def part_urls(%Build{state: "uploading"}, _kind, _numbers),
    do: {:error, {:invalid, "part_numbers", "must be a list"}}

  def part_urls(%Build{state: state}, _kind, _numbers), do: {:error, {:state, state}}

  defp validate_part_numbers(artifact, numbers) do
    count = Artifact.part_count(artifact)

    cond do
      length(numbers) > @max_urls_per_request ->
        {:error, {:invalid, "part_numbers", "at most #{@max_urls_per_request} at a time"}}

      Enum.all?(numbers, &(is_integer(&1) and &1 >= 1 and &1 <= count)) ->
        :ok

      true ->
        {:error, {:invalid, "part_numbers", "must be between 1 and #{count}"}}
    end
  end

  # An artifact completed by an earlier call has every part, and its multipart
  # upload no longer exists, so it must not look lost.
  defp uploaded_parts(%Artifact{uploaded_at: %DateTime{}} = artifact) do
    {:ok, Enum.map(1..Artifact.part_count(artifact), &%{number: &1, size: 0, etag: nil})}
  end

  # The bucket is the truth about which parts exist. When the multipart upload
  # is gone (aborted by a lifecycle rule, say), start a new one.
  defp uploaded_parts(artifact) do
    case Storage.list_parts(artifact.object_key, artifact.upload_id) do
      {:ok, parts} ->
        {:ok, parts}

      {:error, :no_such_upload} ->
        Repo.delete_all(from p in ArtifactPart, where: p.artifact_id == ^artifact.id)
        Repo.update_all(from(a in Artifact, where: a.id == ^artifact.id), set: [upload_id: nil])
        :ok = create_multipart_upload(%{artifact | upload_id: nil})
        {:ok, []}

      error ->
        error
    end
  end

  @doc "Records a finished part. Only drives the progress bar."
  def report_part(%Build{state: "uploading"} = build, kind, number, size)
      when is_integer(number) and is_integer(size) do
    with {:ok, artifact} <- fetch_artifact(build, kind),
         true <- number >= 1 and number <= Artifact.part_count(artifact),
         true <- size > 0 and size <= artifact.part_size do
      record_parts(artifact, [%{number: number, size: size}])
      touch(build)
      broadcast(build)
      :ok
    else
      false -> {:error, {:invalid, "part", "outside the artifact"}}
      error -> error
    end
  end

  def report_part(%Build{state: "uploading"}, _kind, _number, _size),
    do: {:error, {:invalid, "part_number and size", "must be integers"}}

  def report_part(%Build{state: state}, _kind, _number, _size), do: {:error, {:state, state}}

  defp record_parts(_artifact, []), do: :ok

  defp record_parts(artifact, parts) do
    rows = Enum.map(parts, &%{artifact_id: artifact.id, number: &1.number, size: &1.size})

    Repo.insert_all(ArtifactPart, rows,
      on_conflict: {:replace, [:size]},
      conflict_target: [:artifact_id, :number]
    )

    :ok
  end

  defp touch(build) do
    Repo.update_all(from(b in Build, where: b.id == ^build.id),
      set: [updated_at: DateTime.utc_now()]
    )
  end

  defp fetch_artifact(build, kind) do
    case Repo.get_by(Artifact, build_id: build.id, kind: kind) do
      %Artifact{upload_id: nil, uploaded_at: nil} -> {:error, {:state, "preparing"}}
      %Artifact{} = artifact -> {:ok, artifact}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Completes every multipart upload and moves the build to processing. Returns
  `{:error, {:incomplete, kind, missing_part_numbers}}` when parts are missing.
  """
  def complete(%Build{state: "uploading"} = build) do
    artifacts = Repo.all(from a in Artifact, where: a.build_id == ^build.id)

    with :ok <- complete_artifacts(artifacts),
         {:ok, build} <- start_processing(build) do
      {:ok, broadcast(get_build!(build.id))}
    end
  end

  def complete(%Build{state: state} = build) when state in ~w(processing ready),
    do: {:ok, get_build!(build.id)}

  def complete(%Build{state: state}), do: {:error, {:state, state}}

  defp complete_artifacts(artifacts) do
    Enum.reduce_while(artifacts, :ok, fn artifact, :ok ->
      case complete_artifact(artifact) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp complete_artifact(%Artifact{uploaded_at: %DateTime{}}), do: :ok

  defp complete_artifact(%Artifact{upload_id: nil} = artifact),
    do: {:error, {:incomplete, artifact.kind, Enum.to_list(1..Artifact.part_count(artifact))}}

  defp complete_artifact(artifact) do
    expected = 1..Artifact.part_count(artifact)

    case Storage.list_parts(artifact.object_key, artifact.upload_id) do
      {:ok, []} ->
        complete_from_object(artifact)

      {:ok, parts} ->
        missing = Enum.to_list(expected) -- Enum.map(parts, & &1.number)
        total = parts |> Enum.map(& &1.size) |> Enum.sum()

        cond do
          missing != [] ->
            {:error, {:incomplete, artifact.kind, missing}}

          total != artifact.size ->
            {:error,
             {:invalid, artifact.kind, "parts add up to #{total} bytes, not #{artifact.size}"}}

          true ->
            parts = Enum.filter(parts, &(&1.number in expected))

            case Storage.complete_multipart_upload(artifact.object_key, artifact.upload_id, parts) do
              :ok -> mark_uploaded(artifact)
              {:error, :no_such_upload} -> complete_from_object(artifact)
              error -> error
            end
        end

      {:error, :no_such_upload} ->
        complete_from_object(artifact)

      error ->
        error
    end
  end

  # The multipart upload is gone. Either an earlier call completed it, or it
  # was aborted; the object tells which.
  defp complete_from_object(artifact) do
    case Storage.object_size(artifact.object_key) do
      {:ok, size} when size == artifact.size ->
        mark_uploaded(artifact)

      {:ok, _} ->
        {:error, {:invalid, artifact.kind, "stored size doesn't match"}}

      {:error, :not_found} ->
        {:error, {:incomplete, artifact.kind, Enum.to_list(1..Artifact.part_count(artifact))}}

      error ->
        error
    end
  end

  defp mark_uploaded(artifact) do
    Repo.update_all(from(a in Artifact, where: a.id == ^artifact.id),
      set: [uploaded_at: DateTime.utc_now()]
    )

    Repo.delete_all(from p in ArtifactPart, where: p.artifact_id == ^artifact.id)
    :ok
  end

  defp start_processing(build) do
    Repo.transact(fn ->
      {updated, _} =
        Repo.update_all(from(b in Build, where: b.id == ^build.id and b.state == "uploading"),
          set: [state: "processing", updated_at: DateTime.utc_now()]
        )

      if updated == 1 do
        with {:ok, _job} <- Oban.insert(ProcessBuild.new(%{build_id: build.id})), do: {:ok, build}
      else
        {:ok, build}
      end
    end)
  end

  ## Changelog

  @doc "Stores the changelog CI sent; see `BuildDistro.Changelog.put/2`."
  def put_changelog(%Build{state: "expired"}, _params), do: {:error, {:state, "expired"}}

  def put_changelog(%Build{} = build, params) do
    with {:ok, build} <- BuildDistro.Changelog.put(build, params) do
      {:ok, broadcast(build)}
    end
  end

  ## Processing results

  def mark_ready(%Build{} = build, metadata) do
    transition(build, "processing", fn changeset ->
      changeset
      |> Build.metadata_changeset(metadata)
      |> Ecto.Changeset.change(state: "ready", ready_at: DateTime.utc_now())
    end)
  end

  def mark_failed(%Build{} = build, reason) do
    transition(build, ~w(uploading processing), fn changeset ->
      Ecto.Changeset.change(changeset,
        state: "failed",
        failure_reason: String.slice(reason, 0, 500)
      )
    end)
  end

  defp transition(build, from_states, change) do
    from_states = List.wrap(from_states)

    Repo.transact(fn ->
      case Repo.get(Build, build.id) do
        %Build{state: state} = current ->
          if state in from_states do
            current |> Ecto.Changeset.change() |> change.() |> Repo.update()
          else
            {:ok, current}
          end

        nil ->
          {:error, :not_found}
      end
    end)
    |> case do
      {:ok, updated} -> {:ok, broadcast(updated)}
      error -> error
    end
  end

  ## Maintenance

  @doc "Builds stuck in processing, for the reconciler."
  def processing_build_ids do
    Repo.all(from b in Build, where: b.state == "processing", select: b.id)
  end

  @doc "Fails uploads that haven't moved since `cutoff` and frees their parts."
  def fail_stalled_uploads(cutoff) do
    from(b in Build, where: b.state == "uploading" and b.updated_at < ^cutoff)
    |> Repo.all()
    |> Enum.each(fn build ->
      abort_uploads(build)
      mark_failed(build, "The upload stopped before it finished.")
    end)
  end

  @doc "Ready and failed builds older than `cutoff`, except the newest ready build of each branch."
  def expirable_builds(cutoff) do
    newest_per_branch =
      from b in Build,
        where: b.state == "ready",
        group_by: [b.project_id, b.branch],
        select: max(b.id)

    Repo.all(
      from b in Build,
        where: b.state in ["ready", "failed"] and b.inserted_at < ^cutoff,
        where: b.id not in subquery(newest_per_branch)
    )
  end

  @doc "Deletes a build's objects and keeps its row, so old links say it expired."
  def expire(%Build{} = build) do
    artifacts = Repo.all(from a in Artifact, where: a.build_id == ^build.id)

    with :ok <- delete_objects(artifacts, build) do
      Repo.delete_all(from a in Artifact, where: a.build_id == ^build.id)

      build
      |> Ecto.Changeset.change(state: "expired", icon_key: nil)
      |> Repo.update()
      |> case do
        {:ok, build} -> {:ok, broadcast(build)}
        error -> error
      end
    end
  end

  defp delete_objects(artifacts, build) do
    keys = Enum.map(artifacts, & &1.object_key) ++ List.wrap(build.icon_key)
    abort_uploads(build)

    Enum.reduce_while(keys, :ok, fn key, :ok ->
      case Storage.delete(key) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp abort_uploads(build) do
    from(a in Artifact, where: a.build_id == ^build.id)
    |> Repo.all()
    |> abort_multipart_uploads()
  end

  # Best effort: the bucket's lifecycle rule removes anything left behind.
  defp abort_multipart_uploads(artifacts) do
    for %Artifact{upload_id: upload_id, uploaded_at: nil} = artifact <- artifacts,
        upload_id != nil do
      Storage.abort_multipart_upload(artifact.object_key, upload_id)
    end

    :ok
  end
end
