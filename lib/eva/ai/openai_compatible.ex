defmodule Eva.AI.OpenAICompatibleProvider do
  use GenServer

  alias Eva.AI.{Events, StreamState}
  alias Eva.AI.Config.OpenAICompatible, as: OpenAICompatibleConfig
  alias Eva.Agent.{Messages, Tools}

  @type opts :: [name: atom(), config: OpenAICompatibleConfig.t()]
  @type stream_opts :: %{
          listener_pid: pid(),
          model: String.t(),
          system_prompt: String.t(),
          messages: [Messages.t()],
          tools: [Tools.tool()]
        }

  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec stream_response(pid(), stream_opts()) :: :ok
  def stream_response(pid \\ __MODULE__, opts) do
    GenServer.cast(pid, {:stream, opts})
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       config: Keyword.fetch!(opts, :config)
     }}
  end

  @impl true
  def handle_cast({:stream, opts}, state) do
    Task.start(fn -> stream(state, opts) end)
    {:noreply, state}
  end

  defp stream(state, opts) do
    acc = %{
      stream_state: %StreamState{},
      partial: %Messages.AssistantMessage{
        api: state.config.api,
        provider: state.config.provider_name,
        model: opts.model
      },
      active_index: nil,
      active_kind: nil,
      started: false
    }

    Finch.build(
      :post,
      state.config.base_url <> "/chat/completions",
      [],
      build_req_body(opts, state)
    )
    |> Finch.stream(
      Eva.Finch,
      acc,
      fn event, acc -> handle_stream_event(event, acc, opts.listener_pid) end,
      receive_timeout: 15_000
    )
    |> emit_stream_outcome(opts.listener_pid)
  end

  defp handle_stream_event({:status, status}, acc, _listener_pid) do
    %{acc | stream_state: %{acc.stream_state | status: status}}
  end

  defp handle_stream_event({:headers, _}, acc, _listener_pid), do: acc
  defp handle_stream_event({:trailers, _}, acc, _listener_pid), do: acc

  defp handle_stream_event({:data, data}, acc, listener_pid) do
    {stream_state, deltas} = StreamState.feed(acc.stream_state, data)
    acc = %{acc | stream_state: stream_state}

    # deltas: [{:thinking, "thinking response ..."}, {:content, "content response ..."}]
    Enum.reduce(deltas, acc, &handle_delta(&1, &2, listener_pid))
  end

  # Each parsed SSE delta becomes one AI event. Text and thinking arrive
  # interleaved, so each delta appends to the active content block of a
  # running `partial` AssistantMessage, opening/closing blocks as the stream
  # switches channels. Every event carries `partial` so consumers can render
  # without buffering.
  defp handle_delta({:content, delta}, acc, pid) do
    {acc, index} = enter_block(acc, :text, pid)

    %Messages.TextContent{} = block = Enum.at(acc.partial.content, index)
    %Messages.TextContent{} = block = %{block | text: block.text <> delta}

    %Messages.AssistantMessage{} =
      partial = %{acc.partial | content: List.replace_at(acc.partial.content, index, block)}

    send(pid, %Events.TextDelta{content_index: index, delta: delta, partial: partial})
    %{acc | partial: partial}
  end

  defp handle_delta({:thinking, delta}, acc, pid) do
    {acc, index} = enter_block(acc, :thinking, pid)

    %Messages.ThinkingContent{} = block = Enum.at(acc.partial.content, index)
    %Messages.ThinkingContent{} = block = %{block | thinking: block.thinking <> delta}

    %Messages.AssistantMessage{} =
      partial = %{acc.partial | content: List.replace_at(acc.partial.content, index, block)}

    send(pid, %Events.ThinkingDelta{content_index: index, delta: delta, partial: partial})
    %{acc | partial: partial}
  end

  # Emit `AgentStart` once, on first content. Deferring it keeps the sequence
  # honest if the stream dies before any content lands.
  defp start_assistant(acc, pid) do
    if acc.started do
      acc
    else
      send(pid, %Events.AgentStart{partial: acc.partial})
      %{acc | started: true}
    end
  end

  # Open (or reuse) the active content block for `kind`. Closes the previous
  # block first if the channel changed. Returns `{acc, content_index}`.
  defp enter_block(acc, kind, pid) do
    if acc.active_kind == kind do
      {acc, acc.active_index}
    else
      # Set started: true if not done already(fires up an AgentStart event)
      acc = start_assistant(acc, pid)

      # If we are already in a block(like :text or :thinking), close it(which fires up an TextEnd or ThinkingEnd event)
      acc = close_block(acc, pid)

      index = length(acc.partial.content)

      # Start up a new TextContent or ThinkingContent block with it's starting event struct(TextStart | ThinkingStart)
      {block, start_event} = new_block(kind, index)

      # Put this new block into the list of blocks(that we call partial as the chunks arrive)
      # partial is of type AssistantMessage
      partial = %{acc.partial | content: acc.partial.content ++ [block]}

      # Fire up the start event with partial data: the event contains the partial data all the past content
      send(pid, %{start_event | partial: partial})

      {%{acc | partial: partial, active_index: index, active_kind: kind}, index}
    end
  end

  # Close the active block (if any) and emit its end event.
  defp close_block(acc, pid) do
    if acc.active_index == nil do
      acc
    else
      case Enum.at(acc.partial.content, acc.active_index) do
        %Messages.TextContent{text: text} ->
          send(pid, %Events.TextEnd{
            content_index: acc.active_index,
            content: text,
            partial: acc.partial
          })

        %Messages.ThinkingContent{thinking: thinking} ->
          send(pid, %Events.ThinkingEnd{
            content_index: acc.active_index,
            content: thinking,
            partial: acc.partial
          })
      end

      %{acc | active_index: nil, active_kind: nil}
    end
  end

  defp new_block(:text, idx),
    do: {%Messages.TextContent{text: ""}, %Events.TextStart{content_index: idx}}

  defp new_block(:thinking, idx),
    do: {%Messages.ThinkingContent{thinking: ""}, %Events.ThinkingStart{content_index: idx}}

  defp emit_stream_outcome(
         {:ok, %{stream_state: %{status: status}} = acc},
         listener_pid
       )
       when status != nil and status >= 400 do
    acc = start_assistant(acc, listener_pid)
    acc = close_block(acc, listener_pid)

    body = acc.stream_state.body_rev |> Enum.reverse() |> Enum.join("")
    message = "HTTP #{status}" <> if(body != "", do: ": #{body}", else: "")

    error =
      %{
        acc.partial
        | stop_reason: :error,
          error_message: message,
          diagnostics: [
            %Messages.AssistantMessageDiagnostic{
              type: "provider_error",
              details: %{status: status, body: body}
            }
          ]
      }

    send(listener_pid, %Events.AssistantError{reason: :error, error: error})
  end

  defp emit_stream_outcome({:ok, acc}, listener_pid) do
    acc = start_assistant(acc, listener_pid)
    acc = close_block(acc, listener_pid)

    tool_calls =
      acc.stream_state.tool_calls
      |> StreamState.build_tool_calls()

    acc =
      Enum.reduce(tool_calls, acc, fn tool_call, acc ->
        content_index = length(acc.partial.content)
        partial = %{acc.partial | content: acc.partial.content ++ [tool_call]}

        send(listener_pid, %Events.ToolCallStart{
          content_index: content_index,
          partial: partial
        })

        send(listener_pid, %Events.ToolCallEnd{
          content_index: content_index,
          tool_call: tool_call,
          partial: partial
        })

        %{acc | partial: partial}
      end)

    finish_reason = finish_reason(acc.stream_state.finish_reason, tool_calls != [])
    %Messages.AssistantMessage{} = final = %{acc.partial | stop_reason: finish_reason}

    send(listener_pid, %Events.AssistantDone{reason: finish_reason, message: final})
  end

  defp emit_stream_outcome({:error, error, acc}, listener_pid) do
    acc = start_assistant(acc, listener_pid)
    acc = close_block(acc, listener_pid)

    message = "Transport error: #{inspect(error)}"

    error_msg = %{
      acc.partial
      | stop_reason: :error,
        error_message: message,
        diagnostics: [
          %Messages.AssistantMessageDiagnostic{
            type: "transport_error",
            details: %{error: inspect(error)}
          }
        ]
    }

    send(listener_pid, %Events.AssistantError{reason: :error, error: error_msg})
  end

  defp finish_reason(value, has_tools) when is_binary(value) do
    cond do
      has_tools or value in ["tool_calls", "tool_use", "toolUse"] -> :tool_use
      value in ["length", "max_tokens", "MAX_TOKENS", "incomplete"] -> :length
      true -> :stop
    end
  end

  defp finish_reason(_value, true), do: :tool_use
  defp finish_reason(_value, false), do: :stop

  defp serialize_tool(%Tools.AgentTool{} = tool) do
    %{
      type: "function",
      function: %{
        name: tool.name,
        description: tool.description,
        parameters: tool.input_schema
      }
    }
  end

  defp build_req_body(opts, state) do
    compat = state.config.compat
    supports_reasoning_effort = Map.get(compat, :supports_reasoning_effort, true)

    body = %{
      model: opts.model,
      messages: build_messages(opts.system_prompt, opts.messages),
      tools: Enum.map(opts.tools, &serialize_tool/1),
      stream: true
    }

    reasoning_enabled? =
      supports_reasoning_effort &&
        not is_nil(state.config.reasoning_effort) &&
        state.config.reasoning_effort != "none"

    body =
      if reasoning_enabled? or state.config.include_reasoning_effort_none_in_payload do
        Map.merge(body, %{reasoning_effort: state.config.reasoning_effort})
      else
        body
      end

    JSON.encode!(body)
  end

  defp build_messages(system_prompt, messages) do
    system = [%{role: "system", content: system_prompt}]

    messages =
      Enum.map(messages, fn
        %Messages.UserMessage{} = user_message ->
          %{role: "user", content: Messages.UserMessage.text(user_message)}

        %Messages.AssistantMessage{} = assistant_message ->
          %{role: "assistant", content: Messages.AssistantMessage.text(assistant_message)}
          |> maybe_add_reasoning(assistant_message)
          |> maybe_add_tool_calls(assistant_message)

        %Messages.ToolResultMessage{} = tool_result_message ->
          %{
            role: "tool",
            tool_call_id: tool_result_message.tool_call_id,
            name: tool_result_message.tool_name,
            content: Messages.ToolResultMessage.text(tool_result_message)
          }

        %Messages.CustomMessage{} = custom_message ->
          %{role: "user", content: Messages.CustomMessage.text(custom_message)}

        %Messages.BranchSummaryMessage{} = branch_summary_message ->
          %{role: "user", content: branch_summary_message.summary}

        %Messages.CompactionSummaryMessage{} = compaction_summary_message ->
          %{role: "user", content: compaction_summary_message.summary}

        %Messages.BashExecutionMessage{} = bash_execution_message ->
          %{role: "user", content: bash_execution_message.output}
      end)

    system ++ messages
  end

  defp maybe_add_reasoning(message, assistant_message) do
    thinking = Enum.filter(assistant_message.content, &match?(%Messages.ThinkingContent{}, &1))

    case thinking do
      [] ->
        message

      thinking ->
        signature = hd(thinking).thinking_signature
        signature = if signature != "", do: signature, else: "reasoning_content"

        if signature in ["reasoning_content", "reasoning", "thinking"] do
          reasoning =
            thinking
            |> Enum.map(&Messages.AssistantMessage.thinking_text/1)
            |> Enum.join()

          Map.put(message, signature, reasoning)
        else
          message
        end
    end
  end

  defp maybe_add_tool_calls(message, assistant_message) do
    case Messages.AssistantMessage.tool_calls(assistant_message) do
      [] ->
        message

      tool_calls ->
        tool_calls =
          Enum.map(tool_calls, fn %Messages.ToolCall{} = t ->
            %{
              id: t.id,
              type: "function",
              function: %{
                name: t.name,
                arguments: encode_arguments(t.arguments)
              }
            }
          end)

        Map.put(message, :tool_calls, tool_calls)
    end
  end

  defp encode_arguments(args) when is_map(args), do: JSON.encode!(args)
  defp encode_arguments(args) when is_binary(args), do: args
  defp encode_arguments(_), do: "{}"
end
