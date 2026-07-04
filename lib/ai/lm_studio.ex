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
  def init(_opts) do
    config = %Config{
      base_url: @base_url,
      endpoint: @endpoint,
      model: @model,
      system_prompt: @system_prompt
    }

    {:ok, config}
  end

  @impl true
  def handle_call({:change_config, config}, _from, _state) do
    {:reply, :ok, config}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast({:run, prompt, listener_pid}, state) do
    Task.start(fn -> stream(state, prompt, listener_pid) end)
    {:noreply, state}
  end

  defp stream(%Config{} = config, prompt, listener_pid) do
    send(listener_pid, %Events.ProviderResponseStart{model: config.model})

    body =
      JSON.encode!(%{
        model: config.model,
        messages: [
          %{role: "system", content: config.system_prompt},
          %{role: "user", content: prompt}
        ],
        stream: true
      })

    request =
      Finch.build(
        :post,
        config.base_url <> config.endpoint,
        [{"content-type", "application/json"}],
        body
      )

    state = %StreamState{}

    stream_req =
      Finch.stream(
        request,
        Eva.Finch,
        state,
        fn
          {:status, status}, state ->
            %{state | status: status}

          {:headers, _}, state ->
            state

          {:trailers, _}, state ->
            state

          {:data, data}, %StreamState{status: status} = state when status == nil or status < 400 ->
            full_text = state.buffer <> data
            lines = String.split(full_text, "\n")

            {content_rev, finish_reason} =
              Enum.reduce(lines, {state.content_rev, state.finish_reason}, fn
                "data: " <> _ = line, {cr, fr} ->
                  parse_sse_line(line, cr, fr, listener_pid)

                _, pair ->
                  pair
              end)

            last = List.last(lines) || ""
            buffer = if String.starts_with?(last, "data:"), do: "", else: last

            %{state | content_rev: content_rev, finish_reason: finish_reason, buffer: buffer}

          {:data, _data}, state ->
            state
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
