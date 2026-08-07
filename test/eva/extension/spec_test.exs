defmodule Eva.Extension.SpecTest do
  use ExUnit.Case, async: true

  alias Eva.Core.Extension.Spec

  describe "stateful?/1" do
    test "returns false when all callback triggers are empty" do
      spec = %Spec{hooks: [], event_classes: [], commands: []}
      refute Spec.stateful?(spec)
    end

    test "returns true when hooks is non-empty" do
      spec = %Spec{hooks: [:tool_call], event_classes: [], commands: []}
      assert Spec.stateful?(spec)
    end

    test "returns true when event_classes is non-empty" do
      spec = %Spec{hooks: [], event_classes: [:stream], commands: []}
      assert Spec.stateful?(spec)
    end

    test "returns true when commands is non-empty" do
      cmd = %Spec.Command{name: "hello", description: "says hello", arg_hint: ""}

      spec = %Spec{
        hooks: [],
        event_classes: [],
        commands: [cmd]
      }

      assert Spec.stateful?(spec)
    end

    test "defaults produce a stateless spec" do
      spec = struct(Spec)
      refute Spec.stateful?(spec)
    end
  end

  describe "Command typedstruct" do
    test "has expected fields" do
      cmd = %Spec.Command{name: "deploy", description: "Deploys the app", arg_hint: "--env prod"}
      assert cmd.name == "deploy"
      assert cmd.description == "Deploys the app"
      assert cmd.arg_hint == "--env prod"
    end
  end
end
