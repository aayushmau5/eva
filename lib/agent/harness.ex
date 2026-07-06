defmodule Eva.Agent.Harness do
  use GenServer

  alias Eva.Agent.{Loop, Messages}

  # -- Public API --

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def prompt(pid \\ __MODULE__, prompt) do
    GenServer.call(pid, {:prompt, prompt})
  end

  def continue(pid \\ __MODULE__) do
    GenServer.call(pid, :continue)
  end

  def steer(pid \\ __MODULE__, content) do
    GenServer.call(pid, {:steer, content})
  end

  def follow_up(pid \\ __MODULE__, content) do
    GenServer.call(pid, {:follow_up, content})
  end

  def cancel(pid \\ __MODULE__) do
    GenServer.call(pid, :cancel)
  end

  def update_messages(pid \\ __MODULE__, messages) do
    GenServer.call(pid, {:update_messages, messages})
  end

  def update_tools(pid \\ __MODULE__, tools) do
    GenServer.call(pid, {:update_tools, tools})
  end

  def change_provider(pid \\ __MODULE__, provider_pid) do
    GenServer.call(pid, {:change_provider, provider_pid})
  end

  def get_state(pid \\ __MODULE__) do
    GenServer.call(pid, :get_state)
  end

  def has_queued_messages?(pid \\ __MODULE__) do
    GenServer.call(pid, :has_queued_messages?)
  end

  # -- GenServer --

  @impl true
  def init(opts) do
    provider_pid = Keyword.fetch!(opts, :provider_pid)
    tools = Keyword.get(opts, :tools, [])
    max_turns = Keyword.get(opts, :max_turns)
    messages = Keyword.get(opts, :messages, [])
    queue_mode = Keyword.get(opts, :queue_mode, :one_at_a_time)

    # Loop crash gets trapped ({:EXIT, ...}) so this process doesn't go down with it.
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       provider_pid: provider_pid,
       messages: messages,
       tools: tools,
       max_turns: max_turns,
       running?: false,
       looper: nil,
       steering_queue: [],
       follow_up_queue: [],
       queue_mode: queue_mode
     }}
  end

  @impl true
  def handle_call({:prompt, prompt}, _from, state) do
    if state.running? do
      {:reply, {:error, :already_running}, state}
    else
      state = repair_tool_calls(state)
      messages = state.messages ++ [%Messages.UserMessage{content: prompt}]
      state = run(%{state | messages: messages})
      {:reply, {:ok, state}, state}
    end
  end

  def handle_call(:continue, _from, state) do
    if state.running? do
      {:reply, {:error, :already_running}, state}
    else
      state = repair_tool_calls(state)
      state = run(state)
      {:reply, {:ok, state}, state}
    end
  end

  def handle_call({:steer, content}, _from, state) do
    message = %Messages.UserMessage{content: content}
    state = %{state | steering_queue: state.steering_queue ++ [message]}
    {:reply, :ok, state}
  end

  def handle_call({:follow_up, content}, _from, state) do
    message = %Messages.UserMessage{content: content}
    state = %{state | follow_up_queue: state.follow_up_queue ++ [message]}
    {:reply, :ok, state}
  end

  def handle_call(:cancel, _from, %{running?: true, looper: looper_pid} = state) do
    Process.exit(looper_pid, :kill)
    state = repair_tool_calls(state)
    {:reply, :ok, %{state | running?: false, looper: nil}}
  end

  def handle_call(:cancel, _from, state) do
    {:reply, :ok, state}
  end

  def handle_call(:has_queued_messages?, _from, state) do
    {:reply, state.steering_queue != [] or state.follow_up_queue != [], state}
  end

  # Called by Loop
  def handle_call({:drain_queue, :steering}, _from, state) do
    {messages, remaining} = drain_queue(state.steering_queue, state.queue_mode)
    {:reply, messages, %{state | steering_queue: remaining}}
  end

  # Called by Loop
  def handle_call({:drain_queue, :follow_up}, _from, state) do
    {messages, remaining} = drain_queue(state.follow_up_queue, state.queue_mode)
    {:reply, messages, %{state | follow_up_queue: remaining}}
  end

  def handle_call({:update_messages, messages}, _from, state) do
    state = %{state | messages: messages}
    {:reply, {:ok, state}, state}
  end

  def handle_call({:update_tools, tools}, _from, state) do
    state = %{state | tools: tools}
    {:reply, {:ok, state}, state}
  end

  def handle_call({:change_provider, provider_pid}, _from, state) do
    state = %{state | provider_pid: provider_pid}
    {:reply, {:ok, state}, state}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, {:ok, state}, state}
  end

  # -- handle_info --

  @impl true
  def handle_info({:EXIT, pid, _reason}, %{looper: pid} = state) do
    {:noreply, %{state | running?: false, looper: nil}}
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  # TODO: broadcast agent events to subscribers via pubsub
  def handle_info(%{__struct__: _mod} = _event, state) do
    {:noreply, state}
  end

  # -- Private --

  defp run(state) do
    harness_pid = self()

    pid =
      spawn_link(fn ->
        Loop.run(
          provider_pid: state.provider_pid,
          harness_pid: harness_pid,
          messages: state.messages,
          tools: state.tools,
          max_turns: state.max_turns
        )
      end)

    %{state | looper: pid, running?: true}
  end

  defp drain_queue([], _mode), do: {[], []}

  defp drain_queue(queue, :one_at_a_time) do
    [head | tail] = queue
    {[head], tail}
  end

  defp drain_queue(queue, :all) do
    {queue, []}
  end

  # When a run is cancelled mid-tool-call, the transcript is left dangling —
  # it has an AssistantMessage with tool calls but no matching ToolResultMessage for them.
  # Providers reject that as malformed.
  # This function walks backward from the tail, finds the last assistant message with open tool calls,
  # and synthesizes failure ToolResultMessage stubs ("Tool call interrupted by user") for any missing results.
  # This lets the next prompt or continue start with a valid transcript.
  defp repair_tool_calls(%{messages: messages} = state) do
    case latest_open_tool_call_assistant_index(messages) do
      nil ->
        state

      index ->
        assistant = Enum.at(messages, index)

        case assistant do
          %Messages.AssistantMessage{tool_calls: tool_calls} ->
            returned_ids =
              messages
              |> Enum.drop(index + 1)
              |> Enum.filter(&match?(%Messages.ToolResultMessage{}, &1))
              |> MapSet.new(& &1.tool_call_id)

            repaired =
              tool_calls
              |> Enum.reject(&MapSet.member?(returned_ids, &1.id))
              |> Enum.map(fn tc ->
                %Messages.ToolResultMessage{
                  tool_call_id: tc.id,
                  name: tc.name,
                  content: "Tool call interrupted by user",
                  ok: false,
                  error: "Tool call interrupted by user"
                }
              end)

            %{state | messages: messages ++ repaired}

          _ ->
            state
        end
    end
  end

  # Walk backward from the tail to find the last AssistantMessage with
  # unresolved tool calls. If a UserMessage appears first, the run completed
  # cleanly before being interrupted — no repair needed.
  defp latest_open_tool_call_assistant_index(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.reduce_while(nil, fn
      {%Messages.UserMessage{}, _i}, _acc -> {:halt, nil}
      {%Messages.AssistantMessage{tool_calls: [_ | _]}, i}, _acc -> {:halt, i}
      _, _acc -> {:cont, nil}
    end)
  end
end
