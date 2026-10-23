import Config

vapid = for name <- ~w(VAPID_PUBLIC_KEY VAPID_PRIVATE_KEY VAPID_SUBJECT), do: System.get_env(name)

if Enum.any?(vapid, &(&1 not in [nil, ""])) do
  [public, private, subject] = vapid
  contact = URI.parse(subject || "")

  valid_contact? =
    (contact.scheme == "mailto" and is_binary(contact.path) and
       String.contains?(contact.path, "@")) or
      (contact.scheme == "https" and is_binary(contact.host) and contact.host != "")

  with {:ok, public_bytes} when byte_size(public_bytes) == 65 <-
         Base.url_decode64(public || "", padding: false),
       {:ok, private_bytes} when byte_size(private_bytes) == 32 <-
         Base.url_decode64(private || "", padding: false),
       {^public_bytes, _} <- :crypto.generate_key(:ecdh, :prime256v1, private_bytes),
       true <- valid_contact? do
    config :web_push, :vapid, public_key: public, private_key: private, subject: subject
  else
    _ ->
      raise "Set VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY and VAPID_SUBJECT to a valid matching keypair and contact URL"
  end
end

if System.get_env("PHX_SERVER") do
  config :build_distro, BuildDistroWeb.Endpoint, server: true
end

config :build_distro, BuildDistroWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  require_env = fn name ->
    System.get_env(name) || raise "environment variable #{name} is missing"
  end

  config :build_distro, BuildDistro.Repo,
    database: System.get_env("DATABASE_PATH", "/data/build_distro.db"),
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "5"))

  public_url = URI.parse(require_env.("PUBLIC_URL"))

  config :build_distro, BuildDistroWeb.Endpoint,
    url: [host: public_url.host, port: public_url.port, scheme: public_url.scheme],
    http: [ip: {0, 0, 0, 0}],
    secret_key_base: require_env.("SECRET_KEY_BASE")

  config :build_distro, :storage,
    bucket: require_env.("S3_BUCKET"),
    endpoint: require_env.("S3_ENDPOINT"),
    region: System.get_env("S3_REGION", "auto"),
    access_key_id: require_env.("S3_ACCESS_KEY_ID"),
    secret_access_key: require_env.("S3_SECRET_ACCESS_KEY")

  # GitHub logins that may sign in as admins, comma-separated.
  config :build_distro,
         :admin_github_logins,
         "ADMIN_GITHUB_LOGINS" |> System.get_env("") |> String.split(~r/[,\s]+/, trim: true)

  # A GitHub OAuth App with the callback https://<host>/auth/github/callback.
  config :build_distro, :github_oauth,
    client_id: System.get_env("GITHUB_CLIENT_ID"),
    client_secret: System.get_env("GITHUB_CLIENT_SECRET")

  config :build_distro, :retention,
    days: String.to_integer(System.get_env("RETENTION_DAYS", "30"))
end
