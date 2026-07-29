defmodule Eva.Coding.SessionTest do
  use ExUnit.Case, async: false

  alias Eva.Agent.Tools
  alias Eva.Coding.Session
  alias Eva.MCP.{Config, Events}

  defmodule MockMCPClient do
    use GenServer

    def start_link({config, tools}) do
      GenServer.start_link(__MODULE__, {config, tools})
    end

    @impl true
    def init({config, tools}) do
      Registry.register(Eva.MCP.Registry, {config.scope_dir, config.name}, nil)
      {:ok, tools}
    end

    @impl true
    def handle_call(:list_tools, _from, tools) do
      {:reply, tools, tools}
    end
  end

  defp unique_name, do: "test_#{System.unique_integer([:positive])}"

  defp build_mcp_config(attrs \\ []) do
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

  defp build_session_config(attrs \\ []) do
    %Session.SessionConfig{
      cwd: File.cwd!(),
      storage: fake_storage(),
      model: "",
      provider_config: fake_provider_config(),
      listener_pid: Keyword.get(attrs, :listener_pid)
    }
  end

  defp fake_storage do
    Eva.Agent.Session.Storage.Jsonl.new(
      Path.join(System.tmp_dir!(), "session_test_#{:erlang.unique_integer()}.jsonl")
    )
  end

  defp fake_provider_config do
    %Eva.AI.Config.OpenAICompatible{
      base_url: "http://localhost:1/v1",
      provider_name: "test"
    }
  end

  describe "mcp_tools/1" do
    test "returns empty list when there are no MCP servers" do
      state = build_state(mcp_servers: [])
      assert Session.mcp_tools(state) == []
    end

    test "returns empty list when no MCP clients are running" do
      config = build_mcp_config()
      state = build_state(mcp_servers: [config])
      assert Session.mcp_tools(state) == []
    end

    test "returns adapted tools from a running MCP client" do
      config = build_mcp_config()

      mcp_tools = [
        %{name: "search", description: "search the web", input_schema: %{type: "object"}}
      ]

      register_mock_client(config, mcp_tools)

      state = build_state(mcp_servers: [config])
      result = Session.mcp_tools(state)

      assert length(result) == 1
      tool = List.first(result)
      assert %Tools.AgentTool{} = tool
      assert tool.name == Eva.MCP.ToolAdapter.tool_name(config.name, "search")
      assert tool.description == "search the web"
      assert tool.input_schema == %{type: "object"}
    end

    test "returns tools from multiple running MCP clients" do
      config_a = build_mcp_config(name: "server_a")
      config_b = build_mcp_config(name: "server_b")

      tools_a = [%{name: "tool_a", description: "a", input_schema: %{}}]
      tools_b = [%{name: "tool_b", description: "b", input_schema: %{}}]

      register_mock_client(config_a, tools_a)
      register_mock_client(config_b, tools_b)

      state = build_state(mcp_servers: [config_a, config_b])
      result = Session.mcp_tools(state)

      assert length(result) == 2
      names = Enum.map(result, & &1.name)
      assert Eva.MCP.ToolAdapter.tool_name("server_a", "tool_a") in names
      assert Eva.MCP.ToolAdapter.tool_name("server_b", "tool_b") in names
    end

    test "skips clients that are not registered, returns tools from those that are" do
      config_dead = build_mcp_config(name: "dead_server")
      config_alive = build_mcp_config(name: "alive_server")
      tools = [%{name: "live_tool", description: "alive", input_schema: %{}}]
      register_mock_client(config_alive, tools)

      state = build_state(mcp_servers: [config_dead, config_alive])
      result = Session.mcp_tools(state)

      assert length(result) == 1
      assert List.first(result).name == Eva.MCP.ToolAdapter.tool_name("alive_server", "live_tool")
    end
  end

  describe "MCP event forwarding" do
    test "forwards ServerConnected event to listener" do
      event = %Events.ServerConnected{
        server_name: "my-server",
        scope_dir: :global,
        server_version: "1.0",
        protocol_version: "2025-06-18"
      }

      listener_pid = self()
      state = build_state(config: build_session_config(listener_pid: listener_pid))

      {:noreply, _} = Session.handle_info(event, state)
      assert_receive %Events.ServerConnected{server_name: "my-server"}
    end

    test "forwards ServerDisconnected event to listener" do
      event = %Events.ServerDisconnected{
        server_name: "my-server",
        scope_dir: :global,
        reason: :connection_lost
      }

      listener_pid = self()
      state = build_state(config: build_session_config(listener_pid: listener_pid))

      {:noreply, _} = Session.handle_info(event, state)
      assert_receive %Events.ServerDisconnected{reason: :connection_lost}
    end

    test "forwards ToolsDiscovered event to listener" do
      event = %Events.ToolsDiscovered{
        server_name: "srv",
        scope_dir: :global,
        tools: [%{name: "t1", description: "d", input_schema: %{}}]
      }

      listener_pid = self()
      state = build_state(config: build_session_config(listener_pid: listener_pid))

      {:noreply, _} = Session.handle_info(event, state)
      assert_receive %Events.ToolsDiscovered{server_name: "srv"}
    end

    test "forwards ServerError event to listener" do
      event = %Events.ServerError{
        server_name: "broken",
        scope_dir: :global,
        error: "something went wrong",
        phase: :spawn
      }

      listener_pid = self()
      state = build_state(config: build_session_config(listener_pid: listener_pid))

      {:noreply, _} = Session.handle_info(event, state)
      assert_receive %Events.ServerError{error: "something went wrong"}
    end

    test "forwards ServerLog event to listener" do
      event = %Events.ServerLog{
        server_name: "logger",
        scope_dir: :global,
        level: :warning,
        logger: "stderr",
        message: "deprecated API"
      }

      listener_pid = self()
      state = build_state(config: build_session_config(listener_pid: listener_pid))

      {:noreply, _} = Session.handle_info(event, state)
      assert_receive %Events.ServerLog{message: "deprecated API"}
    end

    test "forwards ToolsChanged event to listener" do
      event = %Events.ToolsChanged{
        server_name: "srv",
        scope_dir: :global,
        tools: [],
        added: [],
        removed: ["old_tool"]
      }

      listener_pid = self()
      state = build_state(config: build_session_config(listener_pid: listener_pid))

      {:noreply, _} = Session.handle_info(event, state)
      assert_receive %Events.ToolsChanged{removed: ["old_tool"]}
    end

    test "does not forward when no listener is configured" do
      event = %Events.ServerConnected{
        server_name: "no-listener-server",
        scope_dir: :global,
        server_version: "1.0",
        protocol_version: "2025-06-18"
      }

      state = build_state(config: build_session_config(listener_pid: nil))

      {:noreply, _} = Session.handle_info(event, state)

      refute_receive %Events.ServerConnected{}, 50
    end

    test "forwards ResourcesDiscovered event to listener" do
      event = %Events.ResourcesDiscovered{
        server_name: "res-srv",
        scope_dir: :global,
        resources: [%{uri: "file:///data.txt", name: "data"}],
        templates: []
      }

      listener_pid = self()
      state = build_state(config: build_session_config(listener_pid: listener_pid))

      {:noreply, _} = Session.handle_info(event, state)
      assert_receive %Events.ResourcesDiscovered{server_name: "res-srv"}
    end

    test "forwards PromptsDiscovered event to listener" do
      event = %Events.PromptsDiscovered{
        server_name: "prompt-srv",
        scope_dir: :global,
        prompts: [%{name: "greet", description: "say hi"}]
      }

      listener_pid = self()
      state = build_state(config: build_session_config(listener_pid: listener_pid))

      {:noreply, _} = Session.handle_info(event, state)
      assert_receive %Events.PromptsDiscovered{server_name: "prompt-srv"}
    end

    test "forwards AuthRequired event to listener" do
      event = %Events.AuthRequired{
        server_name: "auth-srv",
        scope_dir: :global,
        login_command: "mcp auth login auth-srv"
      }

      listener_pid = self()
      state = build_state(config: build_session_config(listener_pid: listener_pid))

      {:noreply, _} = Session.handle_info(event, state)
      assert_receive %Events.AuthRequired{login_command: "mcp auth login auth-srv"}
    end
  end

  describe "MCP events module list" do
    test "all event modules are recognized" do
      listener_pid = self()
      state = build_state(config: build_session_config(listener_pid: listener_pid))

      for mod <- Eva.MCP.Events.modules() do
        event = struct(mod)
        {:noreply, _} = Session.handle_info(event, state)
        assert_received %{__struct__: ^mod}
      end
    end
  end

  describe "subscribe_mcp_servers/1" do
    test "returns empty map for empty config list" do
      assert Session.subscribe_mcp_servers([]) == %{}
    end

    test "returns snapshot for successfully started client" do
      tmp = mktmp()

      write_mcp_json(tmp, "mcp.json", %{
        "mcpServers" => %{
          "echo_server" => %{
            "type" => "stdio",
            "command" => "echo",
            "args" => ["hello"]
          }
        }
      })

      resources = %Eva.Coding.Resources{root: tmp, cwd: tmp}
      {mcp_configs, _diagnostics} = Config.parse(resources)

      result = Session.subscribe_mcp_servers(mcp_configs)

      assert is_map(result)
      assert Map.has_key?(result, "echo_server")

      snapshot = Map.get(result, "echo_server")
      assert is_map(snapshot)
      assert snapshot.server_name == "echo_server"
      assert snapshot.scope_dir == :global
      assert snapshot.status in [:connecting, :connected, :failed]
    end

    test "handles invalid commands — client starts but status reflects failure" do
      tmp = mktmp()

      write_mcp_json(tmp, "mcp.json", %{
        "mcpServers" => %{
          "bad_server" => %{
            "type" => "stdio",
            "command" => "nonexistent_command_xyz_testing"
          }
        }
      })

      resources = %Eva.Coding.Resources{root: tmp, cwd: tmp}
      {mcp_configs, _diagnostics} = Config.parse(resources)

      result = Session.subscribe_mcp_servers(mcp_configs)

      assert is_map(result)
      assert Map.has_key?(result, "bad_server")
    end
  end

  defp build_state(attrs) do
    config = build_session_config()

    struct(
      Session,
      Keyword.merge(
        [
          provider_pid: self(),
          harness_pid: self(),
          session_state: nil,
          last_parent_id: nil,
          skills: [],
          prompt_templates: [],
          context_files: [],
          resource_diagnostics: [],
          command_registry: [],
          pending_initial_entries: [],
          config: config,
          provider_config: config.provider_config
        ],
        attrs
      )
    )
  end

  defp mktmp do
    dir = Path.join(System.tmp_dir!(), "eva_session_test_#{System.unique_integer()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp write_mcp_json(dir, filename, content) do
    path = Path.join(dir, filename)
    json = JSON.encode_to_iodata!(content) |> IO.iodata_to_binary()
    File.write!(path, json)
  end
end
