# Defined at the top level rather than nested in the test module: nesting would make
# these `Eva.Extension.TerminateTest.Eva.Extension.Cleans`, and the namespace is what
# `use Eva.Extension` resolves against.
defmodule Eva.Extension.TerminateCleans do
  use Eva.Extension

  @impl true
  def setup(_ctx), do: {:ok, %Spec{commands: [%Spec.Command{name: "noop"}]}}

  @impl true
  def init(ctx), do: {:ok, ctx}

  @impl true
  def terminate(reason, ctx) do
    API.append_entry(ctx, %{"terminated_with" => to_string(reason)})
    :ok
  end
end

defmodule Eva.Extension.TerminateRaises do
  use Eva.Extension

  @impl true
  def setup(_ctx), do: {:ok, %Spec{commands: [%Spec.Command{name: "noop"}]}}

  @impl true
  def terminate(_reason, _state), do: raise("boom")
end

defmodule Eva.Extension.TerminateSilent do
  use Eva.Extension

  @impl true
  def setup(_ctx), do: {:ok, %Spec{commands: [%Spec.Command{name: "noop"}]}}
end

defmodule Eva.Extension.TerminateTest do
  use ExUnit.Case, async: false

  alias Eva.Test.ExtensionHarness, as: Harness

  describe "terminate/2" do
    for reason <- [:shutdown, :reload, :disabled] do
      test "receives #{inspect(reason)} when stopped that way" do
        reason = unquote(reason)
        harness = Harness.start(Eva.Extension.TerminateCleans)

        :ok = Harness.stop(harness, reason)
        wait_for_exit(harness)

        assert [%{"terminated_with" => to_string(reason)}] == Harness.entries(harness)
      end
    end

    test "an extension that raises on the way out does not break the stop" do
      harness = Harness.start(Eva.Extension.TerminateRaises)

      assert :ok = Harness.stop(harness, :shutdown)
      wait_for_exit(harness)
    end

    test "an extension without terminate/2 stops cleanly" do
      harness = Harness.start(Eva.Extension.TerminateSilent)

      assert :ok = Harness.stop(harness, :reload)
      wait_for_exit(harness)
    end

    test "stopping the same extension twice is not an error" do
      harness = Harness.start(Eva.Extension.TerminateSilent)

      assert :ok = Harness.stop(harness, :shutdown)
      wait_for_exit(harness)
      assert :ok = Harness.stop(harness, :shutdown)
    end

    test "the test process survives a graceful stop" do
      # `{:shutdown, reason}` is not `:normal`, so it propagates across links. The
      # harness goes through the supervisor precisely so this does not kill the test.
      harness = Harness.start(Eva.Extension.TerminateCleans)

      :ok = Harness.stop(harness, :disabled)

      assert Process.alive?(self())
    end
  end

  defp wait_for_exit(%{pid: pid}) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
  end
end
