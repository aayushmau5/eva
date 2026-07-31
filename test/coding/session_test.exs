defmodule Eva.Coding.SessionTest do
  use ExUnit.Case, async: false

  alias Eva.Coding.Session
  alias Eva.MCP.Events

  alias Eva.Agent.Session.{Storage, Entries}
  alias Eva.Agent.Session.State, as: SessionState
  alias Eva.Agent.Messages
  alias Eva.Coding.SessionIndexManager
  alias Eva.Coding.Paths

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

  describe "fork/2" do
    setup do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "fork_test_#{System.unique_integer([:positive, :monotonic])}"
        )

      File.mkdir_p!(tmp)

      paths = %Paths{home: tmp}
      manager = SessionIndexManager.new(paths)
      cwd = "/home/fork-project"

      # Create an index entry for the original session
      original =
        SessionIndexManager.create_index(manager, %{cwd: cwd, model: "gpt-4", title: "My session"})

      # Create storage with some messages
      storage = Eva.Agent.Session.Storage.Jsonl.new(original.session_path)

      # Write initial entries
      info = Entries.SessionInfo.new(%{cwd: cwd})
      model = Entries.ModelChange.new(%{parent_id: info.id, model: "gpt-4"})
      thinking = Entries.ThinkingLevelChange.new(%{parent_id: model.id, thinking_level: "medium"})

      # First user message
      user1 =
        Entries.Message.new(%{
          parent_id: thinking.id,
          message: %Messages.UserMessage{content: "First message"}
        })

      leaf1 = Entries.Leaf.new(%{parent_id: user1.id, entry_id: user1.id})

      # Assistant response
      asst1 =
        Entries.Message.new(%{
          parent_id: user1.id,
          message: %Messages.AssistantMessage{content: [%Messages.TextContent{text: "Hello!"}]}
        })

      leaf2 = Entries.Leaf.new(%{parent_id: asst1.id, entry_id: asst1.id})

      # Second user message (the fork point)
      user2 =
        Entries.Message.new(%{
          parent_id: asst1.id,
          message: %Messages.UserMessage{content: "Second message"}
        })

      leaf3 = Entries.Leaf.new(%{parent_id: user2.id, entry_id: user2.id})

      all_entries = [info, model, thinking, user1, leaf1, asst1, leaf2, user2, leaf3]

      Enum.each(all_entries, fn entry ->
        Storage.append(storage, entry)
      end)

      on_exit(fn -> File.rm_rf!(tmp) end)

      {:ok,
       tmp: tmp,
       manager: manager,
       original: original,
       storage: storage,
       entries: all_entries,
       user1: user1,
       user2: user2,
       asst1: asst1,
       leaf3: leaf3}
    end

    defp build_fork_state(attrs) do
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

    test "forks at a user message and returns {:ok, session_id, title, prefill_text}", ctx do
      state =
        build_fork_state(
          config: %Session.SessionConfig{
            cwd: "/home/fork-project",
            storage: ctx.storage,
            model: "gpt-4",
            provider_config: fake_provider_config(),
            session_id: ctx.original.id,
            session_index_manager: ctx.manager
          },
          last_parent_id: ctx.leaf3.entry_id
        )

      {:reply, result, _state} = Session.handle_call({:fork, ctx.user2.id}, nil, state)

      assert {:ok, forked_id, fork_title, prefill_text} = result
      assert is_binary(forked_id)
      assert forked_id != ctx.original.id
      assert fork_title == "fork: My session"
      assert prefill_text == "Second message"
    end

    test "forked JSONL contains entries up to but not including the fork point", ctx do
      state =
        build_fork_state(
          config: %Session.SessionConfig{
            cwd: "/home/fork-project",
            storage: ctx.storage,
            model: "gpt-4",
            provider_config: fake_provider_config(),
            session_id: ctx.original.id,
            session_index_manager: ctx.manager
          },
          last_parent_id: ctx.leaf3.entry_id
        )

      {:reply, {:ok, forked_id, _, _}, _state} =
        Session.handle_call({:fork, ctx.user2.id}, nil, state)

      # Retrieve the forked session index entry and read its transcript
      forked_entry = SessionIndexManager.get_session(ctx.manager, forked_id)
      refute is_nil(forked_entry)

      forked_entries =
        Storage.read_all(Eva.Agent.Session.Storage.Jsonl.new(forked_entry.session_path))

      # Should contain initial entries + user1 + leaf1 + asst1 + leaf2, but NOT user2 or leaf3
      entry_ids = MapSet.new(forked_entries, & &1.id)
      assert MapSet.member?(entry_ids, ctx.user1.id)
      assert MapSet.member?(entry_ids, ctx.asst1.id)
      refute MapSet.member?(entry_ids, ctx.user2.id)
      refute MapSet.member?(entry_ids, ctx.leaf3.id)
    end

    test "original session gets a Custom fork entry appended", ctx do
      state =
        build_fork_state(
          config: %Session.SessionConfig{
            cwd: "/home/fork-project",
            storage: ctx.storage,
            model: "gpt-4",
            provider_config: fake_provider_config(),
            session_id: ctx.original.id,
            session_index_manager: ctx.manager
          },
          last_parent_id: ctx.leaf3.entry_id
        )

      old_count = Storage.read_all(ctx.storage) |> length()

      {:reply, {:ok, forked_id, _, _}, _state} =
        Session.handle_call({:fork, ctx.user2.id}, nil, state)

      entries_after = Storage.read_all(ctx.storage)
      # Should have one extra Custom entry
      assert length(entries_after) == old_count + 1

      fork_custom = Enum.find(entries_after, &(&1.type == "custom" and &1.namespace == "fork"))
      refute is_nil(fork_custom)
      assert fork_custom.data["forked_session_id"] == forked_id
      assert fork_custom.data["forked_from_entry_id"] == ctx.user2.id
      assert fork_custom.data["title"] == "fork: My session"
    end

    test "updates last_parent_id to the fork entry", ctx do
      state =
        build_fork_state(
          config: %Session.SessionConfig{
            cwd: "/home/fork-project",
            storage: ctx.storage,
            model: "gpt-4",
            provider_config: fake_provider_config(),
            session_id: ctx.original.id,
            session_index_manager: ctx.manager
          },
          last_parent_id: ctx.leaf3.entry_id
        )

      {:reply, {:ok, _, _, _}, new_state} =
        Session.handle_call({:fork, ctx.user2.id}, nil, state)

      # last_parent_id should now point to the fork Custom entry
      assert new_state.last_parent_id != state.last_parent_id
      entries = Storage.read_all(ctx.storage)
      fork_custom = Enum.find(entries, &(&1.type == "custom" and &1.namespace == "fork"))
      assert new_state.last_parent_id == fork_custom.id
    end

    test "forked session can be replayed without errors", ctx do
      state =
        build_fork_state(
          config: %Session.SessionConfig{
            cwd: "/home/fork-project",
            storage: ctx.storage,
            model: "gpt-4",
            provider_config: fake_provider_config(),
            session_id: ctx.original.id,
            session_index_manager: ctx.manager
          },
          last_parent_id: ctx.leaf3.entry_id
        )

      {:reply, {:ok, forked_id, _, _}, _state} =
        Session.handle_call({:fork, ctx.user2.id}, nil, state)

      forked_entry = SessionIndexManager.get_session(ctx.manager, forked_id)

      forked_entries =
        Storage.read_all(Eva.Agent.Session.Storage.Jsonl.new(forked_entry.session_path))

      # No Leaf entries in the forked copy (only path entries), so replay without a leaf
      session_state = SessionState.from_entries(forked_entries)
      assert length(session_state.messages) == 2
    end

    test "returns {:error, {:entry_not_found, _}} for unknown entry_id", ctx do
      state =
        build_fork_state(
          config: %Session.SessionConfig{
            cwd: "/home/fork-project",
            storage: ctx.storage,
            model: "gpt-4",
            provider_config: fake_provider_config(),
            session_id: ctx.original.id,
            session_index_manager: ctx.manager
          },
          last_parent_id: ctx.leaf3.entry_id
        )

      {:reply, result, _state} =
        Session.handle_call({:fork, "nonexistent-id"}, nil, state)

      assert result == {:error, {:entry_not_found, "nonexistent-id"}}
    end

    test "forking at the first message works (empty copy_entries)", ctx do
      state =
        build_fork_state(
          config: %Session.SessionConfig{
            cwd: "/home/fork-project",
            storage: ctx.storage,
            model: "gpt-4",
            provider_config: fake_provider_config(),
            session_id: ctx.original.id,
            session_index_manager: ctx.manager
          },
          last_parent_id: ctx.leaf3.entry_id
        )

      {:reply, {:ok, forked_id, _, prefill_text}, _state} =
        Session.handle_call({:fork, ctx.user1.id}, nil, state)

      assert prefill_text == "First message"

      forked_entry = SessionIndexManager.get_session(ctx.manager, forked_id)

      forked_entries =
        Storage.read_all(Eva.Agent.Session.Storage.Jsonl.new(forked_entry.session_path))

      # Only initial entries (session_info, model_change, thinking_level_change), no messages
      entry_ids = MapSet.new(forked_entries, & &1.id)
      refute MapSet.member?(entry_ids, ctx.user1.id)
    end

    test "multiple forks create independent sessions", ctx do
      state =
        build_fork_state(
          config: %Session.SessionConfig{
            cwd: "/home/fork-project",
            storage: ctx.storage,
            model: "gpt-4",
            provider_config: fake_provider_config(),
            session_id: ctx.original.id,
            session_index_manager: ctx.manager
          },
          last_parent_id: ctx.leaf3.entry_id
        )

      {:reply, {:ok, fork1_id, _, _}, state1} =
        Session.handle_call({:fork, ctx.user2.id}, nil, state)

      {:reply, {:ok, fork2_id, _, _}, _state2} =
        Session.handle_call({:fork, ctx.user2.id}, nil, state1)

      assert fork1_id != fork2_id

      forked1_entry = SessionIndexManager.get_session(ctx.manager, fork1_id)
      forked2_entry = SessionIndexManager.get_session(ctx.manager, fork2_id)
      refute is_nil(forked1_entry)
      refute is_nil(forked2_entry)

      # Original JSONL has 2 fork Custom entries
      originals = Storage.read_all(ctx.storage)
      fork_entries = Enum.filter(originals, &(&1.type == "custom" and &1.namespace == "fork"))
      assert length(fork_entries) == 2
    end

    test "returns {:error, :original_not_indexed} when session is not in the index", %{
      tmp: tmp
    } do
      # Create a storage that isn't associated with any indexed session
      storage_path = Path.join(tmp, "unindexed.jsonl")
      storage = Eva.Agent.Session.Storage.Jsonl.new(storage_path)

      info = Entries.SessionInfo.new(%{cwd: "/some/cwd"})
      model = Entries.ModelChange.new(%{parent_id: info.id, model: "gpt-4"})
      thinking = Entries.ThinkingLevelChange.new(%{parent_id: model.id, thinking_level: "medium"})

      user =
        Entries.Message.new(%{
          parent_id: thinking.id,
          message: %Messages.UserMessage{content: "Hello"}
        })

      leaf = Entries.Leaf.new(%{parent_id: user.id, entry_id: user.id})

      Enum.each([info, model, thinking, user, leaf], fn e -> Storage.append(storage, e) end)

      paths = %Paths{home: tmp}
      manager = SessionIndexManager.new(paths)

      state =
        build_fork_state(
          config: %Session.SessionConfig{
            cwd: "/some/cwd",
            storage: storage,
            model: "gpt-4",
            provider_config: fake_provider_config(),
            session_id: "unindexed-session",
            session_index_manager: manager
          },
          last_parent_id: leaf.entry_id
        )

      {:reply, result, _state} = Session.handle_call({:fork, user.id}, nil, state)
      assert result == {:error, :original_not_indexed}
    end

    test "forked session appears in list_sessions", ctx do
      state =
        build_fork_state(
          config: %Session.SessionConfig{
            cwd: "/home/fork-project",
            storage: ctx.storage,
            model: "gpt-4",
            provider_config: fake_provider_config(),
            session_id: ctx.original.id,
            session_index_manager: ctx.manager
          },
          last_parent_id: ctx.leaf3.entry_id
        )

      {:reply, {:ok, forked_id, fork_title, _}, _state} =
        Session.handle_call({:fork, ctx.user2.id}, nil, state)

      sessions = SessionIndexManager.list_sessions(ctx.manager, "/home/fork-project")
      forked = Enum.find(sessions, &(&1.id == forked_id))
      refute is_nil(forked)
      assert forked.title == fork_title
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
