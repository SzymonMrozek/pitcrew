defmodule BuildDistro.Workers.Retention do
  @moduledoc """
  Deletes the files of old builds. The newest ready build of every branch is
  kept regardless of age, so `latest` links keep working.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  alias BuildDistro.Builds

  @impl Oban.Worker
  def perform(_job) do
    days = Application.fetch_env!(:build_distro, :retention)[:days]

    DateTime.utc_now()
    |> DateTime.add(-days, :day)
    |> Builds.expirable_builds()
    |> Enum.each(fn build -> {:ok, _} = Builds.expire(build) end)
  end
end
