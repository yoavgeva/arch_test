defmodule FixtureApp.MixProject do
  use Mix.Project

  def project do
    [
      app: :fixture_app,
      version: "0.1.0",
      elixir: "~> 1.15",
      build_path: "_build",
      deps_path: "deps",
      build_embedded: false,
      start_permanent: false,
      deps: []
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end
end
