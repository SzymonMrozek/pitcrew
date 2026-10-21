defmodule BuildDistro.Repo do
  use Ecto.Repo,
    otp_app: :build_distro,
    adapter: Ecto.Adapters.SQLite3
end
