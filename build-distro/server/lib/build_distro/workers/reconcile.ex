defmodule BuildDistro.Workers.Reconcile do
  @moduledoc """
  Repairs what a crash or a lost CI job leaves behind. Runs on boot and every
  few minutes, and does nothing when everything is consistent.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3, unique: [period: 60]

  alias BuildDistro.Builds
  alias BuildDistro.Workers.ProcessBuild

  @stalled_after_hours 6

  @impl Oban.Worker
  def perform(_job) do
    # Unique jobs make this a no-op for builds whose job still exists.
    for build_id <- Builds.processing_build_ids() do
      {:ok, _} = Oban.insert(ProcessBuild.new(%{build_id: build_id}))
    end

    Builds.fail_stalled_uploads(DateTime.add(DateTime.utc_now(), -@stalled_after_hours, :hour))
    :ok
  end
end
