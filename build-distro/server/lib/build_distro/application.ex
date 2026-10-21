defmodule BuildDistro.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      BuildDistroWeb.Telemetry,
      BuildDistro.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:build_distro, :ecto_repos), skip: skip_migrations?()},
      {Phoenix.PubSub, name: BuildDistro.PubSub},
      BuildDistro.RateLimiter,
      {Oban, Application.fetch_env!(:build_distro, Oban)},
      {Task, &reconcile_on_boot/0},
      BuildDistroWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: BuildDistro.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    BuildDistroWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations? do
    # SQLite migrations run on boot in a release.
    System.get_env("RELEASE_NAME") == nil
  end

  # Picks up work a crash interrupted without waiting for the next cron tick.
  defp reconcile_on_boot do
    if Application.fetch_env!(:build_distro, Oban)[:testing] != :manual do
      Oban.insert!(BuildDistro.Workers.Reconcile.new(%{}))
    end
  end
end
