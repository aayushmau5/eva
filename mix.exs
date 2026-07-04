defmodule Eva.MixProject do
  use Mix.Project

  def project do
    [
      app: :eva,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Eva.Application, []}
    ]
  end

  defp deps do
    [
      {:finch, "~> 0.23"},
      {:typedstruct, "~> 0.5"}
    ]
  end

  defp aliases do
    [
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
