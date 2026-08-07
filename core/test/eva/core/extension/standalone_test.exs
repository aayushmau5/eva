defmodule Eva.Extension.Standalone do
  use Eva.Core.Extension

  def setup(_ctx), do: {:ok, %Spec{hooks: [:tool_call], event_classes: [:lifecycle]}}

  def init(ctx), do: {:ok, %{ctx: ctx, events: 0}}

  def handle_hook(:tool_call, payload, state), do: {{:rewrite, payload}, state}

  def handle_event(_event, state), do: {:ok, %{state | events: state.events + 1}}

  def handle_command("events", _args, state), do: {{:text, state.events}, state}
end

defmodule Eva.Extension.StandaloneTest do
  @moduledoc """
  The property `eva_core` exists for: an extension runs with only this library loaded.

  Eva is not a dependency here, so nothing in this file can reach it — which is the
  point. A node extension gets exactly this VM: `eva_core` started, its own app, and
  nothing of the host's.
  """

  use ExUnit.Case, async: false

  alias Eva.Core.Extension.{Context, Supervisor}

  setup do
    ctx = %Context{
      name: "standalone",
      cwd: File.cwd!(),
      model: "test-model",
      session_pid: self(),
      extension_dir: "/tmp"
    }

    {:ok, spec} = Eva.Extension.Standalone.setup(ctx)
    {:ok, pid} = Supervisor.start_extension(Eva.Extension.Standalone, spec, ctx)
    on_exit(fn -> if Process.alive?(pid), do: Supervisor.stop_extension(pid) end)

    %{pid: pid}
  end

  test "the application brings up everything an extension needs" do
    # Each of these fails silently when missing — a registry that isn't there, a scope
    # that delivers nothing — so assert them rather than waiting to be surprised.
    assert is_pid(Process.whereis(Eva.Core.Extension.Processes))
    assert is_pid(Process.whereis(Eva.Core.Extension.Supervisor))
    assert :pg.get_members(Eva.PG, :no_such_group) == []
  end

  test "the host is genuinely absent" do
    refute Code.ensure_loaded?(Eva.Coding.Session)
    refute Code.ensure_loaded?(Eva.Extension.Set)
  end

  test "hooks round-trip", %{pid: pid} do
    assert GenServer.call(pid, {:hook, :tool_call, :payload}) == {:rewrite, :payload}
  end

  test "bus events reach handle_event/2", %{pid: pid} do
    Eva.Core.Bus.publish(self(), %Eva.Core.Agent.Events.TurnStart{}, :lifecycle)

    assert GenServer.call(pid, {:command, "events", ""}) == {:text, 1}
  end

  test "a struct the bus does not know is not an event" do
    refute Eva.Core.Bus.event?(%Context{})
    assert Eva.Core.Bus.event?(%Eva.Core.Agent.Events.TurnStart{})
  end
end
