defmodule LokiLoggerHandler.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/nickgunn/loki_logger_handler"

  def project do
    [
      app: :loki_logger_handler,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.json": :test
      ],

      # Docs
      name: "LokiLoggerHandler",
      description: "An Elixir Logger handler for Grafana Loki with persistent buffering",
      source_url: @source_url,
      docs: docs(),
      package: package()
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
      {:plug, "~> 1.16", only: :test},
      {:bandit, "~> 1.6", only: :test},
      {:excoveralls, "~> 0.18", only: :test},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:expublish, "~> 2.5", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "LokiLoggerHandler",
      extras: ["README.md", "CHANGELOG.md", "LICENSE"],
      source_ref: "#{@version}",
      source_url: @source_url,
      formatters: ["html"],
      groups_for_modules: [
        Core: [
          LokiLoggerHandler,
          LokiLoggerHandler.Handler
        ],
        Internal: [
          LokiLoggerHandler.Storage,
          LokiLoggerHandler.Sender,
          LokiLoggerHandler.LokiClient,
          LokiLoggerHandler.Formatter
        ],
        Testing: [
          LokiLoggerHandler.FakeLoki
        ]
      ]
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
end
