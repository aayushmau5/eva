defmodule Eva.MCPNodeTest do
  @moduledoc """
  MCP as a project extension: registered, started as its own OS process, announcing itself.

  Nothing here is simulated. `mix eva.ext.start` really runs `mix run --no-halt` in
  `ext/mcp`, that VM really brings up distribution and joins, and the session really talks
  to it across the boundary. It is the slowest test in the tree and the only one that
  proves the whole path.
  """

  use ExUnit.Case, async: false

  @moduletag :distributed
  @moduletag timeout: 180_000

  alias Eva.Cluster
  alias Eva.Cluster.Distribution
  alias Eva.Coding.Resources
  alias Eva.Extension.{Package, Set}

  # A server that stays up and is findable in `ps`, so its cleanup can be checked. The
  # marker is the *duration*, because `sleep` wants a number and anything else exits at
  # once — which looks exactly like the cleanup working.
  @marker "918273645"

  setup do
    unless Node.alive?(), do: raise("needs a distributed VM — run `mix test.dist`")

    root = Path.join(System.tmp_dir!(), "mcp_node_#{System.unique_integer([:positive])}")
    cwd = Path.join(root, "project")
    File.mkdir_p!(Path.join(cwd, ".eva"))

    File.write!(
      Path.join([cwd, ".eva", "mcp.json"]),
      JSON.encode!(%{
        "mcpServers" => %{"marker" => %{"command" => "sleep", "args" => [@marker]}}
      })
    )

    resources = %Resources{root: root, cwd: cwd}

    # Publish where this VM is, so the child can find it the way a real one would.
    {:ok, _node} = Distribution.ensure_started(enabled?: true, root: root)
    start_supervised!({Eva.Cluster, allow: ["mcp"]})

    # Before as well as after: an extension node outliving the thing that started it is
    # the design working, but for a test it means a previous failure can leave one running
    # — and a live MCP client *reconnects*, so killing its server process only makes it
    # spawn another. The node has to go, not the symptom.
    stop_stray_mcp_nodes()
    kill_marker_processes()

    on_exit(fn ->
      stop_stray_mcp_nodes()
      kill_marker_processes()
      File.rm_rf!(root)
    end)

    %{root: root, cwd: cwd, resources: resources}
  end

  test "registered, started, announced, and usable from a session", %{
    resources: resources,
    cwd: cwd
  } do
    # 1. Register it. This records where it is and how to start it, and nothing else.
    assert {:ok, entry} = Package.add(resources, "ext/mcp")
    assert entry["name"] == "mcp"
    assert entry["start"] == ["mix", "run", "--no-halt"]
    assert Package.list(resources) == [{entry, :not_running}]

    # 2. Start it. A real OS process, detached, that outlives this call.
    :ok = Cluster.subscribe()
    assert {:ok, ^entry} = Package.start(resources, "mcp", eva_node: node())

    # Generous: the child may have to compile before it can announce.
    assert_receive {:cluster_member_up, member}, 120_000
    assert member.name == "mcp"
    assert member.node != node()
    assert [{^entry, :announced}] = Package.list(resources)

    # 3. A session picks it up, and its command runs over there.
    set = Set.load(resources, self(), %{cwd: cwd, model: "test"})

    assert "mcp" in set.order
    assert [%{name: "mcp", node: mcp_node}] = Set.list(set)
    assert mcp_node == member.node

    {:text, listing} = Set.run_command(set, "mcp", "")
    assert listing =~ "marker"

    # 4. The server it started is a real OS process, on the extension's node.
    wait_until(fn -> marker_processes() != [] end, 30_000)

    # 5. Stopping the node takes its servers with it — the leak this tier exists to
    #    prevent, checked rather than assumed.
    :ok = Package.stop(resources, "mcp")

    assert_receive {:cluster_member_down, %{name: "mcp"}}, 30_000

    wait_until(
      fn -> marker_processes() == [] end,
      30_000,
      fn -> "these survived the node stopping:\n" <> describe_markers() end
    )
  end

  defp describe_markers do
    case System.cmd("pgrep", ["-af", @marker], stderr_to_stdout: true) do
      {output, 0} -> output
      _none -> "(none)"
    end
  end

  defp marker_processes do
    case System.cmd("pgrep", ["-f", @marker], stderr_to_stdout: true) do
      {output, 0} -> output |> String.split("\n", trim: true)
      _none -> []
    end
  end

  defp kill_marker_processes do
    System.cmd("pkill", ["-f", @marker], stderr_to_stdout: true)
    :ok
  catch
    _kind, _reason -> :ok
  end

  # An extension node sets its name at runtime, so it is not in any command line and
  # `pkill` cannot find it. EPMD can: it lists every node registered on this host, running
  # or orphaned, connected to us or not.
  defp stop_stray_mcp_nodes do
    case :erl_epmd.names(~c"127.0.0.1") do
      {:ok, names} ->
        for {name, _port} <- names,
            name = List.to_string(name),
            String.starts_with?(name, "eva_ext_mcp") do
          node = :"#{name}@127.0.0.1"
          Node.connect(node)
          :erpc.cast(node, :init, :stop, [])
        end

        # Give them a moment to take their servers down with them.
        Process.sleep(500)

      _no_epmd ->
        :ok
    end
  end

  defp wait_until(fun, remaining, describe \\ fn -> "condition never became true" end) do
    cond do
      fun.() -> :ok
      remaining <= 0 -> flunk(describe.())
      true -> Process.sleep(100) && wait_until(fun, remaining - 100, describe)
    end
  end
end
