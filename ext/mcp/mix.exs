defmodule EvaMcp.MixProject do
  use Mix.Project

  def project do
    [
      app: :eva_mcp,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Eva.Extension.MCP.Application, []}
    ]
  end

  defp deps do
    [
      {:eva_core, path: "../../core"},
      {:finch, "~> 0.23"},
      {:erlexec, "~> 2.0"},
      {:typedstruct, "~> 0.5"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]
end
