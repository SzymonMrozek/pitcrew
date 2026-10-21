import Config

# Digested asset names let browsers cache them forever and let LiveView notice
# a deploy that changed them. TLS ends at the Cloudflare Tunnel, which forwards
# plain HTTP.
config :build_distro, BuildDistroWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json",
  force_ssl: [rewrite_on: [:x_forwarded_proto], exclude: [hosts: ["localhost", "127.0.0.1"]]]

config :logger, level: :info
