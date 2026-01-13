defmodule LokiLoggerHandler.MixProject do
  use Mix.Project

  @version "0.1.1"
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
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.github": :test
      ],

      # Docs
      name: "LokiLoggerHandler",
      description: "An Elixir Logger handler for Grafana Loki",
      source_url: @source_url,
      docs: docs(),
      package: package(),
      aliases: aliases()
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
      {:plug, "~> 1.16", only: [:test, :dev]},
      {:bandit, "~> 1.6", only: [:test, :dev]},
      {:excoveralls, "~> 0.18", only: :test},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:expublish, "~> 2.5", only: :dev, runtime: false},
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
      "expublish.major": &expublish("expublish.major", &1),
      "expublish.minor": &expublish("expublish.minor", &1),
      "expublish.patch": &expublish("expublish.patch", &1),
      "expublish.stable": &expublish("expublish.stable", &1),
      "expublish.rc": &expublish("expublish.rc", &1),
      "expublish.beta": &expublish("expublish.beta", &1),
      "expublish.alpha": &expublish("expublish.alpha", &1)
    ]
  end

  defp expublish(task, args) do
    {branch, 0} = System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"])
    common = ["--tag-prefix", "", "--commit-prefix", "Version", "--branch", String.trim(branch)]

    if "--no-dry-run" in args do
      Mix.Task.run(task, common ++ args)
    else
      Mix.Task.run(task, ["--dry-run" | common] ++ args)
    end
  end
end
