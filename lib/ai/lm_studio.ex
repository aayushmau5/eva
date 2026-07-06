defmodule Eva.AI.LmStudio do
  use GenServer

  alias Eva.AI.{Events, StreamState}
  alias Eva.Agent.{Messages, Tools}

  @base_url "http://localhost:1234/v1"
  @endpoint "/chat/completions"
  @model "liquid/lfm2.5-1.2b"

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def change_system_prompt(pid \\ __MODULE__, system_prompt) when is_binary(system_prompt) do
    GenServer.call(pid, {:change_system_prompt, system_prompt})
  end

  def change_model(pid \\ __MODULE__, model) when is_binary(model) do
    GenServer.call(pid, {:change_model, model})
  end

  @impl true
  def init(opts) do
    state = %{
      base_url: Keyword.get(opts, :base_url, @base_url),
      endpoint: Keyword.get(opts, :endpoint, @endpoint),
      model: Keyword.get(opts, :model, @model),
      reasoning_effort: Keyword.get(opts, :reasoning_effort),
      system_prompt: Keyword.get(opts, :system_prompt)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:change_system_prompt, system_prompt}, _from, state) do
    {:reply, :ok, %{state | system_prompt: system_prompt}}
  end

  def handle_call({:change_model, model}, _from, state) do
    {:reply, :ok, %{state | model: model}}
  end

  @impl true
  def handle_cast({:run, run_opts}, state) do
    listener_pid = Keyword.fetch!(run_opts, :listener_pid)
    messages = Keyword.get(run_opts, :messages, [])
    tools = Keyword.get(run_opts, :tools, [])

    Task.start(fn ->
      stream(state, %{
        messages: messages,
        tools: tools,
        listener_pid: listener_pid
      })
    end)

    {:noreply, state}
  end

  defp stream(state, opts) do
    send(opts.listener_pid, %Events.ProviderResponseStart{model: state.model})

    stream_req =
      Finch.build(
        :post,
        state.base_url <> state.endpoint,
        [{"content-type", "application/json"}],
        build_req_body(
          state.model,
          state.system_prompt,
          opts.messages,
          opts.tools,
          state.reasoning_effort
        )
      )
      |> Finch.stream(
        Eva.Finch,
        %StreamState{},
        fn event, acc -> handle_stream_event(event, acc, opts.listener_pid) end,
        receive_timeout: 15_000
      )

    emit_stream_outcome(stream_req, opts.listener_pid)
  end

  defp handle_stream_event({:status, status}, stream_state, _listener_pid) do
    %{stream_state | status: status}
  end

  defp handle_stream_event({:headers, _}, stream_state, _listener_pid) do
    stream_state
  end

  defp handle_stream_event({:trailers, _}, stream_state, _listener_pid) do
    stream_state
  end

  defp handle_stream_event({:data, data}, stream_state, listener_pid) do
    {new_state, events} = StreamState.feed(stream_state, data)
    emit_events(events, listener_pid)
    new_state
  end

  defp emit_events(events, pid) do
    Enum.each(events, fn
      {:content, text} -> send(pid, %Events.ProviderTextDelta{delta: text})
      {:thinking, text} -> send(pid, %Events.ProviderThinkingDelta{delta: text})
    end)
  end

  defp emit_stream_outcome(
         {:ok,
          %StreamState{content_rev: _cr, finish_reason: _fr, status: s, tool_calls: _tcs} = ss},
         pid
       )
       when s != nil and s >= 400 do
    body = ss |> Map.get(:body_rev, []) |> Enum.reverse() |> Enum.join("")
    msg = "HTTP #{s}" <> if(body != "", do: ": #{body}", else: "")

    send(pid, %Events.ProviderError{message: msg, data: %{status: s, body: body}})
  end

  defp emit_stream_outcome(
         {:ok, %StreamState{content_rev: cr, finish_reason: fr, tool_calls: tcs}},
         pid
       ) do
    tool_calls = StreamState.build_tool_calls(tcs)

    Enum.each(tool_calls, fn tool_call ->
      send(pid, %Events.ProviderToolCall{tool_call: tool_call})
    end)

    send(pid, %Events.ProviderResponseEnd{
      message: %Messages.AssistantMessage{
        content: cr |> Enum.reverse() |> Enum.join(""),
        tool_calls: tool_calls
      },
      finish_reason: fr
    })
  end

  defp emit_stream_outcome({:error, error, _}, pid) do
    send(pid, %Events.ProviderError{message: "Transport error: #{inspect(error)}"})
  end

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

  defp build_req_body(model, system_prompt, messages, tools, reasoning_effort) do
    body = %{
      model: model,
      messages: build_messages(system_prompt, messages),
      tools: Enum.map(tools, &serialize_tool/1),
      stream: true
    }

    body =
      if reasoning_effort,
        do: Map.merge(body, %{reasoning_effort: reasoning_effort}),
        else: body

    JSON.encode!(body)
  end

  defp build_messages(system_prompt, messages) do
    system = if system_prompt, do: [%{role: "system", content: system_prompt}], else: []

    serialized =
      Enum.map(messages, fn
        %Messages.UserMessage{content: c} ->
          %{role: "user", content: c}

        %Messages.AssistantMessage{content: c, tool_calls: tool_calls} ->
          message = %{role: "assistant", content: c}
          tool_calls = Enum.reject(tool_calls, &is_nil/1)

          if tool_calls != [] do
            serialized_tcs =
              Enum.map(tool_calls, fn %Tools.ToolCall{id: id, name: name, arguments: args} ->
                %{
                  id: id,
                  type: "function",
                  function: %{
                    name: name,
                    arguments: encode_arguments(args)
                  }
                }
              end)

            Map.put(message, :tool_calls, serialized_tcs)
          else
            message
          end

        %Messages.ToolResultMessage{
          tool_call_id: id,
          name: name,
          content: c,
          data: data,
          details: details
        } ->
          result = %{role: "tool", tool_call_id: id, content: c}

          result
          |> maybe_put(:name, name)
          |> maybe_put(:data, data)
          |> maybe_put(:details, details)
      end)

    system ++ serialized
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp encode_arguments(args) when is_map(args), do: JSON.encode!(args)
  defp encode_arguments(args) when is_binary(args), do: args
  defp encode_arguments(_), do: "{}"
end
