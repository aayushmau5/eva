defmodule Eva.Agent.LoopTransformContextTest do
  use ExUnit.Case, async: true

  alias Eva.AI.Events, as: AIEvents
  alias Eva.Agent.{Loop, Messages, Tools}
  alias Eva.Test.{MockHarness, MockProvider}

  describe "transform_context" do
    test "the provider sees the transformed messages" do
      {:ok, harness} = MockHarness.start_link()

      {:ok, provider} =
        MockProvider.start_link([[stream_start(), response_end("ok")]])

      run(provider, harness, transform_context: &prepend_memory/1)

      assert [request] = MockProvider.get_requests(provider)
      assert [%Messages.UserMessage{content: "remembered"} | _] = request.messages
    end

    test "the transcript keeps the untransformed messages" do
      # The point of applying this at the provider call rather than in the turn loop:
      # injected context shapes one request and is recomputed next time, instead of
      # being written to the transcript and re-fed forever.
      {:ok, harness} = MockHarness.start_link()

      {:ok, provider} =
        MockProvider.start_link([[stream_start(), response_end("ok")]])

      {:ok, messages} = run(provider, harness, transform_context: &prepend_memory/1)

      refute Enum.any?(messages, &match?(%Messages.UserMessage{content: "remembered"}, &1))
      assert [%Messages.UserMessage{content: "hello"} | _] = messages
    end

    test "runs once per provider request, not once per turn" do
      # A turn with a tool call makes two requests. A memory plugin has to get a look
      # at both, or the second half of the turn is missing whatever it injected.
      {:ok, harness} = MockHarness.start_link()
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      tool_call = %Messages.ToolCall{id: "call_1", name: "echo", arguments: %{"msg" => "pong"}}

      {:ok, provider} =
        MockProvider.start_link([
          [
            stream_start(),
            %AIEvents.AssistantDone{
              reason: :tool_use,
              message: %Messages.AssistantMessage{model: "test", content: [tool_call]}
            }
          ],
          [stream_start(), response_end("done")]
        ])

      run(provider, harness,
        tools: [echo_tool()],
        transform_context: fn messages ->
          Agent.update(counter, &(&1 + 1))
          messages
        end
      )

      assert Agent.get(counter, & &1) == 2
      assert length(MockProvider.get_requests(provider)) == 2
    end

    test "returning a non-list leaves the messages alone" do
      {:ok, harness} = MockHarness.start_link()
      {:ok, provider} = MockProvider.start_link([[stream_start(), response_end("ok")]])

      run(provider, harness, transform_context: fn _messages -> :garbage end)

      assert [request] = MockProvider.get_requests(provider)
      assert [%Messages.UserMessage{content: "hello"}] = request.messages
    end

    test "without a callback nothing changes" do
      {:ok, harness} = MockHarness.start_link()
      {:ok, provider} = MockProvider.start_link([[stream_start(), response_end("ok")]])

      run(provider, harness, [])

      assert [request] = MockProvider.get_requests(provider)
      assert [%Messages.UserMessage{content: "hello"}] = request.messages
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────

  defp run(provider, harness, opts) do
    Task.async(fn ->
      Loop.run(
        [
          provider_pid: provider,
          harness_pid: harness,
          messages: [%Messages.UserMessage{content: "hello"}]
        ] ++ opts
      )
    end)
    |> Task.await()
  end

  defp prepend_memory(messages) do
    [%Messages.UserMessage{content: "remembered"} | messages]
  end

  defp stream_start do
    %AIEvents.AssistantStart{partial: %Messages.AssistantMessage{model: "test"}}
  end

  defp response_end(content) do
    %AIEvents.AssistantDone{
      reason: :stop,
      message: %Messages.AssistantMessage{
        model: "test",
        content: [%Messages.TextContent{text: content}]
      }
    }
  end

  defp echo_tool do
    %Tools.AgentTool{
      name: "echo",
      description: "Echoes back the input",
      input_schema: %{type: "object", properties: %{}},
      executor: fn args, _ctx ->
        %Tools.AgentToolResult{
          content: [%Messages.TextContent{text: "echo: #{args["msg"]}"}]
        }
      end
    }
  end
end
