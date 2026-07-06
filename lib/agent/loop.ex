defmodule Eva.Agent.Loop do
  @moduledoc """
  Pure provider/tool agent loop.

  The loop is a stateless function that takes all inputs as arguments and returns
  the final transcript. The caller owns the messages list, steering/follow-up queues,
  and cancellation signal.

  The loop runs synchronously in the calling process — it blocks while waiting for
  provider events via `receive`. The caller should run it inside a Task or separate
  process so it doesn't block the caller's main loop.

  The loop communicates with the owner process exclusively via OTP messages:

    * `send(harness_pid, event)` — fire-and-forget agent events.
    * `GenServer.call(harness_pid, {:drain_queue, queue_type})` — drains and returns the
      steering (`:steering`) or follow-up (`:follow_up`) queue as a list of
      `UserMessage` structs.

  Cancellation is handled externally by the harness: it kills the run process
  via `Process.exit/2`. The harness tracks the transcript from events, so a killed
  run leaves the last finalized turn intact.
  """

  alias Eva.AI.Events, as: AIEvents
  alias Eva.Agent.{Events, Messages, Tools}

  @type agent_message ::
          Messages.UserMessage.t()
          | Messages.AssistantMessage.t()
          | Messages.ToolResultMessage.t()

  @doc """
  Runs the agent loop.

  ## Options

    * `:provider_pid` (required) — the provider process PID (e.g. `Eva.AI.LmStudio` GenServer).
    * `:harness_pid` — the owner PID to send events to and call back for
      queue draining. Defaults to `self()`.
    * `:messages` — initial transcript (default: `[]`). The harness pre-populates
      this with the user prompt and any prior conversation history.
    * `:tools` — list of `%Tools.AgentTool{}` definitions (default: `[]`).
    * `:max_turns` — maximum number of turns (default: unlimited).
    * `:stream_timeout` — milliseconds to wait for provider events (default: `120_000`).

  ## Returns

    * `{:ok, messages}` — the full transcript after the run completes.
    * `{:error, reason}` — if the provider stream fatally errors.
  """
  @spec run(keyword()) :: {:ok, [agent_message()]} | {:error, term()}
  def run(opts) do
    provider_pid = Keyword.fetch!(opts, :provider_pid)
    harness_pid = Keyword.get(opts, :harness_pid, self())

    ctx = %{
      provider_pid: provider_pid,
      harness_pid: harness_pid,
      tools: Keyword.get(opts, :tools, []),
      max_turns: Keyword.get(opts, :max_turns),
      stream_timeout: Keyword.get(opts, :stream_timeout, 120_000)
    }

    messages = Keyword.get(opts, :messages, [])

    send(harness_pid, %Events.AgentStart{})

    if is_integer(ctx.max_turns) and ctx.max_turns < 1 do
      send(harness_pid, %Events.Error{message: "max_turns must be at least 1", recoverable: false})

      send(harness_pid, %Events.AgentEnd{})
      {:ok, messages}
    else
      tool_by_name = Map.new(ctx.tools, fn %Tools.AgentTool{name: n} = t -> {n, t} end)
      run_turn_loop(ctx, messages, tool_by_name, 1)
    end
  end

  defp run_turn_loop(ctx, messages, tool_by_name, turn) do
    if exceeded_turns?(ctx.max_turns, turn) do
      send(ctx.harness_pid, %Events.Error{
        message: "Agent loop stopped after reaching max_turns=#{ctx.max_turns}",
        recoverable: true
      })

      send(ctx.harness_pid, %Events.AgentEnd{})
      {:ok, messages}
    else
      do_turn(ctx, messages, tool_by_name, turn)
    end
  end

  defp do_turn(ctx, messages, tool_by_name, turn) do
    send(ctx.harness_pid, %Events.TurnStart{turn: turn})

    case stream_response(ctx, messages) do
      {:ok, assistant_message} ->
        messages = messages ++ [assistant_message]

        if assistant_message.tool_calls == [] do
          send(ctx.harness_pid, %Events.TurnEnd{turn: turn})
          handle_no_tool_calls(ctx, messages, tool_by_name, turn)
        else
          messages = execute_tool_calls(assistant_message.tool_calls, tool_by_name, messages, ctx)
          send(ctx.harness_pid, %Events.TurnEnd{turn: turn})
          handle_post_tool_calls(ctx, messages, tool_by_name, turn)
        end

      {:error, _reason} ->
        send(ctx.harness_pid, %Events.TurnEnd{turn: turn})
        send(ctx.harness_pid, %Events.AgentEnd{})
        {:ok, messages}
    end
  end

  defp handle_no_tool_calls(ctx, messages, tool_by_name, turn) do
    case drain_queued_messages(messages, :steering, ctx) do
      {:continue, messages} ->
        run_turn_loop(ctx, messages, tool_by_name, turn + 1)

      :done ->
        case drain_queued_messages(messages, :follow_up, ctx) do
          {:continue, messages} ->
            run_turn_loop(ctx, messages, tool_by_name, turn + 1)

          :done ->
            send(ctx.harness_pid, %Events.AgentEnd{})
            {:ok, messages}
        end
    end
  end

  defp handle_post_tool_calls(ctx, messages, tool_by_name, turn) do
    # After tool calls the model must process tool results, so we always
    # continue to the next turn. Follow-ups wait until the model finishes
    # thinking about the tool output — use steering to inject input mid-run.
    case drain_queued_messages(messages, :steering, ctx) do
      {:continue, messages} ->
        run_turn_loop(ctx, messages, tool_by_name, turn + 1)

      :done ->
        run_turn_loop(ctx, messages, tool_by_name, turn + 1)
    end
  end

  defp stream_response(ctx, messages) do
    run_opts =
      [
        listener_pid: self(),
        messages: messages,
        tools: ctx.tools
      ]

    GenServer.cast(ctx.provider_pid, {:run, run_opts})

    case collect_response(ctx) do
      {:ok, message} ->
        send(ctx.harness_pid, %Events.MessageEnd{message: message})
        {:ok, message}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_response(ctx) do
    receive do
      %AIEvents.ProviderTextDelta{delta: d} ->
        send(ctx.harness_pid, %Events.MessageDelta{delta: d})
        collect_response(ctx)

      %AIEvents.ProviderThinkingDelta{delta: d} ->
        send(ctx.harness_pid, %Events.ThinkingDelta{delta: d})
        collect_response(ctx)

      %AIEvents.ProviderToolCall{} ->
        collect_response(ctx)

      %AIEvents.ProviderRetry{
        attempt: attempt,
        max_attempts: max_attempts,
        delay_seconds: delay,
        message: msg,
        data: data
      } ->
        send(ctx.harness_pid, %Events.Retry{
          attempt: attempt,
          max_attempts: max_attempts,
          delay_seconds: delay,
          message: msg,
          data: data
        })

        collect_response(ctx)

      %AIEvents.ProviderResponseEnd{message: assistant_message} ->
        {:ok, assistant_message}

      %AIEvents.ProviderError{message: reason, data: data} ->
        send(ctx.harness_pid, %Events.Error{
          message: reason,
          recoverable: false,
          data: data
        })

        {:error, reason}

      %AIEvents.ProviderResponseStart{} ->
        send(ctx.harness_pid, %Events.MessageStart{message_role: "assistant"})
        collect_response(ctx)
    after
      ctx.stream_timeout ->
        {:error, "Provider stream timed out after #{div(ctx.stream_timeout, 1000)}s"}
    end
  end

  defp execute_tool_calls(tool_calls, tool_by_name, messages, ctx) do
    Enum.reduce(tool_calls, messages, fn tool_call, acc ->
      send(ctx.harness_pid, %Events.ToolExecutionStart{tool_call: tool_call})

      tool = Map.get(tool_by_name, tool_call.name)

      result =
        if is_nil(tool) do
          unknown_tool_result(tool_call)
        else
          execute_tool(tool, tool_call)
        end

      send(ctx.harness_pid, %Events.ToolExecutionEnd{result: result})
      acc ++ [tool_result_message(result)]
    end)
  end

  defp execute_tool(%Tools.AgentTool{} = tool, %Tools.ToolCall{} = tool_call) do
    Tools.execute(tool, tool_call.arguments)
  rescue
    e ->
      %Tools.AgentToolResult{
        tool_call_id: tool_call.id,
        name: tool_call.name,
        ok: false,
        content: Exception.message(e),
        error: Exception.message(e)
      }
  end

  defp unknown_tool_result(tool_call) do
    %Tools.AgentToolResult{
      tool_call_id: tool_call.id,
      name: tool_call.name,
      ok: false,
      content: "Unknown tool: #{tool_call.name}",
      error: "Unknown tool: #{tool_call.name}"
    }
  end

  defp tool_result_message(%Tools.AgentToolResult{} = result) do
    content = build_tool_content(result)
    data = if content != "", do: nil, else: result.data

    %Messages.ToolResultMessage{
      tool_call_id: result.tool_call_id,
      name: result.name,
      content: content,
      ok: result.ok,
      data: data,
      details: result.details,
      error: result.error
    }
  end

  defp build_tool_content(%{ok: false, content: c, error: e}) when not is_nil(e) do
    if String.contains?(c, e), do: c, else: "#{c}\n\nError: #{e}"
  end

  defp build_tool_content(%{content: ""} = result) when not is_nil(result.data) do
    inspect(result.data)
  end

  defp build_tool_content(%{content: c}), do: c

  defp drain_queued_messages(messages, queue_type, ctx) do
    queued_messages = GenServer.call(ctx.harness_pid, {:drain_queue, queue_type})

    if queued_messages == [] do
      :done
    else
      Enum.each(queued_messages, fn message ->
        send(ctx.harness_pid, %Events.MessageStart{message_role: message.role})
        send(ctx.harness_pid, %Events.MessageEnd{message: message})
      end)

      {:continue, messages ++ queued_messages}
    end
  end

  defp exceeded_turns?(nil, _), do: false
  defp exceeded_turns?(max, turn) when turn > max, do: true
  defp exceeded_turns?(_, _), do: false
end
