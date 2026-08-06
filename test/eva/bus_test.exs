# A host's own event, of the kind `register_events/2` exists for. Eva used to register
# `Eva.MCP.Events.*` this way; now that MCP is an extension, nothing in the tree does, so
# the mechanism needs an event of its own to be tested against.
defmodule Eva.BusTest.HostEvent do
  defstruct [:detail]
end

defmodule Eva.BusTest do
  use ExUnit.Case, async: true

  alias Eva.Bus
  alias Eva.Agent.Events, as: AgentEvents
  alias Eva.BusTest.HostEvent
  alias Eva.Agent.Messages

  setup_all do
    :ok = Bus.register_events([HostEvent], :host_test)
  end

  describe "classes/0" do
    test "returns the built-in classes plus whatever the host registered" do
      classes = Bus.classes()

      for built_in <- [:stream, :lifecycle, :tools, :extension] do
        assert built_in in classes
      end

      assert :host_test in classes
    end
  end

  describe "subscribe/2 and subscribe_pid/3" do
    test "subscribe self joins pg groups" do
      session_pid = self()

      :ok = Bus.subscribe(session_pid, [:lifecycle, :tools])

      assert self() in :pg.get_members(Eva.PG, {:eva_session, session_pid, :lifecycle})
      assert self() in :pg.get_members(Eva.PG, {:eva_session, session_pid, :tools})
      refute self() in :pg.get_members(Eva.PG, {:eva_session, session_pid, :stream})
    end

    test "subscribe_pid joins pg groups for a given pid" do
      session_pid = self()
      listener = spawn(fn -> Process.sleep(:infinity) end)

      :ok = Bus.subscribe_pid(listener, session_pid, [:tools])

      assert listener in :pg.get_members(Eva.PG, {:eva_session, session_pid, :tools})
    end

    test "subscribe_pid uses default classes" do
      session_pid = self()

      :ok = Bus.subscribe(session_pid)

      assert self() in :pg.get_members(Eva.PG, {:eva_session, session_pid, :lifecycle})
      assert self() in :pg.get_members(Eva.PG, {:eva_session, session_pid, :tools})
    end

    test "subscribe is idempotent" do
      session_pid = self()

      Bus.subscribe_pid(self(), session_pid, [:lifecycle])
      Bus.subscribe_pid(self(), session_pid, [:lifecycle])

      assert length(:pg.get_members(Eva.PG, {:eva_session, session_pid, :lifecycle})) == 1
    end
  end

  describe "unsubscribe/2" do
    test "leaves pg groups" do
      session_pid = self()
      Bus.subscribe(session_pid, [:lifecycle, :tools])

      :ok = Bus.unsubscribe(session_pid, [:lifecycle])

      refute self() in :pg.get_members(Eva.PG, {:eva_session, session_pid, :lifecycle})
      assert self() in :pg.get_members(Eva.PG, {:eva_session, session_pid, :tools})
    end

    test "unsubscribe with no args leaves all classes" do
      session_pid = self()
      Bus.subscribe(session_pid, [:lifecycle, :tools])

      Bus.unsubscribe(session_pid)

      refute self() in :pg.get_members(Eva.PG, {:eva_session, session_pid, :lifecycle})
      refute self() in :pg.get_members(Eva.PG, {:eva_session, session_pid, :tools})
    end
  end

  describe "publish/2" do
    test "forwards MessageUpdate to :stream subscribers" do
      session_pid = self()
      Bus.subscribe(session_pid, [:stream])

      event = %AgentEvents.MessageUpdate{
        message: %Messages.AssistantMessage{content: [%Messages.TextContent{text: "hi"}]}
      }

      Bus.publish(session_pid, event)
      assert_receive %AgentEvents.MessageUpdate{}
    end

    test "forwards ToolExecutionStart to :tools subscribers" do
      session_pid = self()
      Bus.subscribe(session_pid, [:tools])

      event = %AgentEvents.ToolExecutionStart{
        tool_call_id: "tc1",
        tool_name: "echo"
      }

      Bus.publish(session_pid, event)
      assert_receive %AgentEvents.ToolExecutionStart{tool_name: "echo"}
    end

    test "forwards ToolExecutionUpdate to :tools subscribers" do
      session_pid = self()
      Bus.subscribe(session_pid, [:tools])

      result = %Eva.Agent.Tools.AgentToolResult{
        content: [%Messages.TextContent{text: "partial"}]
      }

      event = %AgentEvents.ToolExecutionUpdate{
        tool_call_id: "tc1",
        tool_name: "echo",
        partial_result: result
      }

      Bus.publish(session_pid, event)
      assert_receive %AgentEvents.ToolExecutionUpdate{}
    end

    test "forwards ToolExecutionEnd to :tools subscribers" do
      session_pid = self()
      Bus.subscribe(session_pid, [:tools])

      result = %Eva.Agent.Tools.AgentToolResult{
        content: [%Messages.TextContent{text: "done"}]
      }

      event = %AgentEvents.ToolExecutionEnd{
        tool_call_id: "tc1",
        tool_name: "echo",
        result: result,
        is_error: false
      }

      Bus.publish(session_pid, event)
      assert_receive %AgentEvents.ToolExecutionEnd{}
    end

    test "forwards a registered host event to that class's subscribers" do
      session_pid = self()
      Bus.subscribe(session_pid, [:host_test])

      Bus.publish(session_pid, %HostEvent{detail: "registered"})

      assert_receive %HostEvent{detail: "registered"}
    end

    test "an event nobody registered is a lifecycle event, not a crash" do
      session_pid = self()
      Bus.subscribe(session_pid, [:lifecycle])

      Bus.publish(session_pid, %Eva.Extension.Context{name: "not an event"})

      assert_receive %Eva.Extension.Context{name: "not an event"}
    end

    test "forwards unknown events to :lifecycle subscribers" do
      session_pid = self()
      Bus.subscribe(session_pid, [:lifecycle])

      event = %AgentEvents.AgentStart{}

      Bus.publish(session_pid, event)
      assert_receive %AgentEvents.AgentStart{}
    end

    test "forwards TurnStart to :lifecycle subscribers" do
      session_pid = self()
      Bus.subscribe(session_pid, [:lifecycle])

      event = %AgentEvents.TurnStart{}

      Bus.publish(session_pid, event)
      assert_receive %AgentEvents.TurnStart{}
    end

    test "publish/3 accepts explicit class" do
      session_pid = self()
      Bus.subscribe(session_pid, [:lifecycle])

      event = %AgentEvents.ToolExecutionStart{
        tool_call_id: "tc1",
        tool_name: "echo"
      }

      Bus.publish(session_pid, event, :lifecycle)
      assert_receive %AgentEvents.ToolExecutionStart{}
    end

    test "subscriber in wrong class does not receive event" do
      session_pid = self()
      Bus.subscribe(session_pid, [:lifecycle])

      event = %AgentEvents.MessageUpdate{
        message: %Messages.AssistantMessage{content: [%Messages.TextContent{text: "nope"}]}
      }

      Bus.publish(session_pid, event)
      refute_receive %AgentEvents.MessageUpdate{}, 50
    end

    test "publish without class argument uses classify" do
      session_pid = self()
      Bus.subscribe(session_pid, [:tools])

      event = %AgentEvents.ToolExecutionStart{
        tool_call_id: "tc1",
        tool_name: "echo"
      }

      Bus.publish(session_pid, event)
      assert_receive %AgentEvents.ToolExecutionStart{}
    end

    test "multiple subscribers in same class all receive event" do
      session_pid = self()
      Bus.subscribe(session_pid, [:lifecycle])

      task =
        Task.async(fn ->
          Bus.subscribe(session_pid, [:lifecycle])

          receive do
            %AgentEvents.AgentStart{} -> :received
          after
            500 -> :timeout
          end
        end)

      Process.sleep(10)

      Bus.publish(session_pid, %AgentEvents.AgentStart{})

      assert_receive %AgentEvents.AgentStart{}
      assert Task.await(task) == :received
    end
  end
end
