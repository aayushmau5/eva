# Top level, not nested: nesting would make these
# `Eva.Extension.HandleInfoTest.Eva.Extension.Records`, and the namespace is what
# `use Eva.Extension` resolves against.
defmodule Eva.Extension.InfoRecords do
  use Eva.Extension

  defmodule Own do
    defstruct [:value]
  end

  @impl true
  def setup(_ctx) do
    {:ok,
     %Spec{
       commands: [%Spec.Command{name: "seen"}],
       event_classes: [:lifecycle]
     }}
  end

  @impl true
  def init(_ctx), do: {:ok, %{info: [], events: []}}

  @impl true
  def handle_info(message, state), do: {:ok, %{state | info: state.info ++ [message]}}

  @impl true
  def handle_event(event, state), do: {:ok, %{state | events: state.events ++ [event]}}

  @impl true
  def handle_command("seen", _args, state), do: {{state.info, state.events}, state}
end

defmodule Eva.Extension.InfoSilent do
  use Eva.Extension

  @impl true
  def setup(_ctx), do: {:ok, %Spec{commands: [%Spec.Command{name: "noop"}]}}
end

defmodule Eva.Extension.HandleInfoTest do
  use ExUnit.Case, async: false

  alias Eva.Agent.Events
  alias Eva.Extension.InfoRecords
  alias Eva.Test.ExtensionHarness, as: Harness

  describe "routing" do
    test "a plain message goes to handle_info/2" do
      harness = Harness.start(InfoRecords)

      :ok = Harness.send_message(harness, {:connected, "github", []})

      assert {[{:connected, "github", []}], []} = Harness.command(harness, "seen")
    end

    test "a bus event goes to handle_event/2" do
      harness = Harness.start(InfoRecords)

      :ok = Harness.send_message(harness, %Events.TurnEnd{})

      assert {[], [%Events.TurnEnd{}]} = Harness.command(harness, "seen")
    end

    test "an extension's own struct goes to handle_info/2, not handle_event/2" do
      # This is the whole point: routing on `is_struct` would send this to
      # handle_event/2, which is meant for things the extension subscribed to.
      harness = Harness.start(InfoRecords)

      :ok = Harness.send_message(harness, %InfoRecords.Own{value: 7})

      assert {[%InfoRecords.Own{value: 7}], []} = Harness.command(harness, "seen")
    end

    test "an ExtensionEvent is a bus event, whoever published it" do
      harness = Harness.start(InfoRecords)

      event = %Events.ExtensionEvent{extension: "mcp", payload: %{type: :connected}}
      :ok = Harness.send_message(harness, event)

      assert {[], [^event]} = Harness.command(harness, "seen")
    end

    test "an exit signal from a linked process reaches handle_info/2" do
      # The server traps exits so `terminate/2` can run, which turns a dying child into
      # a message. Without routing it, an extension cannot notice its own work failing.
      harness = Harness.start(InfoRecords)

      :ok = Harness.send_message(harness, {:EXIT, self(), :normal})

      assert {[{:EXIT, _pid, :normal}], []} = Harness.command(harness, "seen")
    end

    test "an extension with no handle_info/2 ignores the message" do
      harness = Harness.start(Eva.Extension.InfoSilent)

      :ok = Harness.send_message(harness, {:whatever, 1})

      assert Process.alive?(harness.pid)
    end
  end

  describe "Eva.Bus.event?/1" do
    test "true for agent events" do
      assert Eva.Bus.event?(%Events.TurnEnd{})
      assert Eva.Bus.event?(%Events.MessageUpdate{})
      assert Eva.Bus.event?(%Events.ExtensionEvent{extension: "x", payload: nil})
    end

    test "false for a struct the bus does not know — an extension's own message" do
      # This is how MCP client events reach the MCP extension now that MCP is not core's
      # to publish: they are structs the bus has never heard of, so they route to
      # `handle_info/2` rather than `handle_event/2`.
      refute Eva.Bus.event?(%Eva.Extension.Context{name: "mcp"})
    end

    test "false for anything else" do
      refute Eva.Bus.event?(%InfoRecords.Own{value: 1})
      refute Eva.Bus.event?({:connected, "github"})
      refute Eva.Bus.event?(:tuple_free_atom)
      refute Eva.Bus.event?(%{not: "a struct"})
    end
  end

  describe "publish_event/2" do
    test "stamps the extension's own name and lands on the :extension class" do
      harness = Harness.start(InfoRecords, name: "notes")
      :ok = Eva.Bus.subscribe(harness.session, [:extension])

      Eva.Extension.API.publish_event(harness.context, %{type: :indexed, count: 3})

      assert_receive %Events.ExtensionEvent{
                       extension: "notes",
                       payload: %{type: :indexed, count: 3}
                     },
                     1_000
    end
  end
end
