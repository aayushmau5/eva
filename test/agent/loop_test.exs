defmodule Eva.Agent.LoopTest do
  use ExUnit.Case, async: true

  alias Eva.Agent.{Loop, Events, Messages, Tools}
  alias Eva.AI.Events, as: AIEvents
  alias Eva.Test.{MockProvider, MockHarness}

  defp assert_event(events, module, fields \\ []) do
    found =
      Enum.any?(events, fn event ->
        event.__struct__ == module &&
          Enum.all?(fields, fn {key, val} -> Map.get(event, key) == val end)
      end)

    refute found == false, "expected event #{inspect(module)} with #{inspect(fields)}"
  end

  describe "run/1 with text-only responses" do
    test "single turn, single text delta" do
      {:ok, harness} = MockHarness.start_link()

      {:ok, provider} =
        MockProvider.start_link([[stream_start(), text_delta("hi"), response_end("hi")]])

      {:ok, messages} =
        Task.async(fn ->
          Loop.run(
            provider_pid: provider,
            harness_pid: harness,
            messages: [%Messages.UserMessage{content: "hello"}]
          )
        end)
        |> Task.await()

      events = MockHarness.get_events(harness)

      assert_event(events, Events.AgentStart)
      assert_event(events, Events.MessageStart, message_role: "assistant")
      assert_event(events, Events.MessageDelta, delta: "hi")
      assert_event(events, Events.MessageEnd)
      assert_event(events, Events.AgentEnd)

      assert length(messages) == 2
      assert %Messages.AssistantMessage{content: "hi"} = List.last(messages)
    end

    test "single turn, multiple text deltas" do
      {:ok, harness} = MockHarness.start_link()

      {:ok, provider} =
        MockProvider.start_link([
          [
            stream_start(),
            text_delta("Hello "),
            text_delta("world"),
            response_end("Hello world")
          ]
        ])

      {:ok, messages} =
        Task.async(fn ->
          Loop.run(
            provider_pid: provider,
            harness_pid: harness,
            messages: [%Messages.UserMessage{content: "hi"}]
          )
        end)
        |> Task.await()

      events = MockHarness.get_events(harness)

      assert_event(events, Events.MessageDelta, delta: "Hello ")
      assert_event(events, Events.MessageDelta, delta: "world")
      assert %Messages.AssistantMessage{content: "Hello world"} = List.last(messages)
    end

    test "ends when no queued messages exist" do
      {:ok, harness} = MockHarness.start_link()

      {:ok, provider} =
        MockProvider.start_link([[stream_start(), text_delta("done"), response_end("done")]])

      {:ok, messages} =
        Task.async(fn ->
          Loop.run(
            provider_pid: provider,
            harness_pid: harness,
            messages: [%Messages.UserMessage{content: "go"}]
          )
        end)
        |> Task.await()

      events = MockHarness.get_events(harness)
      assert_event(events, Events.AgentEnd)

      assert Enum.count(events, &match?(%Events.AgentStart{}, &1)) == 1
      assert Enum.count(events, &match?(%Events.AgentEnd{}, &1)) == 1
      assert length(messages) == 2
    end
  end

  describe "run/1 with tool calls" do
    test "executes a known tool and continues to next turn" do
      {:ok, harness} = MockHarness.start_link()

      tool_call = %Tools.ToolCall{id: "call_1", name: "echo", arguments: %{"msg" => "pong"}}

      {:ok, provider} =
        MockProvider.start_link([
          [
            stream_start(),
            %AIEvents.ProviderToolCall{tool_call: tool_call},
            %AIEvents.ProviderResponseEnd{
              message: %Messages.AssistantMessage{content: "", tool_calls: [tool_call]}
            }
          ],
          [stream_start(), text_delta("got your echo"), response_end("got your echo")]
        ])

      {:ok, messages} =
        Task.async(fn ->
          Loop.run(
            provider_pid: provider,
            harness_pid: harness,
            messages: [%Messages.UserMessage{content: "echo pong"}],
            tools: [echo_tool()]
          )
        end)
        |> Task.await()

      events = MockHarness.get_events(harness)

      assert_event(events, Events.ToolExecutionStart)
      assert_event(events, Events.ToolExecutionEnd)

      starts = Enum.filter(events, &match?(%Events.TurnStart{}, &1))
      assert length(starts) == 2

      assert length(messages) == 4
      assert %Messages.AssistantMessage{tool_calls: [%Tools.ToolCall{}]} = Enum.at(messages, 1)
      assert %Messages.ToolResultMessage{content: "echo: pong"} = Enum.at(messages, 2)
      assert %Messages.AssistantMessage{content: "got your echo"} = Enum.at(messages, 3)
    end

    test "returns error result for unknown tool, continues to next turn" do
      {:ok, harness} = MockHarness.start_link()

      tool_call = %Tools.ToolCall{id: "call_x", name: "nonexistent", arguments: %{}}

      {:ok, provider} =
        MockProvider.start_link([
          [
            stream_start(),
            %AIEvents.ProviderToolCall{tool_call: tool_call},
            %AIEvents.ProviderResponseEnd{
              message: %Messages.AssistantMessage{content: "", tool_calls: [tool_call]}
            }
          ],
          [stream_start(), text_delta("no tool executed"), response_end("no tool executed")]
        ])

      {:ok, messages} =
        Task.async(fn ->
          Loop.run(
            provider_pid: provider,
            harness_pid: harness,
            messages: [%Messages.UserMessage{content: "try unknown tool"}],
            tools: [echo_tool()]
          )
        end)
        |> Task.await()

      events = MockHarness.get_events(harness)
      assert_event(events, Events.ToolExecutionEnd)

      result_msg = Enum.find(messages, &match?(%Messages.ToolResultMessage{}, &1))
      assert result_msg.ok == false
      assert result_msg.name == "nonexistent"
      assert result_msg.content =~ "Unknown tool"
    end

    test "catches tool executor crashes and continues" do
      {:ok, harness} = MockHarness.start_link()

      crashing_tool = %Tools.AgentTool{
        name: "crash",
        description: "Will crash",
        input_schema: %{type: "object", properties: %{}},
        executor: fn _args, _signal -> raise "boom" end
      }

      tool_call = %Tools.ToolCall{id: "call_c", name: "crash", arguments: %{}}

      {:ok, provider} =
        MockProvider.start_link([
          [
            stream_start(),
            %AIEvents.ProviderToolCall{tool_call: tool_call},
            %AIEvents.ProviderResponseEnd{
              message: %Messages.AssistantMessage{content: "", tool_calls: [tool_call]}
            }
          ],
          [stream_start(), text_delta("recovered"), response_end("recovered")]
        ])

      {:ok, messages} =
        Task.async(fn ->
          Loop.run(
            provider_pid: provider,
            harness_pid: harness,
            messages: [%Messages.UserMessage{content: "crash"}],
            tools: [crashing_tool]
          )
        end)
        |> Task.await()

      result = Enum.find(messages, &match?(%Messages.ToolResultMessage{}, &1))
      assert result.ok == false
      assert result.content =~ "boom"
      assert length(messages) == 4
    end
  end

  describe "run/1 with steering" do
    test "drains steering queue and continues to next turn" do
      steer_msg = %Messages.UserMessage{content: "use rust instead"}
      {:ok, harness} = MockHarness.start_link(%{steering: [steer_msg], follow_up: []})

      {:ok, provider} =
        MockProvider.start_link([
          [stream_start(), text_delta("ok"), response_end("ok")],
          [stream_start(), text_delta("switching to rust"), response_end("switching to rust")]
        ])

      {:ok, messages} =
        Task.async(fn ->
          Loop.run(
            provider_pid: provider,
            harness_pid: harness,
            messages: [%Messages.UserMessage{content: "write a server"}]
          )
        end)
        |> Task.await()

      events = MockHarness.get_events(harness)

      assert Enum.any?(events, fn e ->
               match?(
                 %Events.MessageEnd{message: %Messages.UserMessage{content: "use rust instead"}},
                 e
               )
             end)

      starts = Enum.filter(events, &match?(%Events.TurnStart{}, &1))
      assert length(starts) == 2

      assert length(messages) == 4
      assert %Messages.UserMessage{content: "use rust instead"} = Enum.at(messages, 2)
    end

    test "drains follow-up queue after no steering" do
      follow_up = %Messages.UserMessage{content: "also add tests"}
      {:ok, harness} = MockHarness.start_link(%{steering: [], follow_up: [follow_up]})

      {:ok, provider} =
        MockProvider.start_link([
          [stream_start(), text_delta("done"), response_end("done")],
          [stream_start(), text_delta("adding tests"), response_end("adding tests")]
        ])

      {:ok, messages} =
        Task.async(fn ->
          Loop.run(
            provider_pid: provider,
            harness_pid: harness,
            messages: [%Messages.UserMessage{content: "build it"}]
          )
        end)
        |> Task.await()

      assert Enum.any?(messages, &match?(%Messages.UserMessage{content: "also add tests"}, &1))
    end
  end

  describe "run/1 error handling" do
    test "returns error on provider error" do
      {:ok, harness} = MockHarness.start_link()

      {:ok, provider} =
        MockProvider.start_link([
          [
            stream_start(),
            %AIEvents.ProviderError{message: "model overloaded"}
          ]
        ])

      {:ok, messages} =
        Task.async(fn ->
          Loop.run(
            provider_pid: provider,
            harness_pid: harness,
            messages: [%Messages.UserMessage{content: "hi"}]
          )
        end)
        |> Task.await()

      events = MockHarness.get_events(harness)
      assert_event(events, Events.Error, message: "model overloaded")
      assert_event(events, Events.AgentEnd)

      assert length(messages) == 1
    end

    test "emits error and ends when max_turns < 1" do
      {:ok, harness} = MockHarness.start_link()
      {:ok, provider} = MockProvider.start_link([[]])

      {:ok, messages} =
        Task.async(fn ->
          Loop.run(
            provider_pid: provider,
            harness_pid: harness,
            messages: [%Messages.UserMessage{content: "hi"}],
            max_turns: 0
          )
        end)
        |> Task.await()

      events = MockHarness.get_events(harness)
      assert_event(events, Events.Error, message: "max_turns must be at least 1")
      assert_event(events, Events.AgentEnd)
      assert length(messages) == 1
    end

    test "stops and emits error when max_turns reached" do
      {:ok, harness} = MockHarness.start_link()

      {:ok, provider} =
        MockProvider.start_link([
          [
            stream_start(),
            text_delta("t1"),
            response_end("t1")
          ]
        ])

      {:ok, _messages} =
        Task.async(fn ->
          Loop.run(
            provider_pid: provider,
            harness_pid: harness,
            messages: [%Messages.UserMessage{content: "go"}],
            max_turns: 1
          )
        end)
        |> Task.await()

      events = MockHarness.get_events(harness)
      starts = Enum.filter(events, &match?(%Events.TurnStart{}, &1))
      assert length(starts) == 1
    end

    test "times out when provider never responds" do
      {:ok, harness} = MockHarness.start_link()
      {:ok, provider} = MockProvider.start_link([])

      {:ok, messages} =
        Task.async(fn ->
          Loop.run(
            provider_pid: provider,
            harness_pid: harness,
            messages: [%Messages.UserMessage{content: "hi"}],
            stream_timeout: 50
          )
        end)
        |> Task.await()

      events = MockHarness.get_events(harness)

      refute Enum.any?(events, &match?(%Events.MessageStart{}, &1))
      assert_event(events, Events.AgentEnd)
      assert length(messages) == 1
    end
  end

  describe "run/1 event ordering" do
    test "emits events in correct lifecycle order" do
      {:ok, harness} = MockHarness.start_link()

      {:ok, provider} =
        MockProvider.start_link([[stream_start(), text_delta("x"), response_end("x")]])

      Task.async(fn ->
        Loop.run(
          provider_pid: provider,
          harness_pid: harness,
          messages: [%Messages.UserMessage{content: "hi"}]
        )
      end)
      |> Task.await()

      events = MockHarness.get_events(harness)
      types = Enum.map(events, & &1.type)

      assert types == [
               "agent_start",
               "turn_start",
               "message_start",
               "message_delta",
               "message_end",
               "turn_end",
               "agent_end"
             ]
    end
  end

  @tag :external
  test "completes a single turn with text response" do
    unless lm_studio_alive?() do
      IO.puts(:stderr, "Skipping integration test: LM Studio not reachable at #{lm_studio_url()}")
    else
      {:ok, provider} =
        Eva.AI.LmStudio.start_link(
          name: Eva.Test.LmStudio,
          system_prompt: "You are a helpful assistant. Answer in one short sentence.",
          model: model_name()
        )

      {:ok, harness} = MockHarness.start_link()

      {:ok, messages} =
        Task.async(fn ->
          Loop.run(
            provider_pid: provider,
            harness_pid: harness,
            messages: [%Messages.UserMessage{content: "Say hello in exactly one word"}],
            stream_timeout: 30_000
          )
        end)
        |> Task.await(60_000)

      events = MockHarness.get_events(harness)
      errors = Enum.filter(events, &match?(%Events.Error{}, &1))

      assert_event(events, Events.AgentStart)
      assert_event(events, Events.MessageStart, message_role: "assistant")
      assert_event(events, Events.AgentEnd)

      if errors != [] do
        error_details =
          Enum.map_join(errors, "\n  ", fn e ->
            "#{e.message}" <> if(e.data, do: " | body: #{inspect(e.data[:body])}", else: "")
          end)

        IO.puts(
          :stderr,
          "Provider error(s):\n  #{error_details}\n\nCheck model #{model_name()} is loaded in LM Studio."
        )
      else
        assert_event(events, Events.MessageDelta)
        assert_event(events, Events.MessageEnd)

        assert length(messages) == 2
        assert %Messages.AssistantMessage{content: content} = List.last(messages)
        assert byte_size(content) > 0
      end

      GenServer.stop(provider)
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────

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
