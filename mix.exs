defmodule Eva.MixProject do
  use Mix.Project

  def project do
    [
      app: :eva,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases()
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test, "test.all": :test]
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
      # TODO: fix this(probably by finch)
      #  hpax 1.0.3 VULNERABLE!
      #   EEF-CVE-2026-58226 (HIGH)
      #   aka: CVE-2026-58226, GHSA-jj2p-32j7-whj2
      #   Unauthenticated denial-of-service via unbounded HPACK integer decoding in hpax
      #   https://osv.dev/vulnerability/EEF-CVE-2026-58226
      # mime 2.0.7
      # mint 1.9.0 VULNERABLE!
      #   EEF-CVE-2026-56810 (HIGH)
      #   aka: CVE-2026-56810, GHSA-c59h-fq4p-r36r
      #   mint buffers an entire chunked response chunk in memory in Mint.HTTP1.decode_body/5
      #   https://osv.dev/vulnerability/EEF-CVE-2026-56810
      {:eva_core, path: "core"},
      {:finch, "~> 0.23"},
      {:typedstruct, "~> 0.5"},
      {:mime, "~> 2.0"},
      {:erlexec, "~> 2.0"}
    ]
  end

  defp aliases do
    [
      # A path dependency compiles with its parent but is otherwise its own project —
      # neither its tests nor its formatting are reached from here, so ask for both.
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format.all",
        "test.all"
      ],
      "format.all": [
        "format",
        "cmd --cd core mix format"
      ],
      "test.all": [
        "test",
        "test.dist",
        "cmd --cd core mix test"
      ],
      # Distributed tests need a named VM, and a VM cannot be named after it has booted
      # without breaking references already held to `nonode@nohost`.
      "test.dist": [
        "cmd elixir --name eva_test@127.0.0.1 -S mix test --only distributed"
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
