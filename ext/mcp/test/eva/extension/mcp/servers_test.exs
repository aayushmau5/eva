defmodule Eva.Extension.MCP.ServersTest do
  use ExUnit.Case, async: false

  alias Eva.Agent.Tools
  alias Eva.Extension.MCP.Config.Paths
  alias Eva.Extension.MCP.{Config, Events, Servers, ToolAdapter}

  defmodule MockMCPClient do
    @moduledoc "Stands in for a live client so tests never spawn a real server."
    use GenServer

    def start_link({config, tools}) do
      GenServer.start_link(__MODULE__, {config, tools})
    end

    @impl true
    def init({config, tools}) do
      Registry.register(Eva.Extension.MCP.Registry, {config.scope_dir, config.name}, nil)
      {:ok, tools}
    end

    @impl true
    def handle_call(:list_tools, _from, tools), do: {:reply, tools, tools}

    def handle_call(:snapshot, _from, tools),
      do: {:reply, %{status: :connected, tools: tools}, tools}
  end

  defp unique_name, do: "test_#{System.unique_integer([:positive])}"

  defp build_config(attrs \\ []) do
    struct!(
      Config,
      Keyword.merge(
        [
          scope_dir: :global,
          name: unique_name(),
          type: :stdio,
          enabled: true,
          config: %Config.Stdio{command: "echo", args: []}
        ],
        attrs
      )
    )
  end

  defp register_mock_client(config, tools) do
    {:ok, _pid} = MockMCPClient.start_link({config, tools})
  end

  # Bypasses `new/2` so a test can set up any combination of config, override and
  # snapshot without touching the filesystem or starting anything.
  defp build(attrs) do
    struct(Servers, Keyword.merge([servers: [], overrides: %{}, snapshots: %{}], attrs))
  end

  defp mktmp do
    dir = Path.join(System.tmp_dir!(), "session_servers_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp write_mcp_json(dir, servers) do
    File.write!(Path.join(dir, "mcp.json"), JSON.encode!(%{"mcpServers" => servers}))
    %Paths{home: dir, cwd: dir}
  end

  describe "new/2" do
    test "returns a snapshot for a server it started" do
      paths =
        mktmp()
        |> write_mcp_json(%{"echo_server" => %{"type" => "stdio", "command" => "echo"}})

      mcp = Servers.new(paths)

      assert %{"echo_server" => snapshot} = mcp.snapshots
      assert snapshot.server_name == "echo_server"
      assert snapshot.scope_dir == :global
      assert snapshot.status in [:connecting, :connected, :failed]
    end

    test "keeps disabled servers in the list but does not start them" do
      paths =
        mktmp()
        |> write_mcp_json(%{
          "off" => %{"type" => "stdio", "command" => "echo", "enabled" => false}
        })

      mcp = Servers.new(paths)

      assert [%Config{name: "off", enabled: false}] = mcp.servers
      assert mcp.snapshots == %{}
    end

    test "a replayed override beats the config file" do
      paths =
        mktmp()
        |> write_mcp_json(%{"srv" => %{"type" => "stdio", "command" => "echo"}})

      mcp = Servers.new(paths, %{"srv" => false})

      assert mcp.snapshots == %{}
      assert [%Config{name: "srv", enabled: true}] = mcp.servers
    end

    # A bad command is not a crash — the client starts and parks in :failed.
    test "survives a server whose command does not exist" do
      paths =
        mktmp()
        |> write_mcp_json(%{"bad" => %{"type" => "stdio", "command" => "nonexistent_xyz"}})

      assert %{"bad" => _snapshot} = Servers.new(paths).snapshots
    end
  end

  describe "tools/1" do
    test "returns nothing without servers or clients" do
      assert Servers.tools(build(servers: [])) == []
      assert Servers.tools(build(servers: [build_config()])) == []
    end

    test "adapts the tools of a running client" do
      config = build_config()
      register_mock_client(config, [%{name: "search", description: "web", input_schema: %{}}])

      assert [%Tools.AgentTool{} = tool] = Servers.tools(build(servers: [config]))
      assert tool.name == ToolAdapter.tool_name(config.name, "search")
      assert tool.description == "web"
    end

    test "collects across servers, skipping ones with no client" do
      dead = build_config()
      alive = build_config()
      register_mock_client(alive, [%{name: "live", description: nil, input_schema: %{}}])

      assert [tool] = Servers.tools(build(servers: [dead, alive]))
      assert tool.name == ToolAdapter.tool_name(alive.name, "live")
    end

    test "skips a server disabled in config even while its client runs" do
      config = build_config(enabled: false)
      register_mock_client(config, [%{name: "hidden", description: nil, input_schema: %{}}])

      assert Servers.tools(build(servers: [config])) == []
    end

    # Clients are registered process-wide, so another session may be running the one
    # this session disabled — `whereis/1` alone would leak its tools back in.
    test "skips a server disabled by a session override" do
      config = build_config()
      register_mock_client(config, [%{name: "hidden", description: nil, input_schema: %{}}])

      mcp = build(servers: [config], overrides: %{config.name => false})

      assert Servers.tools(mcp) == []
    end

    test "an override re-enables a server disabled in config" do
      config = build_config(enabled: false)
      register_mock_client(config, [%{name: "shown", description: nil, input_schema: %{}}])

      mcp = build(servers: [config], overrides: %{config.name => true})

      assert [tool] = Servers.tools(mcp)
      assert tool.name == ToolAdapter.tool_name(config.name, "shown")
    end
  end

  describe "list/1" do
    test "reports enabled and disabled servers side by side" do
      on = build_config(name: "on")
      off = build_config(name: "off", enabled: false)

      mcp =
        build(
          servers: [on, off],
          snapshots: %{"on" => %{status: :connected, tools: [%{name: "t"}]}}
        )

      assert [on_info, off_info] = Servers.list(mcp)

      assert %{status: :connected, tool_count: 1, config_enabled: true} = on_info
      assert on_info.session_enabled == nil

      assert %{status: :disabled, tool_count: 0, tools: [], config_enabled: false} = off_info
    end

    test "separates the config default from the session override" do
      config = build_config(name: "srv")
      mcp = build(servers: [config], overrides: %{"srv" => false})

      assert [%{config_enabled: true, session_enabled: false, status: :disabled}] =
               Servers.list(mcp)
    end

    # No snapshot for a server we believe is enabled means it never started.
    test "reports an enabled server with no snapshot as failed" do
      assert [%{status: :failed}] = Servers.list(build(servers: [build_config()]))
    end
  end

  describe "set_enabled/4 - :session" do
    test "disables a server, records the override, and hides its tools" do
      config = build_config()
      register_mock_client(config, [%{name: "tool", description: nil, input_schema: %{}}])
      mcp = build(servers: [config], snapshots: %{config.name => %{status: :connected}})

      assert {:ok, mcp} = Servers.set_enabled(mcp, config.name, false, :session)

      assert mcp.overrides == %{config.name => false}
      assert Servers.tools(mcp) == []
      refute Map.has_key?(mcp.snapshots, config.name)
    end

    test "re-enabling restores the snapshot and the tools" do
      config = build_config(enabled: false)
      register_mock_client(config, [%{name: "tool", description: nil, input_schema: %{}}])

      assert {:ok, mcp} =
               Servers.set_enabled(build(servers: [config]), config.name, true, :session)

      assert mcp.snapshots[config.name].status == :connected
      assert length(Servers.tools(mcp)) == 1
    end

    test "leaves the config file alone" do
      paths = write_mcp_json(mktmp(), %{"srv" => %{"type" => "stdio", "command" => "echo"}})
      mcp = Servers.new(paths)

      assert {:ok, _mcp} = Servers.set_enabled(mcp, "srv", false, :session)

      assert {[%Config{enabled: true}], []} = Config.parse(paths)
    end

    test "returns :not_found for an unknown server" do
      assert Servers.set_enabled(build(servers: []), "nope", false, :session) ==
               {:error, :not_found}
    end
  end

  describe "set_enabled/4 - :persist" do
    setup do
      paths = write_mcp_json(mktmp(), %{"ctx7" => %{"type" => "stdio", "command" => "echo"}})
      %{paths: paths, mcp: Servers.new(paths)}
    end

    test "writes enabled: false back to the file it came from", %{mcp: mcp, paths: paths} do
      assert {:ok, mcp} = Servers.set_enabled(mcp, "ctx7", false, :persist)

      assert {[%Config{enabled: false}], []} = Config.parse(paths)
      # the in-memory config is swapped too, so the next prompt agrees with the file
      assert [%Config{enabled: false}] = mcp.servers
      assert [%{status: :disabled}] = Servers.list(mcp)
    end

    # A leftover override would silently outrank the file the user just wrote.
    test "clears any session override for that server", %{mcp: %Servers{} = mcp} do
      mcp = %Servers{mcp | overrides: %{"ctx7" => false}}

      assert {:ok, mcp} = Servers.set_enabled(mcp, "ctx7", true, :persist)

      assert mcp.overrides == %{}
      assert [%{session_enabled: nil}] = Servers.list(mcp)
    end

    test "reports a write failure without changing state", %{mcp: %Servers{} = mcp} do
      absent = build_config(name: "absent-from-file")
      mcp = %Servers{mcp | servers: mcp.servers ++ [absent]}

      assert Servers.set_enabled(mcp, "absent-from-file", false, :persist) ==
               {:error, :not_found}
    end
  end

  describe "apply_event/2" do
    test "ServerConnected fills in status and version, leaving other keys alone" do
      mcp = build(snapshots: %{"srv" => %{status: :connecting, tools: []}})

      event = %Events.ServerConnected{
        server_name: "srv",
        scope_dir: :global,
        server_version: "1.2.3",
        protocol_version: "2025-06-18",
        capabilities: %{tools: %{supported: true}}
      }

      mcp = Servers.apply_event(mcp, event)

      assert mcp.snapshots["srv"].status == :connected
      assert mcp.snapshots["srv"].server_version == "1.2.3"
      assert mcp.snapshots["srv"].tools == []
    end

    test "ToolsDiscovered replaces the tool list" do
      mcp = build(snapshots: %{"srv" => %{status: :connected, tools: []}})
      tools = [%{name: "search", description: nil, input_schema: %{}}]

      mcp =
        Servers.apply_event(mcp, %Events.ToolsDiscovered{
          server_name: "srv",
          scope_dir: :global,
          tools: tools
        })

      assert mcp.snapshots["srv"].tools == tools
    end

    test "ServerDisconnected mirrors the client's :failed status" do
      mcp = build(snapshots: %{"srv" => %{status: :connected}})

      mcp =
        Servers.apply_event(mcp, %Events.ServerDisconnected{
          server_name: "srv",
          scope_dir: :global,
          reason: :process_exit
        })

      assert mcp.snapshots["srv"].status == :failed
    end

    # A `:request`-phase error is transient and the client stays up.
    test "ServerError leaves status alone" do
      mcp = build(snapshots: %{"srv" => %{status: :connected}})

      mcp =
        Servers.apply_event(mcp, %Events.ServerError{
          server_name: "srv",
          scope_dir: :global,
          error: "boom",
          phase: :request
        })

      assert mcp.snapshots["srv"].status == :connected
    end

    # A disabled server is dropped from snapshots; an event still in flight from
    # another session's client must not put it back.
    test "ignores events for servers this session is not tracking" do
      mcp = build(snapshots: %{})

      mcp =
        Servers.apply_event(mcp, %Events.ServerConnected{
          server_name: "ghost",
          scope_dir: :global
        })

      assert mcp.snapshots == %{}
    end

    test "every event module is handled without crashing" do
      mcp = build(snapshots: %{"srv" => %{status: :connected}})

      for mod <- Events.modules() do
        assert %Servers{} =
                 Servers.apply_event(mcp, struct(mod, server_name: "srv"))
      end
    end
  end
end
