defmodule ArchTest.MixProject do
  use Mix.Project

  @version "0.1.2"
  @source_url "https://github.com/yoavgeva/arch_test"

  def project do
    [
      app: :arch_test,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "ArchTest",
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger, :tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      test: ["cmd --cd test/support/fixture_app mix compile --quiet", "test"]
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    "ArchUnit-inspired architecture testing library for Elixir. " <>
      "Write ExUnit tests that enforce dependency rules, layered architecture, " <>
      "modulith bounded contexts, and naming conventions."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      },
      maintainers: ["Yoav Geva"],
      files: ~w(lib guides cheatsheets .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extra_section: "GUIDES",
      extras: [
        "README.md",
        "guides/getting-started.md",
        "guides/layered-architecture.md",
        "guides/modulith-rules.md",
        "guides/freezing.md",
        "cheatsheets/arch_test.cheatmd",
        "CHANGELOG.md",
        "LICENSE"
      ],
      groups_for_extras: [
        Guides: [
          "guides/getting-started.md",
          "guides/layered-architecture.md",
          "guides/modulith-rules.md",
          "guides/freezing.md"
        ],
        Cheatsheets: [
          "cheatsheets/arch_test.cheatmd"
        ]
      ],
      groups_for_modules: [
        "Core DSL": [ArchTest, ArchTest.ModuleSet, ArchTest.Assertions],
        "Architecture Patterns": [ArchTest.Layers, ArchTest.Modulith],
        "Data Collection": [ArchTest.Collector, ArchTest.Pattern],
        "Advanced Features": [ArchTest.Freeze, ArchTest.Metrics, ArchTest.Conventions],
        Internals: [ArchTest.Rule, ArchTest.Violation]
      ]
    ]
  end
end
