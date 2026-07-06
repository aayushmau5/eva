defmodule Eva.Agent.HarnessTest do
  use ExUnit.Case, async: true

  alias Eva.Agent.{Harness, Messages, Tools}
  alias Eva.AI.Events, as: AIEvents
  alias Eva.Test.MockProvider

  defp stream_start, do: %AIEvents.ProviderResponseStart{model: "test"}

  defp text_delta(text), do: %AIEvents.ProviderTextDelta{delta: text}

  defp response_end(content) do
    %AIEvents.ProviderResponseEnd{
      message: %Messages.AssistantMessage{content: content, tool_calls: []}
    }
  end

  defp echo_tool do
    %Tools.AgentTool{
      name: "echo",
      description: "Echoes back the input",
      input_schema: %{
        type: "object",
        properties: %{"msg" => %{type: "string", description: "Message to echo"}},
        required: ["msg"]
      },
      executor: fn args, _signal ->
        %Tools.AgentToolResult{
          tool_call_id: "",
          name: "echo",
          ok: true,
          content: "echo: #{args["msg"]}"
        }
      end
    }
  end

  defp wait_for_idle(harness, timeout \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      {:ok, state} = Harness.get_state(harness)
      state.running?
    end)
    |> Enum.take_while(fn running? ->
      running? && System.monotonic_time(:millisecond) < deadline
    end)
    |> Enum.to_list()
  end

  defp basic_turn do
    [[stream_start(), text_delta("hello"), response_end("hello")]]
  end

  describe "prompt/2" do
    test "starts a run and completes" do
      {:ok, provider} = MockProvider.start_link(basic_turn())
      {:ok, harness} = Harness.start_link(provider_pid: provider)

      {:ok, state} = Harness.prompt(harness, "hi")
      assert state.running?
      assert is_pid(state.looper)

      wait_for_idle(harness)
      {:ok, final} = Harness.get_state(harness)
      refute final.running?
      assert is_nil(final.looper)

      assert [%Messages.UserMessage{content: "hi"}] = final.messages
    end

    test "returns error when already running" do
      {:ok, provider} = MockProvider.start_link(basic_turn())
      {:ok, harness} = Harness.start_link(provider_pid: provider, messages: [])

      Harness.prompt(harness, "first")
      {:error, :already_running} = Harness.prompt(harness, "second")

      wait_for_idle(harness)
    end

    test "passes max_turns and tools to the loop" do
      {:ok, provider} = MockProvider.start_link(basic_turn())

      {:ok, harness} =
        Harness.start_link(provider_pid: provider, max_turns: 3, tools: [echo_tool()])

      {:ok, state} = Harness.prompt(harness, "hi")

      assert state.max_turns == 3
      assert length(state.tools) == 1

      wait_for_idle(harness)
    end
  end

  describe "continue/1" do
    test "starts a run without appending a user message" do
      {:ok, provider} = MockProvider.start_link(basic_turn())
      messages = [%Messages.UserMessage{content: "previous"}]
      {:ok, harness} = Harness.start_link(provider_pid: provider, messages: messages)

      {:ok, state} = Harness.continue(harness)
      assert state.running?

      wait_for_idle(harness)
      {:ok, final} = Harness.get_state(harness)
      assert length(final.messages) == 1
      assert %Messages.UserMessage{content: "previous"} = List.first(final.messages)
    end

    test "returns error when already running" do
      {:ok, provider} = MockProvider.start_link(basic_turn())
      {:ok, harness} = Harness.start_link(provider_pid: provider, messages: [])

      Harness.prompt(harness, "first")
      {:error, :already_running} = Harness.continue(harness)

      wait_for_idle(harness)
    end
  end

  describe "steer/2 and follow_up/2" do
    test "adds to steering queue" do
      {:ok, provider} = MockProvider.start_link([])
      {:ok, harness} = Harness.start_link(provider_pid: provider)

      Harness.steer(harness, "use rust")

      {:ok, state} = Harness.get_state(harness)
      assert length(state.steering_queue) == 1
      assert %Messages.UserMessage{content: "use rust"} = List.first(state.steering_queue)
    end

    test "adds to follow-up queue" do
      {:ok, provider} = MockProvider.start_link([])
      {:ok, harness} = Harness.start_link(provider_pid: provider)

      Harness.follow_up(harness, "add tests")

      {:ok, state} = Harness.get_state(harness)
      assert length(state.follow_up_queue) == 1
      assert %Messages.UserMessage{content: "add tests"} = List.first(state.follow_up_queue)
    end

    test "steering is drained by the loop during a run" do
      {:ok, provider} =
        MockProvider.start_link([
          [stream_start(), text_delta("ok"), response_end("ok")],
          [stream_start(), text_delta("switched"), response_end("switched")]
        ])

      {:ok, harness} = Harness.start_link(provider_pid: provider)

      Harness.steer(harness, "use rust")
      Harness.prompt(harness, "write code")

      wait_for_idle(harness)
      {:ok, state} = Harness.get_state(harness)

      assert state.steering_queue == []
      refute state.running?
    end

    test "follow-up is drained by the loop after no steering" do
      {:ok, provider} =
        MockProvider.start_link([
          [stream_start(), text_delta("done"), response_end("done")],
          [stream_start(), text_delta("with tests"), response_end("with tests")]
        ])

      {:ok, harness} = Harness.start_link(provider_pid: provider)

      Harness.follow_up(harness, "add tests")
      Harness.prompt(harness, "build it")

      wait_for_idle(harness)
      {:ok, state} = Harness.get_state(harness)

      assert state.follow_up_queue == []
      refute state.running?
    end
  end

  describe "cancel/1" do
    test "when running, kills the looper and sets running to false" do
      {:ok, provider} = MockProvider.start_link(basic_turn())
      {:ok, harness} = Harness.start_link(provider_pid: provider)

      {:ok, state} = Harness.prompt(harness, "go")
      assert state.running?
      assert is_pid(state.looper)

      looper_pid = state.looper
      Harness.cancel(harness)

      {:ok, state} = Harness.get_state(harness)
      refute state.running?
      assert is_nil(state.looper)
      refute Process.alive?(looper_pid)
    end

    test "when not running, is a no-op" do
      {:ok, provider} = MockProvider.start_link([])
      {:ok, harness} = Harness.start_link(provider_pid: provider)

      assert :ok = Harness.cancel(harness)
    end
  end

  describe "has_queued_messages?/1" do
    test "returns false when both queues are empty" do
      {:ok, provider} = MockProvider.start_link([])
      {:ok, harness} = Harness.start_link(provider_pid: provider)

      refute Harness.has_queued_messages?(harness)
    end

    test "returns true when steering queue has messages" do
      {:ok, provider} = MockProvider.start_link([])
      {:ok, harness} = Harness.start_link(provider_pid: provider)

      Harness.steer(harness, "msg")
      assert Harness.has_queued_messages?(harness)
    end

    test "returns true when follow-up queue has messages" do
      {:ok, provider} = MockProvider.start_link([])
      {:ok, harness} = Harness.start_link(provider_pid: provider)

      Harness.follow_up(harness, "msg")
      assert Harness.has_queued_messages?(harness)
    end
  end

  describe "drain_queue call contract" do
    test ":steering drains one message in one_at_a_time mode" do
      {:ok, provider} = MockProvider.start_link([])
      {:ok, harness} = Harness.start_link(provider_pid: provider)

      Harness.steer(harness, "first")
      Harness.steer(harness, "second")

      [first] = GenServer.call(harness, {:drain_queue, :steering})
      assert %Messages.UserMessage{content: "first"} = first

      [second] = GenServer.call(harness, {:drain_queue, :steering})
      assert %Messages.UserMessage{content: "second"} = second

      assert [] = GenServer.call(harness, {:drain_queue, :steering})
    end

    test ":follow_up drains one message in one_at_a_time mode" do
      {:ok, provider} = MockProvider.start_link([])
      {:ok, harness} = Harness.start_link(provider_pid: provider)

      Harness.follow_up(harness, "a")
      Harness.follow_up(harness, "b")

      [first] = GenServer.call(harness, {:drain_queue, :follow_up})
      assert %Messages.UserMessage{content: "a"} = first

      [second] = GenServer.call(harness, {:drain_queue, :follow_up})
      assert %Messages.UserMessage{content: "b"} = second

      assert [] = GenServer.call(harness, {:drain_queue, :follow_up})
    end

    test "drains all messages in :all mode" do
      {:ok, provider} = MockProvider.start_link([])
      {:ok, harness} = Harness.start_link(provider_pid: provider, queue_mode: :all)

      Harness.steer(harness, "first")
      Harness.steer(harness, "second")

      result = GenServer.call(harness, {:drain_queue, :steering})
      assert length(result) == 2

      assert [] = GenServer.call(harness, {:drain_queue, :steering})
    end
  end

  describe "state mutations" do
    test "update_messages/2 replaces messages in state" do
      {:ok, provider} = MockProvider.start_link([])
      {:ok, harness} = Harness.start_link(provider_pid: provider)

      new_messages = [%Messages.UserMessage{content: "fresh"}]
      Harness.update_messages(harness, new_messages)

      {:ok, state} = Harness.get_state(harness)
      assert state.messages == new_messages
    end

    test "update_tools/2 replaces tools" do
      {:ok, provider} = MockProvider.start_link([])
      {:ok, harness} = Harness.start_link(provider_pid: provider)

      Harness.update_tools(harness, [echo_tool()])
      {:ok, state} = Harness.get_state(harness)
      assert length(state.tools) == 1
    end

    test "change_provider/2 updates provider_pid" do
      {:ok, provider} = MockProvider.start_link([])
      {:ok, harness} = Harness.start_link(provider_pid: provider)

      {:ok, provider2} = MockProvider.start_link([])
      Harness.change_provider(harness, provider2)

      {:ok, state} = Harness.get_state(harness)
      assert state.provider_pid == provider2
    end
  end

  describe "tool call repair" do
    test "synthesizes missing tool results before prompt" do
      tool_call = %Tools.ToolCall{id: "missing_1", name: "echo", arguments: %{}}

      dangling = [
        %Messages.UserMessage{content: "do something"},
        %Messages.AssistantMessage{content: "on it", tool_calls: [tool_call]}
      ]

      {:ok, provider} = MockProvider.start_link(basic_turn())
      {:ok, harness} = Harness.start_link(provider_pid: provider, messages: dangling)

      Harness.prompt(harness, "continue")

      wait_for_idle(harness)
      {:ok, state} = Harness.get_state(harness)

      repaired =
        Enum.filter(state.messages, &match?(%Messages.ToolResultMessage{}, &1))

      assert length(repaired) == 1
      assert hd(repaired).tool_call_id == "missing_1"
      assert hd(repaired).ok == false
    end

    test "no-op when all tool calls have results" do
      tool_call = %Tools.ToolCall{id: "done_1", name: "echo", arguments: %{}}

      clean = [
        %Messages.UserMessage{content: "do something"},
        %Messages.AssistantMessage{content: "on it", tool_calls: [tool_call]},
        %Messages.ToolResultMessage{
          tool_call_id: "done_1",
          name: "echo",
          content: "done",
          ok: true
        }
      ]

      {:ok, provider} = MockProvider.start_link(basic_turn())
      {:ok, harness} = Harness.start_link(provider_pid: provider, messages: clean)

      Harness.prompt(harness, "continue")
      wait_for_idle(harness)
      {:ok, state} = Harness.get_state(harness)

      results =
        Enum.filter(state.messages, &match?(%Messages.ToolResultMessage{}, &1))

      assert length(results) == 1
      assert hd(results).ok == true
    end

    test "no-op when transcript ends with UserMessage" do
      clean = [%Messages.UserMessage{content: "just a question"}]

      {:ok, provider} = MockProvider.start_link(basic_turn())
      {:ok, harness} = Harness.start_link(provider_pid: provider, messages: clean)

      Harness.prompt(harness, "continue")
      wait_for_idle(harness)
      {:ok, state} = Harness.get_state(harness)

      results =
        Enum.filter(state.messages, &match?(%Messages.ToolResultMessage{}, &1))

      assert results == []
    end
  end

  describe "fault tolerance" do
    test "harness survives loop crash" do
      {:ok, provider} =
        MockProvider.start_link([
          [stream_start(), %AIEvents.ProviderError{message: "fatal"}, response_end("")]
        ])

      {:ok, harness} = Harness.start_link(provider_pid: provider, messages: [])

      Harness.prompt(harness, "hi")
      wait_for_idle(harness)

      # Harness still alive
      {:ok, state} = Harness.get_state(harness)
      refute state.running?
      assert is_nil(state.looper)

      # Can run again
      Harness.steer(harness, "next")
      {:ok, state} = Harness.get_state(harness)
      assert length(state.steering_queue) == 1
    end

    test "harness survives looper killed externally" do
      {:ok, provider} = MockProvider.start_link(basic_turn())
      {:ok, harness} = Harness.start_link(provider_pid: provider)

      Harness.prompt(harness, "hi")

      {:ok, state} = Harness.get_state(harness)
      Process.exit(state.looper, :kill)
      Process.sleep(50)

      {:ok, state} = Harness.get_state(harness)
      refute state.running?
      assert is_nil(state.looper)
    end
  end

  describe "resume with existing messages" do
    test "continues from a prior transcript" do
      prior = [
        %Messages.UserMessage{content: "old question"},
        %Messages.AssistantMessage{content: "old answer", tool_calls: []}
      ]

      {:ok, provider} = MockProvider.start_link(basic_turn())
      {:ok, harness} = Harness.start_link(provider_pid: provider, messages: prior)

      {:ok, state} = Harness.get_state(harness)
      assert length(state.messages) == 2

      Harness.prompt(harness, "new question")
      wait_for_idle(harness)

      {:ok, state} = Harness.get_state(harness)

      assert length(state.messages) == 3
      assert %Messages.UserMessage{content: "new question"} = List.last(state.messages)
    end
  end

  # -- Integration --

  @tag :external
  test "end-to-end: harness → loop → real LM Studio provider" do
    unless lm_studio_alive?() do
      IO.puts(:stderr, "Skipping integration test: LM Studio not reachable at #{lm_studio_url()}")
    else
      {:ok, provider} =
        Eva.AI.LmStudio.start_link(
          name: Eva.Test.Harness.LmStudio,
          system_prompt: "You are a helpful assistant. Answer in one short sentence.",
          model: model_name()
        )

      {:ok, harness} =
        Harness.start_link(
          provider_pid: provider,
          messages: []
        )

      {:ok, state} = Harness.prompt(harness, "Say hello in exactly one word")
      assert state.running?

      wait_for_idle(harness, 60_000)

      {:ok, state} = Harness.get_state(harness)
      refute state.running?
      assert is_nil(state.looper)
      assert length(state.messages) == 1

      assert %Messages.UserMessage{content: "Say hello in exactly one word"} =
               List.first(state.messages)

      GenServer.stop(provider)
    end
  end

  # -- Helpers --

  defp lm_studio_url, do: Application.get_env(:eva, :lm_studio_url, "http://localhost:1234")

  defp lm_studio_alive? do
    uri = URI.parse(lm_studio_url())
    host = uri.host |> String.to_charlist()
    port = uri.port

    case :gen_tcp.connect(host, port, [], 500) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        true

      {:error, _} ->
        false
    end
  end

  defp model_name do
    Application.get_env(:eva, :lm_studio_model, "liquid/lfm2.5-1.2b")
  end
end
