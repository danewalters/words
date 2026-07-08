defmodule Words.MixProject do
  use Mix.Project

  def project do
    [
      app: :words,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Words.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:req, "~> 0.6.2"},
      {:floki, "~> 0.38.4"},
      {:plug, "~> 1.16", only: :test}
    ]
  end
end
