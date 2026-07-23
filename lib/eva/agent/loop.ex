defmodule Eva.Agent.Loop do
  @moduledoc """
  Pure provider/tool agent loop.

  The loop is a stateless function that takes all inputs as arguments and returns
  the final transcript. The caller owns the messages list, steering/follow-up queues,
  and cancellation signal.

  The loop runs synchronously in the calling process — it blocks while waiting for
  provider events via `receive`. The caller should run it inside a Task or separate
  process so it doesn't block the caller's main loop.

  The loop communicates with the harness process exclusively via OTP messages:

    * `send(harness_pid, event)` — fire-and-forget agent events.
    * `GenServer.call(harness_pid, {:drain_queue, queue_type})` — drains and returns the
      steering (`:steering`) or follow-up (`:follow_up`) queue as a list of
      `UserMessage` structs.
    * `GenServer.call(harness_pid, {:update_messages, messages})` — persists the transcript.

  Cancellation is handled externally by the harness: it kills the run process
  via `Process.exit/2`. The harness tracks the transcript from events, so a killed
  run leaves the last finalized turn intact.
  """

  alias Eva.AI.Events, as: AIEvents
  alias Eva.AI.OpenAICompatibleProvider
  alias Eva.Agent.{Events, Messages, Tools}

  @typedoc """
  Called before each tool execution. Receives the tool call.

  Returns `:proceed` to execute the tool normally, or `{:block, reason}` to skip
  execution and return an error result.
  """
  @type before_tool_callback ::
          (Messages.ToolCall.t() -> :proceed | {:block, String.t()})

  @typedoc """
  Called after each tool execution (including errors and blocks). Receives the
  tool call, the result, and whether the result represents an error. Can modify
  both the result and the error flag.

  Fires on every path — success, unknown tool, blocked, and crashed tools.
  """
  @type after_tool_callback ::
          (Messages.ToolCall.t(), Tools.AgentToolResult.t(), boolean() ->
             {Tools.AgentToolResult.t(), boolean()})

  @doc """
  Runs the agent loop.

  ## Options

    * `:provider_pid` (required) — the provider process PID (e.g. `Eva.AI.LmStudio` GenServer).
    * `:harness_pid` — the owner PID. Defaults to `self()`.
    * `:model` — model name passed to the provider (default: `""`).
    * `:system_prompt` — system prompt passed to the provider (default: `""`).
    * `:prompts` — prompts the user adds. Tracked separately from messages for ease of UI rendering.
    * `:messages` — initial transcript (default: `[]`). The harness pre-populates
      this with any prior conversation history.
    * `:tools` — list of `%Tools.AgentTool{}` definitions (default: `[]`).
    * `:max_turns` — maximum number of turns (default: unlimited).
    * `:stream_timeout` — milliseconds to wait for provider events (default: `120_000`).
    * `:before_tool_call` — optional callback. Called before each tool executes.
      Return `:proceed` to allow execution or `{:block, reason}` to skip it.
    * `:after_tool_call` — optional callback. Called after each tool call (even
      blocked or failed ones). Can transform the result and error flag.

  ## Returns

    * `{:ok, messages}` — the full transcript after the run completes.
  """
  @spec run(Keyword.t()) :: {:ok, [Messages.agent_message()]}
  def run(opts) do
    provider_pid = Keyword.fetch!(opts, :provider_pid)
    harness_pid = Keyword.get(opts, :harness_pid, self())

    ctx = %{
      provider_pid: provider_pid,
      harness_pid: harness_pid,
      model: Keyword.get(opts, :model, ""),
      system_prompt: Keyword.get(opts, :system_prompt, ""),
      tools: Keyword.get(opts, :tools, []),
      max_turns: Keyword.get(opts, :max_turns),
      stream_timeout: Keyword.get(opts, :stream_timeout, 120_000),
      before_tool_callback: Keyword.get(opts, :before_tool_call),
      after_tool_callback: Keyword.get(opts, :after_tool_call)
    }

    messages = Keyword.get(opts, :messages, [])
    prompts = Keyword.get(opts, :prompts, [])

    messages = messages ++ prompts
    if prompts != [], do: update_messages(ctx, messages)

    send(harness_pid, %Events.AgentStart{})
    send(harness_pid, %Events.TurnStart{})

    Enum.each(prompts, fn prompt ->
      send(harness_pid, %Events.MessageStart{message: prompt})
      send(harness_pid, %Events.MessageEnd{message: prompt})
    end)

    if is_integer(ctx.max_turns) and ctx.max_turns < 1 do
      error = error_assistant_message(ctx.model, "max_turns must be at least 1")
      messages = messages ++ [error]
      update_messages(ctx, messages)

      send(harness_pid, %Events.MessageStart{message: error})
      send(harness_pid, %Events.MessageEnd{message: error})
      send(harness_pid, %Events.TurnEnd{message: error})
      send(harness_pid, %Events.AgentEnd{messages: messages})
      {:ok, messages}
    else
      tool_by_name = Map.new(ctx.tools, fn %Tools.AgentTool{name: n} = t -> {n, t} end)
      do_turn(ctx, messages, tool_by_name, 1)
    end
  end

  # ── Turn loop ──────────────────────────────────────────────────────────

  defp do_turn(ctx, messages, tool_by_name, turn) do
    if exceeded_turns?(ctx.max_turns, turn) do
      error = error_assistant_message(ctx.model, "Agent stopped after max_turns=#{ctx.max_turns}")
      messages = messages ++ [error]
      update_messages(ctx, messages)

      send(ctx.harness_pid, %Events.MessageStart{message: error})
      send(ctx.harness_pid, %Events.MessageEnd{message: error})
      send(ctx.harness_pid, %Events.TurnEnd{message: error})
      send(ctx.harness_pid, %Events.AgentEnd{messages: messages})
      {:ok, messages}
    else
      if turn > 1 do
        send(ctx.harness_pid, %Events.TurnStart{})
      end

      {messages, _} = drain_pending(ctx, messages, :steering)

      case stream_response(ctx, messages) do
        {:ok, assistant_message} ->
          messages = messages ++ [assistant_message]
          update_messages(ctx, messages)

          if assistant_message.stop_reason in [:error, :aborted] do
            send(ctx.harness_pid, %Events.TurnEnd{message: assistant_message})
            send(ctx.harness_pid, %Events.AgentEnd{messages: messages})
            {:ok, messages}
          else
            tool_calls = get_tool_calls(assistant_message)

            if tool_calls == [] do
              send(ctx.harness_pid, %Events.TurnEnd{message: assistant_message})
              handle_no_tool_calls(ctx, messages, tool_by_name, turn)
            else
              messages = execute_tool_calls(tool_calls, tool_by_name, messages, ctx)
              update_messages(ctx, messages)

              tool_results = extract_tool_results(messages, tool_calls)

              send(ctx.harness_pid, %Events.TurnEnd{
                message: assistant_message,
                tool_results: tool_results
              })

              handle_post_tool_calls(ctx, messages, tool_by_name, turn)
            end
          end

        {:error, _reason} ->
          send(ctx.harness_pid, %Events.AgentEnd{messages: messages})
          {:ok, messages}
      end
    end
  end

  defp handle_no_tool_calls(ctx, messages, tool_by_name, turn) do
    case drain_pending(ctx, messages, :steering) do
      {messages, true} ->
        do_turn(ctx, messages, tool_by_name, turn + 1)

      {messages, false} ->
        case drain_pending(ctx, messages, :follow_up) do
          {messages, true} ->
            do_turn(ctx, messages, tool_by_name, turn + 1)

          {messages, false} ->
            send(ctx.harness_pid, %Events.AgentEnd{messages: messages})
            {:ok, messages}
        end
    end
  end

  defp handle_post_tool_calls(ctx, messages, tool_by_name, turn) do
    case drain_pending(ctx, messages, :steering) do
      {messages, true} ->
        do_turn(ctx, messages, tool_by_name, turn + 1)

      {messages, false} ->
        do_turn(ctx, messages, tool_by_name, turn + 1)
    end
  end

  # ── Provider streaming ─────────────────────────────────────────────────

  defp stream_response(ctx, messages) do
    OpenAICompatibleProvider.stream_response(ctx.provider_pid, %{
      # the loop will receive provider events
      listener_pid: self(),
      model: ctx.model,
      system_prompt: ctx.system_prompt,
      messages: messages,
      tools: ctx.tools
    })

    collect_response(ctx)
  end

  defp collect_response(ctx) do
    receive do
      %AIEvents.AgentStart{partial: partial} ->
        send(ctx.harness_pid, %Events.MessageStart{message: partial})
        collect_response(ctx)

      %AIEvents.TextDelta{partial: partial} ->
        send(ctx.harness_pid, %Events.MessageUpdate{message: partial})
        collect_response(ctx)

      %AIEvents.ThinkingDelta{partial: partial} ->
        send(ctx.harness_pid, %Events.MessageUpdate{message: partial})
        collect_response(ctx)

      %AIEvents.AssistantDone{message: message} ->
        send(ctx.harness_pid, %Events.MessageEnd{message: message})
        {:ok, message}

      %AIEvents.AssistantError{error: error} ->
        send(ctx.harness_pid, %Events.MessageEnd{message: error})
        {:ok, error}

      %AIEvents.TextStart{partial: partial} ->
        send(ctx.harness_pid, %Events.MessageUpdate{message: partial})
        collect_response(ctx)

      %AIEvents.TextEnd{partial: partial} ->
        send(ctx.harness_pid, %Events.MessageUpdate{message: partial})
        collect_response(ctx)

      %AIEvents.ThinkingStart{partial: partial} ->
        send(ctx.harness_pid, %Events.MessageUpdate{message: partial})
        collect_response(ctx)

      %AIEvents.ThinkingEnd{partial: partial} ->
        send(ctx.harness_pid, %Events.MessageUpdate{message: partial})
        collect_response(ctx)

      %AIEvents.ToolCallStart{partial: partial} ->
        send(ctx.harness_pid, %Events.MessageUpdate{message: partial})
        collect_response(ctx)

      %AIEvents.ToolCallDelta{partial: partial} ->
        send(ctx.harness_pid, %Events.MessageUpdate{message: partial})
        collect_response(ctx)

      %AIEvents.ToolCallEnd{partial: partial} ->
        send(ctx.harness_pid, %Events.MessageUpdate{message: partial})
        collect_response(ctx)
    after
      ctx.stream_timeout ->
        {:error, "Provider stream timed out after #{div(ctx.stream_timeout, 1000)}s"}
    end
  end

  # ── Tool execution ─────────────────────────────────────────────────────

  defp get_tool_calls(%Messages.AssistantMessage{} = message) do
    Messages.AssistantMessage.tool_calls(message)
  end

  defp extract_tool_results(messages, tool_calls) do
    ids = MapSet.new(tool_calls, & &1.id)

    Enum.filter(messages, fn
      %Messages.ToolResultMessage{tool_call_id: id} -> MapSet.member?(ids, id)
      _ -> false
    end)
  end

  defp execute_tool_calls(tool_calls, tool_by_name, messages, ctx) do
    Enum.reduce(tool_calls, messages, fn tool_call, acc ->
      send(ctx.harness_pid, %Events.ToolExecutionStart{
        tool_call_id: tool_call.id,
        tool_name: tool_call.name,
        args: tool_call.arguments
      })

      {result, is_error} = execute_single_tool_call(tool_call, tool_by_name, ctx)

      send(ctx.harness_pid, %Events.ToolExecutionEnd{
        tool_call_id: tool_call.id,
        tool_name: tool_call.name,
        result: result,
        is_error: is_error
      })

      message = build_tool_result_message(result, is_error)
      send(ctx.harness_pid, %Events.MessageStart{message: message})
      send(ctx.harness_pid, %Events.MessageEnd{message: message})

      acc ++ [message]
    end)
  end

  defp execute_single_tool_call(tool_call, tool_by_name, ctx) do
    {result, is_error} =
      case apply_before_hook(tool_call, ctx) do
        :proceed ->
          tool = Map.get(tool_by_name, tool_call.name)

          if is_nil(tool) do
            {unknown_tool_result(tool_call), true}
          else
            execute_tool(tool, tool_call)
          end

        {:block, reason} ->
          {blocked_result(tool_call, reason), true}
      end

    apply_after_hook(tool_call, result, is_error, ctx)
  end

  defp execute_tool(%Tools.AgentTool{} = tool, %Messages.ToolCall{} = tool_call) do
    # TODO: think about passing an "update" function for updates that sends ToolExecutionUpdate event
    {Tools.execute(tool, tool_call.arguments), false}
  rescue
    e ->
      {
        %Tools.AgentToolResult{
          content: %Messages.TextContent{text: Exception.message(e)}
        },
        true
      }
  end

  defp unknown_tool_result(tool_call) do
    %Tools.AgentToolResult{
      content: %Messages.TextContent{text: "Unknown tool: #{tool_call.name}"}
    }
  end

  defp blocked_result(tool_call, reason) do
    msg = reason || "Tool execution was blocked"

    %Tools.AgentToolResult{
      content: %Messages.TextContent{text: msg}
    }
  end

  # ── Hooks ──────────────────────────────────────────────────────────────

  defp apply_before_hook(tool_call, %{before_tool_callback: hook})
       when is_function(hook, 1),
       do: hook.(tool_call)

  defp apply_before_hook(_tool_call, _ctx), do: :proceed

  defp apply_after_hook(tool_call, result, is_error, %{after_tool_callback: hook})
       when is_function(hook, 3),
       do: hook.(tool_call, result, is_error)

  defp apply_after_hook(_tool_call, result, is_error, _ctx), do: {result, is_error}

  # ── Tool result message ────────────────────────────────────────────────

  defp build_tool_result_message(%Tools.AgentToolResult{} = result, is_error) do
    %Messages.ToolResultMessage{
      tool_call_id: result.tool_call_id,
      tool_name: result.name,
      content: build_result_content(result),
      details: result.details,
      is_error: is_error
    }
  end

  defp build_result_content(%{content: ""} = result) when not is_nil(result.data) do
    [%Messages.TextContent{text: inspect(result.data)}]
  end

  defp build_result_content(%{ok: false, content: c, error: e}) when not is_nil(e) do
    text = if String.contains?(c, e), do: c, else: "#{c}\n\nError: #{e}"
    [%Messages.TextContent{text: text}]
  end

  defp build_result_content(%{content: c}) do
    [%Messages.TextContent{text: c}]
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp drain_pending(ctx, messages, queue_type) do
    # TODO: replace with Harness.get_pending_messages()
    queued = GenServer.call(ctx.harness_pid, {:drain_queue, queue_type})

    if queued == [] do
      {messages, false}
    else
      messages = messages ++ queued
      update_messages(ctx, messages)

      Enum.each(queued, fn message ->
        send(ctx.harness_pid, %Events.MessageStart{message: message})
        send(ctx.harness_pid, %Events.MessageEnd{message: message})
      end)

      {messages, true}
    end
  end

  defp update_messages(ctx, messages) do
    # TODO: replace with Harness.update_messages(messages)
    GenServer.call(ctx.harness_pid, {:update_messages, messages})
  end

  defp error_assistant_message(model, message) do
    %Messages.AssistantMessage{
      model: model,
      content: [],
      stop_reason: :error,
      error_message: message
    }
  end

  defp exceeded_turns?(nil, _), do: false
  defp exceeded_turns?(max, turn) when turn > max, do: true
  defp exceeded_turns?(_, _), do: false
end
