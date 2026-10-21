import Config

config :build_distro, BuildDistro.Repo,
  database: Path.expand("../build_distro_dev.db", __DIR__),
  pool_size: 5,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

config :build_distro, BuildDistroWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "HKgMmffh7buv37zUFhNu01RoiSMcNVcdAnZaiUH2feI0rTdKoVEsI570wyT5McPH",
  watchers: []

# Matches test/s3/compose.yaml.
config :build_distro, :storage,
  bucket: "builds",
  endpoint: "http://127.0.0.1:8333",
  region: "auto",
  access_key_id: "build-distro",
  secret_access_key: "build-distro-secret"

config :build_distro, :admin_password, "admin"

config :build_distro, dev_routes: true

config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  debug_heex_annotations: true,
  debug_attributes: true,
  enable_expensive_runtime_checks: true
