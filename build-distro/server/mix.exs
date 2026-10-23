defmodule BuildDistro.MixProject do
  use Mix.Project

  def project do
    [
      app: :build_distro,
      version: "0.3.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      releases: [build_distro: [include_executables_for: [:unix]]]
    ]
  end

  def application do
    [
      mod: {BuildDistro.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.8.16"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:bandit, "~> 1.5"},
      {:oban, "~> 2.24"},
      {:req, "~> 0.7"},
      {:ex_aws, "~> 2.7"},
      {:ex_aws_s3, "~> 2.5"},
      {:sweet_xml, "~> 0.7"},
      {:web_push, "~> 0.1.0"},
      {:eqrcode, "~> 0.2"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "assets.vendor", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "assets.vendor": &vendor_assets/1,
      "assets.deploy": ["assets.vendor", "phx.digest"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["assets.vendor", "ecto.create --quiet", "ecto.migrate --quiet", "test"],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end

  # LiveView ships prebuilt browser bundles; serving them as they are avoids
  # a JavaScript toolchain.
  defp vendor_assets(_args) do
    target = Path.join(["priv", "static", "assets", "vendor"])
    File.mkdir_p!(target)

    for {dep, file} <- [phoenix: "phoenix.min.js", phoenix_live_view: "phoenix_live_view.min.js"] do
      source = Path.join([Mix.Project.deps_paths()[dep], "priv", "static", file])
      File.cp!(source, Path.join(target, file))
    end
  end
end
