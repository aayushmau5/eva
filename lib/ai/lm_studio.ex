defmodule Eva.AI.LmStudio do
  use GenServer

  alias Eva.AI.{Sse, Events}
  alias Eva.AI.Config

  defmodule StreamState do
    defstruct content_rev: [], finish_reason: nil, buffer: "", status: nil
  end

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
    if length(state.messages) > 0 do
      Task.start(fn -> stream(state, listener_pid) end)
    end

    {:noreply, state}
  end

  defp stream(state, listener_pid) do
    send(listener_pid, %Events.ProviderResponseStart{model: state.config.model})

    stream_state = %StreamState{}

    stream_req =
      Finch.build(
        :post,
        state.config.base_url <> state.config.endpoint,
        [{"content-type", "application/json"}],
        build_req_body(state)
      )
      |> Finch.stream(
        Eva.Finch,
        stream_state,
        fn
          {:status, status}, stream_state ->
            %{stream_state | status: status}

          {:headers, _}, stream_state ->
            stream_state

          {:trailers, _}, stream_state ->
            stream_state

          {:data, data}, %StreamState{status: status} = stream_state
          when status == nil or status < 400 ->
            full_text = stream_state.buffer <> data
            lines = String.split(full_text, "\n")

            {content_rev, finish_reason} =
              Enum.reduce(lines, {stream_state.content_rev, stream_state.finish_reason}, fn
                "data: " <> _ = line, {cr, fr} ->
                  parse_sse_line(line, cr, fr, listener_pid)

                _, pair ->
                  pair
              end)

            last = List.last(lines) || ""
            buffer = if String.starts_with?(last, "data:"), do: "", else: last

            %{
              stream_state
              | content_rev: content_rev,
                finish_reason: finish_reason,
                buffer: buffer
            }

          {:data, _data}, stream_state ->
            stream_state
        end,
        receive_timeout: 15_000
      )

    case stream_req do
      {:ok, %StreamState{content_rev: content_rev, finish_reason: finish_reason, status: status}} ->
        if status && status >= 400 do
          send(listener_pid, %Events.ProviderError{
            message: "HTTP #{status}",
            data: %{status: status}
          })
        else
          send(listener_pid, %Events.ProviderResponseEnd{
            message: %{content: content_rev |> Enum.reverse() |> Enum.join("")},
            finish_reason: finish_reason
          })
        end

      {:error, error, _} ->
        send(listener_pid, %Events.ProviderError{
          message: "Transport error: #{inspect(error)}"
        })
    end
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

  defp parse_sse_line(line, content_rev, finish_reason, listener_pid) do
    case Sse.parse(line) do
      :done ->
        {content_rev, finish_reason}

      {:line, json} ->
        delta = Sse.parse_delta(json)
        finish_reason = delta.finish_reason || finish_reason

        content_rev =
          if is_binary(delta.content) and delta.content != "" do
            send(listener_pid, %Events.ProviderTextDelta{delta: delta.content})
            [delta.content | content_rev]
          else
            content_rev
          end

        if is_binary(delta.thinking) and delta.thinking != "" do
          send(listener_pid, %Events.ProviderThinkingDelta{delta: delta.thinking})
        end

        {content_rev, finish_reason}
    end
  rescue
    _ -> {content_rev, finish_reason}
  end
end
