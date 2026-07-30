defmodule Eva.Coding.SessionTest do
  use ExUnit.Case, async: false

  alias Eva.Coding.Session
  alias Eva.MCP.Events

  defp build_session_config(attrs \\ []) do
    %Session.SessionConfig{
      cwd: File.cwd!(),
      storage: fake_storage(),
      model: "",
      provider_config: fake_provider_config(),
      listener_pid: Keyword.get(attrs, :listener_pid)
    }
  end

  # Cleaned up because `unique_integer/0` restarts from the same values on each VM
  # boot: a leftover transcript would otherwise be replayed into the next run's test.
  defp fake_storage do
    path =
      Path.join(System.tmp_dir!(), "session_test_#{System.unique_integer([:positive])}.jsonl")

    on_exit(fn -> File.rm_rf!(path) end)
    Eva.Agent.Session.Storage.Jsonl.new(path)
  end

  defp fake_provider_config do
    %Eva.AI.Config.OpenAICompatible{
      base_url: "http://localhost:1/v1",
      provider_name: "test"
    }
  end

  describe "append_mcp_toggle/3" do
    alias Eva.Agent.Session.State, as: SessionState
    alias Eva.Agent.Session.Storage

    test "writes an entry that replays back as an override" do
      config = build_session_config()
      state = build_state(config: config)

      Session.append_mcp_toggle(state, "ctx7", false)

      entries = Storage.read_all(config.storage)
      leaf = SessionState.latest_leaf_entry(entries)

      overrides =
        entries |> SessionState.from_entries(leaf.entry_id) |> SessionState.mcp_overrides()

      assert overrides == %{"ctx7" => false}
    end

    # The leaf is what puts the entry on the branch replayed at resume — without it
    # `path_to_entry/2` walks straight past the toggle.
    test "keeps successive toggles on the replayed branch, last one winning" do
      config = build_session_config()

      state =
        build_state(config: config)
        |> Session.append_mcp_toggle("ctx7", false)
        |> Session.append_mcp_toggle("other", false)
        |> Session.append_mcp_toggle("ctx7", true)

      entries = Storage.read_all(config.storage)
      leaf = SessionState.latest_leaf_entry(entries)

      overrides =
        entries |> SessionState.from_entries(leaf.entry_id) |> SessionState.mcp_overrides()

      assert overrides == %{"ctx7" => true, "other" => false}
      assert state.last_parent_id == leaf.entry_id
    end

    test "flushes pending initial entries so the toggle has a parent in the file" do
      config = build_session_config()
      info = Eva.Agent.Session.Entries.SessionInfo.new(%{cwd: "/tmp"})

      state =
        build_state(config: config, pending_initial_entries: [info], last_parent_id: info.id)

      state = Session.append_mcp_toggle(state, "ctx7", false)

      assert state.pending_initial_entries == []

      entries = Storage.read_all(config.storage)
      assert Enum.any?(entries, &(&1.id == info.id))

      toggle = Enum.find(entries, &(&1.type == "custom"))
      assert toggle.parent_id == info.id
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
          mcp: %Eva.MCP.SessionServers{},
          config: config,
          provider_config: config.provider_config
        ],
        attrs
      )
    )
  end
end
