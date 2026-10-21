import Config

config :build_distro, BuildDistro.Repo,
  database: Path.expand("../build_distro_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

config :build_distro, BuildDistroWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "PaOfMAjwC98gzUH1OcDdnyrroTQpoml+ayIW2WeQAGJbO3wbvsNTE4k52+BfJR78",
  server: false

config :build_distro, Oban, testing: :manual

# Matches test/s3/compose.yaml. Each test run uses its own bucket.
config :build_distro, :storage,
  bucket: "test-#{System.unique_integer([:positive])}",
  endpoint: System.get_env("TEST_S3_ENDPOINT", "http://127.0.0.1:8333"),
  region: "auto",
  access_key_id: "build-distro",
  secret_access_key: "build-distro-secret"

config :build_distro, :admin_github_logins, ["Admin-Login"]
config :build_distro, :github_oauth, client_id: "client-id", client_secret: "client-secret"
config :build_distro, :min_part_size, 5 * 1024 * 1024
config :build_distro, :passcode_iterations, 1_000

config :ex_aws, retries: [max_attempts: 1]

config :logger, level: :warning

config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  enable_expensive_runtime_checks: true,
  test_warnings: [missing_form_id: :raise]

config :phoenix, sort_verified_routes_query_params: true
