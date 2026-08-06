defmodule RunBashHarness do
  use GenServer

  def start_link(running? \\ false, initial_messages \\ []) do
    GenServer.start_link(__MODULE__, %{
      running?: running?,
      messages: initial_messages
    })
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:running_status, _from, state), do: {:reply, state.running?, state}

  def handle_call(:messages, _from, state), do: {:reply, state.messages, state}

  def handle_call({:update_messages, messages}, _from, state),
    do: {:reply, {:ok, %{}}, %{state | messages: messages}}

  def handle_call({:steer, _prompt}, _from, state), do: {:reply, :ok, state}

  def handle_call({:follow_up, _prompt}, _from, state), do: {:reply, :ok, state}

  def handle_call({:update_tools, _tools}, _from, state),
    do: {:reply, {:ok, state}, state}

  def handle_call({:update_system_prompt, _prompt}, _from, state),
    do: {:reply, :ok, state}

  def handle_call({:update_hooks, _before, _after, _context}, _from, state),
    do: {:reply, :ok, state}

  def handle_call({:prompt, _prompt}, _from, state),
    do: {:reply, {:ok, state}, state}

  def handle_call(:get_state, _from, state), do: {:reply, state, state}
end

defmodule CommandExtension do
  @moduledoc """
  Stands in for an extension's `Eva.Extension.Server`, answering every command the same way.

  Registers itself under the session's key in `Eva.Extension.Processes`, because that registry
  is how `Eva.Extension.Set` finds an extension's process — a pid handed over any other way
  would never be looked up.
  """
  use GenServer

  def start_link(session_pid, name, reply) do
    GenServer.start_link(__MODULE__, {session_pid, name, reply})
  end

  @impl true
  def init({session_pid, name, reply}) do
    {:ok, _} = Registry.register(Eva.Extension.Processes, {session_pid, name}, nil)
    {:ok, reply}
  end

  @impl true
  def handle_call({:command, _name, _args}, _from, reply), do: {:reply, reply, reply}
end

defmodule RemoteExtension do
  @moduledoc """
  Stands in for an `Eva.Extension.Node` on another VM: it answers `:instantiate` with a spec,
  which is all `Eva.Extension.Set.add_member/4` asks of it.
  """
  use GenServer

  alias Eva.Extension.Spec

  def start_link, do: GenServer.start_link(__MODULE__, :ok)

  @impl true
  def init(:ok), do: {:ok, :ok}

  @impl true
  def handle_call({:instantiate, _context, _generation}, _from, state) do
    {:reply, {:ok, self(), %Spec{guidelines: ["from another node"]}}, state}
  end
end

defmodule Eva.Coding.SessionTest do
  use ExUnit.Case, async: false

  alias Eva.Coding.Session

  alias Eva.Agent.Session.{Storage, Entries}
  alias Eva.Agent.Session.State, as: SessionState
  alias Eva.Agent.Messages
  alias Eva.Agent.Events, as: AgentEvents
  alias Eva.Coding.SessionIndexManager
  alias Eva.Coding.Paths

  defp fake_task do
    %Task{
      owner: self(),
      pid: self(),
      ref: make_ref(),
      mfa: {__MODULE__, :fake, []}
    }
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

  describe "append_custom_entry/3" do
    alias Eva.Agent.Session.State, as: SessionState
    alias Eva.Agent.Session.Storage

    # These used to be written through `append_mcp_toggle/3`. MCP is an extension now and
    # writes through `Eva.Extension.API.append_entry/2`, which lands here — so the entry
    # mechanics are still core's, and still worth pinning down.
    defp append_toggle(state, server, enabled) do
      Session.append_custom_entry(state, "ext:mcp", %{
        "server" => server,
        "enabled" => enabled
      })
    end

    defp replay_entries(config) do
      entries = Storage.read_all(config.storage)
      leaf = SessionState.latest_leaf_entry(entries)

      entries
      |> SessionState.from_entries(leaf.entry_id)
      |> SessionState.entries_by_extension()
    end

    test "writes an entry that replays back to its extension" do
      config = build_session_config()
      state = build_state(config: config)

      append_toggle(state, "ctx7", false)

      assert %{"mcp" => [%{"server" => "ctx7", "enabled" => false}]} = replay_entries(config)
    end

    # The leaf is what puts the entry on the branch replayed at resume — without it
    # `path_to_entry/2` walks straight past the toggle.
    test "keeps successive entries on the replayed branch, in write order" do
      config = build_session_config()

      state =
        build_state(config: config)
        |> append_toggle("ctx7", false)
        |> append_toggle("other", false)
        |> append_toggle("ctx7", true)

      entries = Storage.read_all(config.storage)
      leaf = SessionState.latest_leaf_entry(entries)

      assert %{
               "mcp" => [
                 %{"server" => "ctx7", "enabled" => false},
                 %{"server" => "other", "enabled" => false},
                 %{"server" => "ctx7", "enabled" => true}
               ]
             } = replay_entries(config)

      assert state.last_parent_id == leaf.entry_id
    end

    test "flushes pending initial entries so the entry has a parent in the file" do
      config = build_session_config()
      info = Eva.Agent.Session.Entries.SessionInfo.new(%{cwd: "/tmp"})

      state =
        build_state(config: config, pending_initial_entries: [info], last_parent_id: info.id)

      state = append_toggle(state, "ctx7", false)

      assert state.pending_initial_entries == []

      entries = Storage.read_all(config.storage)
      assert Enum.any?(entries, &(&1.id == info.id))

      toggle = Enum.find(entries, &(&1.type == "custom"))
      assert toggle.parent_id == info.id
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

  describe "run_bash/3" do
    test "returns {:error, :agent_running} when harness is running" do
      {:ok, harness} = RunBashHarness.start_link(true)
      config = build_session_config()
      state = build_state(config: config, harness_pid: harness)

      {:reply, result, ^state} = Session.handle_call({:run_bash, "echo hello", []}, nil, state)

      assert result == {:error, :agent_running}
    end

    test "returns {:error, :bash_running} when bash is already running" do
      {:ok, harness} = RunBashHarness.start_link()
      config = build_session_config()

      state =
        build_state(
          config: config,
          harness_pid: harness,
          bash_run: %{
            task: fake_task(),
            from: {self(), make_ref()},
            command: "sleep 100",
            private?: false
          }
        )

      {:reply, result, ^state} =
        Session.handle_call({:run_bash, "echo hello", []}, nil, state)

      assert result == {:error, :bash_running}
    end

    test "starts async execution and sets bash_run" do
      {:ok, harness} = RunBashHarness.start_link()
      config = build_session_config()
      state = build_state(config: config, harness_pid: harness)
      from = {self(), make_ref()}

      {:noreply, state_with_bash} =
        Session.handle_call({:run_bash, "echo hello", []}, from, state)

      assert %{task: %Task{}, from: ^from, command: "echo hello"} = state_with_bash.bash_run
      refute state_with_bash.bash_run.private?

      task_ref = state_with_bash.bash_run.task.ref
      assert_receive {^task_ref, _result}, 5000
    end

    test "completes async execution via handle_info — builds and returns message" do
      {:ok, harness} = RunBashHarness.start_link()
      config = build_session_config()
      state = build_state(config: config, harness_pid: harness)
      from = {self(), call_ref = make_ref()}

      {:noreply, state_with_bash} =
        Session.handle_call({:run_bash, "echo hello", []}, from, state)

      task_ref = state_with_bash.bash_run.task.ref
      assert_receive {^task_ref, result}, 5000

      {:noreply, final_state} = Session.handle_info({task_ref, result}, state_with_bash)

      assert_receive {^call_ref, {:ok, message}}, 1000

      assert %Messages.BashExecutionMessage{} = message
      assert message.command == "echo hello"
      assert String.contains?(message.output, "hello")
      assert message.exit_code == 0
      assert message.cancelled == false
      assert message.truncated == false
      assert message.full_output_path == nil
      refute message.exclude_from_context

      assert final_state.bash_run == nil
    end

    test "exclude_from_context opt is preserved through async flow" do
      {:ok, harness} = RunBashHarness.start_link()
      config = build_session_config()
      state = build_state(config: config, harness_pid: harness)
      from = {self(), call_ref = make_ref()}

      {:noreply, state_with_bash} =
        Session.handle_call(
          {:run_bash, "echo test", [exclude_from_context: true]},
          from,
          state
        )

      assert state_with_bash.bash_run.private?

      task_ref = state_with_bash.bash_run.task.ref
      assert_receive {^task_ref, result}, 5000

      {:noreply, _final_state} = Session.handle_info({task_ref, result}, state_with_bash)

      assert_receive {^call_ref, {:ok, message}}, 1000
      assert message.exclude_from_context
    end

    test "non-zero exit code is captured" do
      {:ok, harness} = RunBashHarness.start_link()
      config = build_session_config()
      state = build_state(config: config, harness_pid: harness)
      from = {self(), call_ref = make_ref()}

      {:noreply, state_with_bash} =
        Session.handle_call({:run_bash, "exit 3", []}, from, state)

      task_ref = state_with_bash.bash_run.task.ref
      assert_receive {^task_ref, result}, 5000

      {:noreply, _final_state} = Session.handle_info({task_ref, result}, state_with_bash)

      assert_receive {^call_ref, {:ok, message}}, 1000
      assert message.exit_code == 3
      assert String.contains?(message.output, "[Command exited with code 3]")
    end

    test "forwards MessageStart and MessageEnd events to listener" do
      {:ok, harness} = RunBashHarness.start_link()
      config = build_session_config(listener_pid: self())
      state = build_state(config: config, harness_pid: harness)
      from = {self(), call_ref = make_ref()}

      {:noreply, state_with_bash} =
        Session.handle_call({:run_bash, "echo hello", []}, from, state)

      assert_receive %AgentEvents.MessageStart{
        message: %Messages.BashExecutionMessage{command: "echo hello", output: ""}
      }

      task_ref = state_with_bash.bash_run.task.ref
      assert_receive {^task_ref, result}, 5000

      {:noreply, _final_state} = Session.handle_info({task_ref, result}, state_with_bash)

      assert_receive {^call_ref, {:ok, message}}, 1000
      assert_receive %AgentEvents.MessageEnd{message: ^message}
    end

    test "truncates large output and provides full_output_path" do
      {:ok, harness} = RunBashHarness.start_link()
      config = build_session_config()
      state = build_state(config: config, harness_pid: harness)
      from = {self(), call_ref = make_ref()}

      large_cmd = "yes x | head -55000 | tr -d '\\n'"

      {:noreply, state_with_bash} =
        Session.handle_call({:run_bash, large_cmd, []}, from, state)

      task_ref = state_with_bash.bash_run.task.ref
      assert_receive {^task_ref, result}, 5000

      {:noreply, _final_state} = Session.handle_info({task_ref, result}, state_with_bash)

      assert_receive {^call_ref, {:ok, message}}, 1000
      assert message.truncated
      assert message.full_output_path != nil
      assert String.contains?(message.output, "[Showing")
      assert String.contains?(message.output, "Full output:")
    end

    test "persists message to storage" do
      {:ok, harness} = RunBashHarness.start_link()
      config = build_session_config()
      state = build_state(config: config, harness_pid: harness)
      from = {self(), call_ref = make_ref()}

      {:noreply, state_with_bash} =
        Session.handle_call({:run_bash, "echo persisted", []}, from, state)

      task_ref = state_with_bash.bash_run.task.ref
      assert_receive {^task_ref, result}, 5000

      {:noreply, _final_state} = Session.handle_info({task_ref, result}, state_with_bash)

      assert_receive {^call_ref, {:ok, _message}}, 1000

      entries = Storage.read_all(config.storage)

      bash_entries =
        Enum.filter(entries, fn e ->
          match?(%Entries.Message{message: %Messages.BashExecutionMessage{}}, e)
        end)

      assert length(bash_entries) == 1
    end

    test "adds status suffix for cancelled command" do
      {:ok, harness} = RunBashHarness.start_link()
      config = build_session_config()
      state = build_state(config: config, harness_pid: harness)
      from = {self(), call_ref = make_ref()}

      {:noreply, state_with_bash} =
        Session.handle_call({:run_bash, "sleep 10", []}, from, state)

      task = state_with_bash.bash_run.task
      Eva.Coding.ShellExec.cancel(task)

      task_ref = task.ref
      assert_receive {^task_ref, result}, 5000
      assert result.cancelled

      {:noreply, _final_state} = Session.handle_info({task_ref, result}, state_with_bash)

      assert_receive {^call_ref, {:ok, message}}, 1000
      assert String.contains?(message.output, "[Command cancelled]")
    end

    test "handles task crash (DOWN) and replies with error" do
      {:ok, harness} = RunBashHarness.start_link()
      config = build_session_config()
      state = build_state(config: config, harness_pid: harness)
      from = {self(), call_ref = make_ref()}

      {:noreply, state_with_bash} =
        Session.handle_call({:run_bash, "echo hello", []}, from, state)

      task_ref = state_with_bash.bash_run.task.ref

      # First consume the success result so the process has exited
      assert_receive {^task_ref, _result}, 5000

      # Simulate a DOWN message (normally sent after the process exits). The pid is a real
      # one because the runtime always sends one — passing `nil` here would let a broader
      # `:DOWN` clause added later swallow this without any test noticing.
      {:noreply, final_state} =
        Session.handle_info({:DOWN, task_ref, :process, self(), :killed}, state_with_bash)

      assert_receive {^call_ref, {:error, {:bash_crashed, :killed}}}, 1000
      assert final_state.bash_run == nil
    end
  end

  describe "cancel_bash/1" do
    test "sends cancel signal and returns :ok when bash is running" do
      {:ok, harness} = RunBashHarness.start_link()
      config = build_session_config()
      state = build_state(config: config, harness_pid: harness)
      from = {self(), make_ref()}

      {:noreply, state_with_bash} =
        Session.handle_call({:run_bash, "sleep 10", []}, from, state)

      {:reply, :ok, _state} = Session.handle_call(:cancel_bash, nil, state_with_bash)

      task_ref = state_with_bash.bash_run.task.ref
      assert_receive {^task_ref, result}, 5000
      assert result.cancelled
    end

    test "returns {:error, :no_command_running} when nothing is running" do
      {:ok, harness} = RunBashHarness.start_link()
      config = build_session_config()
      state = build_state(config: config, harness_pid: harness)

      {:reply, result, ^state} = Session.handle_call(:cancel_bash, nil, state)

      assert result == {:error, :no_command_running}
    end
  end

  describe "extension_user_message" do
    test "follow_up when harness is running" do
      {:ok, harness} = RunBashHarness.start_link(true)
      state = build_state(harness_pid: harness)

      {:noreply, _} =
        Session.handle_info({:extension_user_message, "ext1", "a message"}, state)
    end

    test "submit_prompt when harness is not running" do
      {:ok, harness} = RunBashHarness.start_link(false)
      config = build_session_config()
      state = build_state(config: config, harness_pid: harness)

      {:noreply, _} =
        Session.handle_info({:extension_user_message, "ext1", "a message"}, state)
    end
  end

  describe "extension_custom_message" do
    test "forwards MessageStart and MessageEnd events to listener" do
      listener_pid = self()
      config = build_session_config(listener_pid: listener_pid)
      state = build_state(config: config)

      custom = %Messages.CustomMessage{
        custom_type: "test_type",
        content: "test content"
      }

      {:noreply, _} =
        Session.handle_info({:extension_custom_message, "ext1", custom}, state)

      assert_receive %AgentEvents.MessageStart{message: ^custom}
      assert_receive %AgentEvents.MessageEnd{message: ^custom}
    end
  end

  describe "extension_entry" do
    test "appends custom entry to storage" do
      config = build_session_config()
      state = build_state(config: config)

      {:noreply, _} =
        Session.handle_info({:extension_entry, "my_ext", %{"key" => "val"}}, state)

      entries = Storage.read_all(config.storage)

      # Namespaced `ext:<name>` so an extension called `mcp` cannot read or write
      # core's own `mcp` entries.
      custom = Enum.find(entries, &(&1.type == "custom" and &1.namespace == "ext:my_ext"))
      refute is_nil(custom)
      assert custom.data == %{"key" => "val"}
    end

    test "an extension only sees its own entries on replay" do
      config = build_session_config()
      state = build_state(config: config, session_state: SessionState.from_entries([]))

      {:noreply, state} = Session.handle_info({:extension_entry, "a", %{"n" => 1}}, state)
      {:noreply, state} = Session.handle_info({:extension_entry, "b", %{"n" => 2}}, state)
      {:noreply, state} = Session.handle_info({:extension_entry, "a", %{"n" => 3}}, state)

      grouped = SessionState.entries_by_extension(state.session_state)

      assert %{"a" => [%{"n" => 1}, %{"n" => 3}], "b" => [%{"n" => 2}]} = grouped
    end

    test "core's own namespace is not visible to an extension of the same name" do
      config = build_session_config()
      state = build_state(config: config, session_state: SessionState.from_entries([]))

      # What core writes for enable/disable is `extension`, with no `ext:` prefix — an
      # extension calling itself "extension" still cannot read it.
      state =
        Session.append_custom_entry(state, "extension", %{"name" => "x", "enabled" => false})

      refute Map.has_key?(SessionState.entries_by_extension(state.session_state), "extension")
    end
  end

  describe "extension_notify" do
    test "forwards notification as custom message events" do
      listener_pid = self()
      config = build_session_config(listener_pid: listener_pid)
      state = build_state(config: config)

      {:noreply, _} =
        Session.handle_info({:extension_notify, :warning, "ext1", "be careful"}, state)

      assert_receive %AgentEvents.MessageStart{
        message: %Messages.CustomMessage{custom_type: "extension_notice", content: "be careful"}
      }

      assert_receive %AgentEvents.MessageEnd{
        message: %Messages.CustomMessage{custom_type: "extension_notice"}
      }
    end

    test "includes extension name and level in details" do
      listener_pid = self()
      config = build_session_config(listener_pid: listener_pid)
      state = build_state(config: config)

      {:noreply, _} =
        Session.handle_info({:extension_notify, :error, "alert_ext", "fatal"}, state)

      assert_receive %AgentEvents.MessageStart{
        message: %Messages.CustomMessage{} = msg
      }

      assert msg.details == %{"extension" => "alert_ext", "level" => "error"}
    end
  end

  describe "extension toggles" do
    alias Eva.Agent.Session.Storage

    test "writes an extension toggle entry that replays as an override" do
      {:ok, harness} = RunBashHarness.start_link(false)
      config = build_session_config()
      state = build_state(config: config, harness_pid: harness)

      {:reply, {:ok, _list}, _new_state} =
        Session.handle_call({:set_extension_enabled, "ext1", false}, nil, state)

      entries = Storage.read_all(config.storage)

      custom =
        Enum.find(entries, &(&1.type == "custom" and &1.namespace == "extension"))

      refute is_nil(custom)
      assert custom.data["name"] == "ext1"
      assert custom.data["enabled"] == false
    end

    test "refused when agent is running" do
      {:ok, harness} = RunBashHarness.start_link(true)
      state = build_state(harness_pid: harness)

      {:reply, {:error, :agent_running}, _} =
        Session.handle_call({:set_extension_enabled, "ext1", false}, nil, state)
    end

    test "list_extensions returns list of extension maps" do
      config = build_session_config()
      state = build_state(config: config)
      {:reply, list, _} = Session.handle_call(:list_extensions, nil, state)
      assert is_list(list)
    end

    test "extension_commands returns command map" do
      config = build_session_config()
      state = build_state(config: config)
      {:reply, commands, _} = Session.handle_call(:extension_commands, nil, state)
      assert is_map(commands)
    end

    test "run_command dispatches to extension set" do
      config = build_session_config()
      state = build_state(config: config)

      {:reply, {:error, :unknown_command}, _} =
        Session.handle_call({:run_extension_command, "nonexistent", ""}, nil, state)
    end

    test "reload_extensions refused when agent is running" do
      {:ok, harness} = RunBashHarness.start_link(true)
      state = build_state(harness_pid: harness)

      {:reply, {:error, :agent_running}, _} =
        Session.handle_call(:reload_extensions, nil, state)
    end

    test "trust_extensions refused when agent is running" do
      {:ok, harness} = RunBashHarness.start_link(true)
      state = build_state(harness_pid: harness)

      {:reply, {:error, :agent_running}, _} =
        Session.handle_call(:trust_extensions, nil, state)
    end

    test "trust_extensions with nothing blocked does not reload" do
      {:ok, harness} = RunBashHarness.start_link()
      state = build_state(config: build_session_config(), harness_pid: harness)

      {:reply, {:ok, []}, unchanged} = Session.handle_call(:trust_extensions, nil, state)

      assert unchanged == state
    end
  end

  # Nothing else tells a frontend the set changed. Toggles and reloads are calls and could have
  # answered their caller, but a node joining has no caller — and a frontend cannot watch
  # `Eva.Cluster` itself without racing this session's handling of the same message.
  describe "extensions changed" do
    test "a toggle publishes it" do
      {:ok, harness} = RunBashHarness.start_link(false)
      config = build_session_config(listener_pid: self())
      state = build_state(config: config, harness_pid: harness)

      {:reply, {:ok, _list}, _} =
        Session.handle_call({:set_extension_enabled, "ext1", false}, nil, state)

      assert_receive %AgentEvents.ExtensionsChanged{}
    end

    test "an extension announcing from another node publishes it" do
      {:ok, harness} = RunBashHarness.start_link(false)
      config = build_session_config(listener_pid: self())
      state = build_state(config: config, harness_pid: harness)

      {:ok, remote} = RemoteExtension.start_link()
      member = %{role: :extension, name: "fixture", node: node(), pid: remote, generation: 1}

      {:noreply, state} = Session.handle_info({:cluster_member_up, member}, state)

      assert state.extensions.order == ["fixture"]
      assert_receive %AgentEvents.ExtensionsChanged{}
    end

    test "an extension's node going away publishes it" do
      {:ok, harness} = RunBashHarness.start_link(false)
      config = build_session_config(listener_pid: self())

      extensions = %Eva.Extension.Set{
        session_pid: self(),
        order: ["fixture"],
        specs: %{"fixture" => %Eva.Extension.Spec{}},
        members: %{"fixture" => %{name: "fixture", node: node()}}
      }

      state = build_state(config: config, harness_pid: harness, extensions: extensions)
      member = %{role: :extension, name: "fixture", node: node()}

      {:noreply, state} = Session.handle_info({:cluster_member_down, member}, state)

      assert state.extensions.order == []
      assert_receive %AgentEvents.ExtensionsChanged{}
    end

    # The `:DOWN` for a remote pid nobody in this set owns. Dropping nothing must publish
    # nothing, or a frontend re-reads on every unrelated monitor that fires.
    test "a death that changes nothing publishes nothing" do
      config = build_session_config(listener_pid: self())
      state = build_state(config: config, extensions: %Eva.Extension.Set{session_pid: self()})

      {:noreply, ^state} =
        Session.handle_info({:DOWN, make_ref(), :process, spawn(fn -> :ok end), :normal}, state)

      refute_receive %AgentEvents.ExtensionsChanged{}, 50
    end
  end

  # What a command answers with reaches the user's screen, so the shapes an extension actually
  # returns have to be the shapes that get unwrapped. `{:text, _}` is what `Eva.Extension.MCP`
  # and the test fixture both use; without a clause for it `/mcp` reads as a raw tuple.
  describe "extension command replies" do
    test "a string is shown as it is" do
      state = command_state("checked lib/")

      {:reply, :ok, _} = Session.handle_call({:prompt, "/cmd lib/", nil}, nil, state)

      assert_receive %AgentEvents.MessageEnd{
        message: %Messages.CustomMessage{
          custom_type: "extension_command",
          content: "checked lib/"
        }
      }
    end

    test "{:text, string} is unwrapped rather than inspected" do
      state = command_state({:text, "github  connected  12 tools"})

      {:reply, :ok, _} = Session.handle_call({:prompt, "/cmd", nil}, nil, state)

      assert_receive %AgentEvents.MessageEnd{
        message: %Messages.CustomMessage{content: content}
      }

      assert content == "github  connected  12 tools"
    end

    # The `handle_command/3` that `use Eva.Extension` injects answers with exactly this, so it is
    # what a command declared in `setup/1` but never implemented shows the user.
    test "an error reads as a sentence" do
      state = command_state({:error, :not_implemented})

      {:reply, :ok, _} = Session.handle_call({:prompt, "/cmd", nil}, nil, state)

      assert_receive %AgentEvents.MessageEnd{message: %Messages.CustomMessage{content: content}}
      assert content == "error: :not_implemented"
    end

    test "an error that is already a sentence is not quoted" do
      state = command_state({:error, "no MCP server named exa"})

      {:reply, :ok, _} = Session.handle_call({:prompt, "/cmd", nil}, nil, state)

      assert_receive %AgentEvents.MessageEnd{message: %Messages.CustomMessage{content: content}}
      assert content == "error: no MCP server named exa"
    end

    # Better a visible term than a swallowed one: the author can see what they returned.
    test "anything else is inspected" do
      state = command_state(%{count: 1})

      {:reply, :ok, _} = Session.handle_call({:prompt, "/cmd", nil}, nil, state)

      assert_receive %AgentEvents.MessageEnd{message: %Messages.CustomMessage{content: content}}
      assert content == "%{count: 1}"
    end

    # A set with one extension that answers every command with `reply`. Registering in
    # `Processes` under this session's key is what `Eva.Extension.Set` looks the process up by.
    defp command_state(reply) do
      config = build_session_config(listener_pid: self())
      {:ok, _pid} = CommandExtension.start_link(self(), "ext1", reply)

      extensions = %Eva.Extension.Set{
        session_pid: self(),
        order: ["ext1"],
        specs: %{
          "ext1" => %Eva.Extension.Spec{
            commands: [%Eva.Extension.Spec.Command{name: "cmd", description: "a command"}]
          }
        }
      }

      build_state(config: config, extensions: extensions)
    end
  end

  describe "handle_call :prompt with bash running" do
    test "returns :ok with {:error, :agent_running} status when bash is running" do
      {:ok, harness} = RunBashHarness.start_link()
      config = build_session_config()

      state =
        build_state(
          config: config,
          harness_pid: harness,
          bash_run: %{
            task: fake_task(),
            from: {self(), make_ref()},
            command: "sleep 100",
            private?: false
          }
        )

      {:reply, result, ^state} =
        Session.handle_call({:prompt, "hello", :steer}, nil, state)

      assert result == :ok
    end

    test "returns :ok when harness is running with :follow_up" do
      {:ok, harness} = RunBashHarness.start_link()

      state =
        build_state(
          config: build_session_config(),
          harness_pid: harness,
          bash_run: %{
            task: fake_task(),
            from: {self(), make_ref()},
            command: "sleep 100",
            private?: false
          }
        )

      {:reply, result, ^state} =
        Session.handle_call({:prompt, "hello", :follow_up}, nil, state)

      assert result == :ok
    end
  end

  defp build_state(attrs) do
    config = Keyword.get(attrs, :config, build_session_config())

    # `handle_continue(:setup)` subscribes the listener to the bus. These tests call the
    # handlers directly and skip setup, so they have to do it themselves — `forward_event/2`
    # publishes to `{:eva_session, self(), class}` and nobody would be listening otherwise.
    if config.listener_pid do
      Eva.Bus.subscribe_pid(config.listener_pid, self(), Eva.Bus.classes())
    end

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
          extensions: %Eva.Extension.Set{},
          config: config,
          provider_config: config.provider_config
        ],
        attrs
      )
    )
  end
end
