defmodule Eva.Extension.MemoryStub do
  use Eva.Core.Extension

  alias Eva.Core.Agent.Messages

  @impl true
  def setup(_ctx), do: {:ok, %Spec{hooks: [:context]}}

  @impl true
  def init(_ctx), do: {:ok, %{}}

  @impl true
  def handle_hook(:context, messages, state) do
    injected = %Messages.UserMessage{content: "remembered: the build is flaky"}
    {{:ok, [injected | messages]}, state}
  end

  def handle_hook(_hook, _payload, state), do: {:proceed, state}
end

defmodule Eva.Extension.ContextCrasher do
  use Eva.Core.Extension

  @impl true
  def setup(_ctx), do: {:ok, %Spec{hooks: [:context]}}

  @impl true
  def handle_hook(:context, _messages, _state), do: raise("retrieval exploded")
end

defmodule Eva.Extension.ContextGarbage do
  use Eva.Core.Extension

  @impl true
  def setup(_ctx), do: {:ok, %Spec{hooks: [:context]}}

  @impl true
  def handle_hook(:context, _messages, state), do: {{:ok, :not_a_list}, state}
end

defmodule Eva.Extension.ContextHookTest do
  use ExUnit.Case, async: false

  alias Eva.Core.Agent.Messages
  alias Eva.Extension.Hooks
  alias Eva.Test.ExtensionHarness, as: Harness

  defp targets(harnesses) do
    %{:context => Enum.map(harnesses, &{&1.context.name, &1.pid})}
  end

  defp user(text), do: %Messages.UserMessage{content: text}

  describe "context_fun/1" do
    test "with no listeners the messages come back untouched" do
      fun = Hooks.context_fun(%{})
      messages = [user("hello")]

      assert ^messages = fun.(messages)
    end

    test "an extension can inject a message" do
      harness = Harness.start(Eva.Extension.MemoryStub, name: "memory")
      fun = Hooks.context_fun(targets([harness]))

      assert [
               %Messages.UserMessage{content: "remembered: " <> _},
               %Messages.UserMessage{content: "hello"}
             ] =
               fun.([user("hello")])
    end

    test "extensions chain, each seeing the previous one's output" do
      a = Harness.start(Eva.Extension.MemoryStub, name: "a")
      b = Harness.start(Eva.Extension.MemoryStub, name: "b")

      result = Hooks.context_fun(targets([a, b])).([user("hello")])

      # Both prepended, so the original is last and there are three.
      assert length(result) == 3
      assert %Messages.UserMessage{content: "hello"} = List.last(result)
    end

    test "a crashing extension is neutral — messages pass through" do
      # Unlike :tool_call, where an unreachable extension blocks. Injecting context is
      # additive, so a memory plugin having a bad day must not stop the turn.
      crasher = Harness.start(Eva.Extension.ContextCrasher, name: "crasher")
      messages = [user("hello")]

      assert ^messages = Hooks.context_fun(targets([crasher])).(messages)
    end

    test "a crash in the middle of the chain does not lose the others' work" do
      good = Harness.start(Eva.Extension.MemoryStub, name: "good")
      crasher = Harness.start(Eva.Extension.ContextCrasher, name: "crasher")

      result = Hooks.context_fun(targets([good, crasher])).([user("hello")])

      assert length(result) == 2
    end

    test "an extension returning something that is not a list is ignored" do
      harness = Harness.start(Eva.Extension.ContextGarbage, name: "garbage")
      messages = [user("hello")]

      assert ^messages = Hooks.context_fun(targets([harness])).(messages)
    end
  end
end
