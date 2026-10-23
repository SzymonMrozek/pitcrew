defmodule BuildDistro.Workers.NotifyBuild do
  use Oban.Worker,
    queue: :notifications,
    max_attempts: 8,
    unique: [
      period: :infinity,
      keys: [:build_id, :subscription_id],
      states: [:available, :scheduled, :executing, :retryable, :completed]
    ]

  alias BuildDistro.{Builds, Notifications, Repo}
  alias BuildDistro.Notifications.Subscription

  @impl true
  def perform(%Oban.Job{args: %{"build_id" => build_id, "subscription_id" => subscription_id}}) do
    with %{state: "ready"} = build <- Repo.get(Builds.Build, build_id),
         %Subscription{} = subscription <- Repo.get(Subscription, subscription_id) do
      if Notifications.enabled?() do
        case Notifications.deliver(build, subscription) do
          :ok ->
            :ok

          {:error, :gone} ->
            Repo.delete(subscription)
            :ok

          error ->
            error
        end
      else
        {:snooze, 3600}
      end
    else
      _ -> :ok
    end
  end
end
