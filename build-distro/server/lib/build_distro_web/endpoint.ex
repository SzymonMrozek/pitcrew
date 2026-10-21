defmodule BuildDistroWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :build_distro

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  # Testers stay signed in for half a year; BuildDistroWeb.Access rewrites the
  # cookie daily so the clock restarts while they keep using it.
  @session_options [
    store: :cookie,
    key: "_build_distro",
    signing_salt: "UUykIklW",
    encryption_salt: "q3Lr0dVb",
    same_site: "Lax",
    max_age: 180 * 24 * 60 * 60
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: :build_distro,
    gzip: not code_reloading?,
    only: BuildDistroWeb.static_paths(),
    raise_on_missing_only: code_reloading?

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :build_distro
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :json],
    pass: ["*/*"],
    length: 1_000_000,
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug BuildDistroWeb.Router
end
