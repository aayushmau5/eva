defmodule Eva.AI.LmStudio do
  use GenServer

  alias Eva.AI.{Events, Config, StreamState}
  alias Eva.Agent

  @base_url "http://localhost:1234/v1"
  @endpoint "/chat/completions"
  @model "liquid/lfm2.5-1.2b"
  @system_prompt "You are a weather assistant. Always reply with weather is 20C"

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    system_prompt = Keyword.get(opts, :system_prompt, @system_prompt)
    reasoning_effort = Keyword.get(opts, :reasoning_effort)
    messages = Keyword.get(opts, :messages, [])
    tools = Keyword.get(opts, :tools, [])

    config = %Config{
      base_url: @base_url,
      endpoint: @endpoint,
      model: @model,
      system_prompt: @system_prompt
    }

    state = %{
      config: config,
      system_prompt: system_prompt,
      reasoning_effort: reasoning_effort,
      messages: messages,
      tools: tools
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:change_config, config}, _from, state) do
    {:reply, :ok, %{state | config: config}}
  end

  # Runtime system prompt change
  def handle_call({:change_system_prompt, system_prompt}, _from, state) do
    {:reply, :ok, %{state | system_prompt: system_prompt}}
  end

  def handle_call({:update_messages, messages}, _from, state) do
    {:reply, :ok, %{state | messages: messages}}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast({:run, listener_pid}, state) do
    # Should we do this?
    if length(state.messages) > 0 do
      Task.start(fn -> stream(state, listener_pid) end)
    end

    {:noreply, state}
  end

  defp stream(state, listener_pid) do
    send(listener_pid, %Events.ProviderResponseStart{model: state.config.model})

    stream_req =
      Finch.build(
        :post,
        state.config.base_url <> state.config.endpoint,
        [{"content-type", "application/json"}],
        build_req_body(state)
      )
      |> Finch.stream(
        Eva.Finch,
        %StreamState{},
        fn event, acc -> handle_stream_event(event, acc, listener_pid) end,
        receive_timeout: 15_000
      )

    emit_stream_outcome(stream_req, listener_pid)
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
         {:ok, %StreamState{content_rev: cr, finish_reason: fr, status: s, tool_calls: tcs}},
         pid
       ) do
    if s && s >= 400 do
      send(pid, %Events.ProviderError{message: "HTTP #{s}", data: %{status: s}})
    else
      tool_calls = StreamState.build_tool_calls(tcs)

      Enum.each(tool_calls, fn tool_call ->
        send(pid, %Events.ProviderToolCall{tool_call: tool_call})
      end)

      send(pid, %Events.ProviderResponseEnd{
        message: %Agent.Messages.AssistantMessage{
          content: cr |> Enum.reverse() |> Enum.join(""),
          tool_calls: tool_calls
        },
        finish_reason: fr
      })
    end
  end

  defp emit_stream_outcome({:error, error, _}, pid) do
    send(pid, %Events.ProviderError{message: "Transport error: #{inspect(error)}"})
  end

  defp build_req_body(state) do
    body = %{
      model: state.config.model,
      messages:
        [
          %{role: "system", content: state.system_prompt}
        ] ++ build_messages(state.messages),
      tools: state.tools,
      stream: true
    }

    body =
      if state.reasoning_effort,
        do: Map.merge(body, %{reasoning_effort: state.reasoning_effort}),
        else: body

    JSON.encode!(body)
  end

  defp build_messages(messages) do
    Enum.map(messages, fn message -> %{role: "user", content: message} end)
  end
end
