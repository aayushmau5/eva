defmodule Eva.Extension.Delegator do
  use Eva.Extension

  @impl true
  def setup(_ctx), do: {:ok, %Spec{commands: [%Spec.Command{name: "seen"}]}}

  @impl true
  def init(_ctx), do: {:ok, %{messages: []}}

  # Background agents report back here, as tuples — never as bare event structs, which
  # would land in `handle_event/2` alongside the extension's own subscriptions.
  @impl true
  def handle_info({:agent_done, ref, messages}, state) do
    {:ok, %{state | messages: state.messages ++ [{:done, ref, messages}]}}
  end

  def handle_info({:agent_failed, ref, reason}, state) do
    {:ok, %{state | messages: state.messages ++ [{:failed, ref, reason}]}}
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def handle_command("seen", _args, state), do: {state.messages, state}
end

defmodule Eva.Extension.AgentsTest do
  use ExUnit.Case, async: false

  alias Eva.Agent.{Events, Messages}
  alias Eva.Extension.{AgentRunner, Agents, Capabilities, Context}
  alias Eva.Test.ExtensionHarness, as: Harness

  # `run_agent/2` and `spawn_agent/2` go through the real runner, which starts a real
  # provider. Swap in a stub that plays a canned script and records nothing else.
  defmodule StubCapabilities do
    def ask(_question, default, _opts), do: default

    def spawn_agent(%Context{} = _ctx, opts) do
      ref = make_ref()
      reply_to = Map.fetch!(opts, :reply_to)
      script = Process.get(:agent_script, :ok)

      pid =
        spawn(fn ->
          case script do
            :ok ->
              send(reply_to, {:agent_event, ref, %Events.TurnStart{}})
              send(reply_to, {:agent_event, ref, %Events.AgentEnd{messages: canned()}})
              send(reply_to, {:agent_done, ref, canned()})

            :fail ->
              send(reply_to, {:agent_failed, ref, :boom})

            :hang ->
              Process.sleep(:infinity)
          end
        end)

      {:ok, ref, pid}
    end

    def stop_agent(_ctx, _ref), do: :ok

    defp canned, do: [%Messages.UserMessage{content: "research it"}]
  end

  defp ctx(%{context: %Context{} = context}),
    do: %Context{context | capabilities: StubCapabilities}

  describe "run_agent/2" do
    test "blocks and returns the transcript" do
      harness = Harness.start(Eva.Extension.Delegator)

      assert {:ok, [%Messages.UserMessage{content: "research it"}]} =
               Agents.run_agent(ctx(harness), %{prompt: "research it"})
    end

    test "on_event fires for each harness event as it happens" do
      harness = Harness.start(Eva.Extension.Delegator)
      test_pid = self()

      {:ok, _} =
        Agents.run_agent(ctx(harness), %{
          prompt: "go",
          on_event: fn event -> send(test_pid, {:saw, event.__struct__}) end
        })

      assert_received {:saw, Events.TurnStart}
      assert_received {:saw, Events.AgentEnd}
    end

    test "a raising on_event does not kill the run" do
      harness = Harness.start(Eva.Extension.Delegator)

      assert {:ok, _} =
               Agents.run_agent(ctx(harness), %{
                 prompt: "go",
                 on_event: fn _event -> raise "reporting blew up" end
               })
    end

    test "a failed run comes back as an error" do
      harness = Harness.start(Eva.Extension.Delegator)
      Process.put(:agent_script, :fail)

      assert {:error, :boom} = Agents.run_agent(ctx(harness), %{prompt: "go"})
    end

    test "a hung run times out and stops the child" do
      harness = Harness.start(Eva.Extension.Delegator)
      Process.put(:agent_script, :hang)

      assert {:error, :timeout} = Agents.run_agent(ctx(harness), %{prompt: "go", timeout: 50})
    end

    test "the caller's mailbox is left clean" do
      # Events are drained as they arrive. This runs in the loop process during a tool
      # call, so leaving hundreds of unmatched messages would slow every later receive.
      harness = Harness.start(Eva.Extension.Delegator)

      {:ok, _} = Agents.run_agent(ctx(harness), %{prompt: "go"})

      refute_received {:agent_event, _ref, _event}
      refute_received {:agent_done, _ref, _messages}
    end
  end

  describe "spawn_agent/2" do
    test "returns immediately and reports back to the extension, not the caller" do
      harness = Harness.start(Eva.Extension.Delegator)

      assert {:ok, ref} = Agents.spawn_agent(ctx(harness), %{prompt: "go"})

      # The caller gets nothing; the extension's own process does.
      refute_received {:agent_done, ^ref, _}

      assert [{:done, ^ref, [%Messages.UserMessage{}]}] =
               eventually(fn -> Harness.command(harness, "seen") end)
    end

    test "a failure reaches the extension too" do
      harness = Harness.start(Eva.Extension.Delegator)
      Process.put(:agent_script, :fail)

      {:ok, ref} = Agents.spawn_agent(ctx(harness), %{prompt: "go"})

      assert [{:failed, ^ref, :boom}] = eventually(fn -> Harness.command(harness, "seen") end)
    end
  end

  describe "depth" do
    test "refuses past max_depth" do
      harness = Harness.start(Eva.Extension.Delegator)

      assert {:error, :max_depth_exceeded} =
               Agents.run_agent(ctx(harness), %{prompt: "go", depth: Agents.max_depth()})

      assert {:error, :max_depth_exceeded} =
               Agents.spawn_agent(ctx(harness), %{prompt: "go", depth: Agents.max_depth() + 1})
    end

    test "allows anything below it" do
      harness = Harness.start(Eva.Extension.Delegator)

      assert {:ok, _} =
               Agents.run_agent(ctx(harness), %{prompt: "go", depth: Agents.max_depth() - 1})
    end
  end

  describe "the real runner" do
    test "is supervised, findable by ref, and stoppable through the capability" do
      {:ok, ref, pid} =
        Capabilities.spawn_agent(real_context(), %{prompt: "go", reply_to: self()})

      assert AgentRunner.whereis(ref) == pid

      # Under the agent supervisor, not linked to us — a tool executor is long gone by
      # the time a background agent finishes.
      {:links, links} = Process.info(self(), :links)
      refute pid in links

      :ok = Agents.stop_agent(real_context(), ref)

      refute eventually(fn -> AgentRunner.whereis(ref) end, &is_nil/1)
    end

    test "dies when the process waiting on it goes away" do
      waiter = spawn(fn -> receive do: (:never -> :ok) end)

      {:ok, ref, _pid} =
        Capabilities.spawn_agent(real_context(), %{prompt: "go", reply_to: waiter})

      Process.exit(waiter, :kill)

      refute eventually(fn -> AgentRunner.whereis(ref) end, &is_nil/1)
    end
  end

  # A config shaped correctly but pointing nowhere: the runner starts and registers,
  # which is what these assert on, and the run itself fails quietly against a dead port.
  defp real_context do
    %Context{
      name: "delegator",
      cwd: "/tmp",
      session_pid: self(),
      capabilities: Capabilities,
      provider_config: %Eva.AI.Config.OpenAICompatible{
        base_url: "http://localhost:1/v1",
        provider_name: "test"
      }
    }
  end

  defp eventually(fun, done? \\ &(&1 != []), attempts \\ 50) do
    result = fun.()

    cond do
      done?.(result) -> result
      attempts > 0 -> Process.sleep(10) && eventually(fun, done?, attempts - 1)
      true -> result
    end
  end
end
