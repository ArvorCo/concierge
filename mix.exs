defmodule Concierge.MixProject do
  use Mix.Project

  def project do
    [
      app: :concierge,
      version: "2.0.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [
      mod: {Concierge.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp deps do
    [
      # JSON
      {:jason, "~> 1.4"},

      # SQLite (for wacli DB + tracking DB)
      {:esqlite, "~> 0.8"},

      # Time zones
      {:tzdata, "~> 1.1"},

      # Development
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.3", only: [:dev], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      test: ["test"]
    ]
  end
end
