defmodule LokiLoggerHandler.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/ausimian/loki_logger_handler"

  def project do
    [
      app: :loki_logger_handler,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_coverage: [tool: ExCoveralls],

      # Docs
      name: "LokiLoggerHandler",
      description: "An Elixir Logger handler for Grafana Loki",
      source_url: @source_url,
      docs: docs(),
      package: package(),
      aliases: aliases()
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.github": :test,
        precommit: :test
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {LokiLoggerHandler.Application, []}
    ]
  end

  defp deps do
    [
      {:cubdb, "~> 2.0"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.0"},
      {:plug, "~> 1.16", only: [:test, :dev]},
      {:bandit, "~> 1.6", only: [:test, :dev]},
      {:excoveralls, "~> 0.18", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:publisho, "~> 1.0", only: :dev, runtime: false},
      {:benchee, "~> 1.0", only: :dev}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md", "LICENSE"],
      source_ref: "#{@version}",
      source_url: @source_url,
      formatters: ["html"]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url
      },
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  def aliases do
    [
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "credo --strict",
        "test"
      ]
    ]
  end
end
