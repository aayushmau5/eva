defmodule Eva.AI.LmStudio do
  use GenServer

  alias Eva.AI.{Sse, Events}
  alias Eva.AI.Config

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

  @impl true
  def handle_cast({:run, prompt, listener_pid}, state) do
    # TODO: think if we need listener_pid here or perhaps at init? Architectural decision.
    Task.start(fn -> stream(state, prompt, listener_pid) end)
    {:noreply, state}
  end

  defp stream(%Config{} = config, prompt, listener_pid) do
    send(listener_pid, %Events.ProviderResponseStart{model: config.model})

    {_req, resp} = do_run(config, prompt)

    case resp do
      %Req.Response{status: status} when status >= 400 ->
        send(listener_pid, %Events.ProviderError{
          message: "HTTP #{status}",
          data: %{status: status}
        })

      %Req.Response{body: %Req.Response.Async{}} ->
        {content_rev, finish_reason} = consume_body(resp, listener_pid)

        send(listener_pid, %Events.ProviderResponseEnd{
          message: %{content: Enum.join(Enum.reverse(content_rev), "")},
          finish_reason: finish_reason
        })

      error ->
        send(listener_pid, %Events.ProviderError{
          message: "Transport error: #{inspect(error)}"
        })
    end
  end

  defp consume_body(resp, listener_pid) do
    Enum.reduce(resp.body, {[], nil}, fn data, acc ->
      data
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.reduce(acc, &process_sse_line(&1, &2, listener_pid))
    end)
  end

  defp do_run(%Config{} = config, prompt) do
    Req.run(
      config.base_url <> config.endpoint,
      json: %{
        model: config.model,
        messages: [
          %{role: "system", content: config.system_prompt},
          %{role: "user", content: prompt}
        ],
        stream: true
      },
      into: :self,
      http_errors: :return,
      retry: false
    )
  end

  defp process_sse_line(line, {parts, reason} = acc, listener_pid) do
    case Sse.parse(line) do
      :done ->
        acc

      {:line, json} ->
        delta = Sse.parse_delta(json)

        reason = delta.finish_reason || reason

        parts =
          if is_binary(delta.content) and delta.content != "" do
            send(listener_pid, %Events.ProviderTextDelta{delta: delta.content})
            [delta.content | parts]
          else
            parts
          end

        parts =
          if is_binary(delta.thinking) and delta.thinking != "" do
            send(listener_pid, %Events.ProviderThinkingDelta{delta: delta.thinking})
            parts
          end

        {parts, reason}
    end
  rescue
    _ -> acc
  end
end
