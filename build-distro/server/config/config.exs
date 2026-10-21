import Config

config :build_distro,
  ecto_repos: [BuildDistro.Repo],
  generators: [timestamp_type: :utc_datetime_usec]

config :build_distro, BuildDistro.Repo,
  journal_mode: :wal,
  busy_timeout: 5_000,
  default_transaction_mode: :immediate

config :build_distro, BuildDistroWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: BuildDistroWeb.ErrorHTML, json: BuildDistroWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: BuildDistro.PubSub,
  live_view: [signing_salt: "wFxF6dmn"]

config :build_distro, Oban,
  engine: Oban.Engines.Lite,
  repo: BuildDistro.Repo,
  queues: [processing: 2, maintenance: 1],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 7 * 24 * 60 * 60},
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(10)},
    {Oban.Plugins.Cron,
     crontab: [
       {"*/5 * * * *", BuildDistro.Workers.Reconcile},
       {"17 3 * * *", BuildDistro.Workers.Retention}
     ]}
  ]

config :build_distro, :retention, days: 30

config :ex_aws,
  http_client: ExAws.Request.Req,
  json_codec: Jason,
  retries: [max_attempts: 5, base_backoff_in_ms: 200, max_backoff_in_ms: 5_000]

config :phoenix_live_view, root_tag_attribute: "phx-r"

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :build_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
