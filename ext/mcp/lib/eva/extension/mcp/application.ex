defmodule Eva.Extension.MCP.Application do
  @moduledoc """
  Everything MCP needs to run, owned by MCP.

  These four used to be children of `Eva.Application` — the host started an HTTP pool, a
  task supervisor, a registry and a client supervisor on MCP's behalf, and had to know
  MCP existed to do it. They are here now, which is what "MCP is an extension" means in
  practice.

  Client processes live under this tree rather than under the extension's own process on
  purpose: a server is shared by every session using it, refcounted through `:pg`, and
  outlives any one session's extension instance.

  `Eva.Extension.Node` is what makes this VM an extension: it finds Eva, announces `mcp`,
  and keeps announcing across Eva restarts. `mix run --no-halt` here is the whole
  operational story — nothing starts this node but you.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Finch, name: Eva.Extension.MCP.Finch},
      {Task.Supervisor, name: Eva.Extension.MCP.TaskSupervisor},
      {Registry, keys: :unique, name: Eva.Extension.MCP.Registry},
      Eva.Extension.MCP.Supervisor,
      {Eva.Extension.Node, node_options()}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__.Supervisor)
  end

  # `config :eva_mcp, cluster: [eva_node: :"eva@host"]` overrides discovery, which is
  # occasionally useful and always useful in tests.
  defp node_options do
    Keyword.merge(
      [name: "mcp", module: Eva.Extension.MCP],
      Application.get_env(:eva_mcp, :cluster, [])
    )
  end
end
