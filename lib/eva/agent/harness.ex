defmodule Eva.Agent.Harness do
  use GenServer

  alias Eva.Agent.{Events, Loop, Messages, Tools}

  @event_modules [
    Events.AgentStart,
    Events.AgentEnd,
    Events.TurnStart,
    Events.TurnEnd,
    Events.MessageStart,
    Events.MessageUpdate,
    Events.MessageEnd,
    Events.ToolExecutionStart,
    Events.ToolExecutionUpdate,
    Events.ToolExecutionEnd
  ]

  @type option ::
          {:provider_pid, pid()}
          | {:coding_session_pid, pid()}
          | {:model, String.t()}
          | {:system_prompt, String.t()}
          | {:tools, [Tools.AgentTool.t()]}
          | {:max_turns, pos_integer() | nil}
          | {:messages, [Eva.Agent.Messages.t()]}
          | {:queue_mode, :one_at_a_time | :all}
          | {:before_tool_call, Loop.before_tool_callback()}
          | {:after_tool_call, Loop.after_tool_callback()}
          | {:name, atom()}

  @type options :: [option()]

  # -- Public API --

  @spec start_link(options()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec prompt(GenServer.server(), Messages.agent_message()) ::
          {:ok, map()} | {:error, :already_running}
  def prompt(pid \\ __MODULE__, prompt) do
    GenServer.call(pid, {:prompt, prompt})
  end

  @spec continue(GenServer.server()) :: {:ok, map()} | {:error, :already_running}
  def continue(pid \\ __MODULE__) do
    GenServer.call(pid, :continue)
  end

  @spec tools(GenServer.server()) :: [Eva.Agent.Tools.tool()]
  def tools(pid \\ __MODULE__) do
    GenServer.call(pid, :tools)
  end

  @spec messages(pid()) :: [Eva.Agent.Messages.t()]
  def messages(pid \\ __MODULE__) do
    GenServer.call(pid, :messages)
  end

  @spec running?(pid()) :: boolean()
  def running?(pid \\ __MODULE__) do
    GenServer.call(pid, :running_status)
  end

  @spec steer(GenServer.server(), Messages.agent_message()) :: :ok
  def steer(pid \\ __MODULE__, message) do
    GenServer.call(pid, {:steer, message})
  end

  @spec follow_up(GenServer.server(), Messages.agent_message()) :: :ok
  def follow_up(pid \\ __MODULE__, message) do
    GenServer.call(pid, {:follow_up, message})
  end

  @spec cancel(GenServer.server()) :: :ok
  def cancel(pid \\ __MODULE__) do
    GenServer.call(pid, :cancel)
  end

  @spec update_messages(GenServer.server(), [Messages.t()]) :: {:ok, map()}
  def update_messages(pid \\ __MODULE__, messages) do
    GenServer.call(pid, {:update_messages, messages})
  end

  @spec update_tools(GenServer.server(), [any()]) :: {:ok, map()}
  def update_tools(pid \\ __MODULE__, tools) do
    GenServer.call(pid, {:update_tools, tools})
  end

  @spec change_provider(GenServer.server(), pid()) :: {:ok, map()}
  def change_provider(pid \\ __MODULE__, provider_pid) do
    GenServer.call(pid, {:change_provider, provider_pid})
  end

  @spec get_state(GenServer.server()) :: {:ok, map()}
  def get_state(pid \\ __MODULE__) do
    GenServer.call(pid, :get_state)
  end

  @spec has_queued_messages?(GenServer.server()) :: boolean()
  def has_queued_messages?(pid \\ __MODULE__) do
    GenServer.call(pid, :has_queued_messages?)
  end

  @spec pop_latest_steering(GenServer.server()) :: Messages.agent_message() | nil
  def pop_latest_steering(pid \\ __MODULE__) do
    GenServer.call(pid, :pop_latest_steering)
  end

  @spec pop_latest_follow_up(GenServer.server()) :: Messages.agent_message() | nil
  def pop_latest_follow_up(pid \\ __MODULE__) do
    GenServer.call(pid, :pop_latest_follow_up)
  end

  @spec clear_queues(GenServer.server()) :: %{
          steering: [Messages.agent_message()],
          follow_up: [Messages.agent_message()]
        }
  def clear_queues(pid \\ __MODULE__) do
    GenServer.call(pid, :clear_queues)
  end

  @spec pending_message_count(GenServer.server()) :: non_neg_integer()
  def pending_message_count(pid \\ __MODULE__) do
    GenServer.call(pid, :pending_message_count)
  end

  @spec queued_messages(GenServer.server()) :: %{
          steering: [Messages.agent_message()],
          follow_up: [Messages.agent_message()]
        }
  def queued_messages(pid \\ __MODULE__) do
    GenServer.call(pid, :queued_messages)
  end

  # -- GenServer --

  @impl true
  def init(opts) do
    provider_pid = Keyword.fetch!(opts, :provider_pid)
    coding_session_pid = Keyword.get(opts, :coding_session_pid)
    tools = Keyword.get(opts, :tools, [])
    max_turns = Keyword.get(opts, :max_turns)
    messages = Keyword.get(opts, :messages, [])
    queue_mode = Keyword.get(opts, :queue_mode, :one_at_a_time)
    system_prompt = Keyword.get(opts, :system_prompt, "")
    model = Keyword.get(opts, :model, "")
    before_tool_call = Keyword.get(opts, :before_tool_call)
    after_tool_call = Keyword.get(opts, :after_tool_call)

    # Loop crash gets trapped ({:EXIT, ...}) so this process doesn't go down with it.
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       provider_pid: provider_pid,
       coding_session_pid: coding_session_pid,
       system_prompt: system_prompt,
       model: model,
       messages: messages,
       tools: tools,
       max_turns: max_turns,
       running?: false,
       agent_loop: nil,
       steering_queue: [],
       follow_up_queue: [],
       queue_mode: queue_mode,
       before_tool_call: before_tool_call,
       after_tool_call: after_tool_call
     }}
  end

  @impl true
  def handle_call({:prompt, prompt}, _from, state) do
    if state.running? do
      {:reply, {:error, :already_running}, state}
    else
      state = repair_tool_calls(state)
      state = run([prompt], state)
      {:reply, {:ok, state}, state}
    end
  end

  def handle_call(:continue, _from, state) do
    if state.running? do
      {:reply, {:error, :already_running}, state}
    else
      state = repair_tool_calls(state)
      state = run([], state)
      {:reply, {:ok, state}, state}
    end
  end

  def handle_call({:steer, message}, _from, state) do
    state = %{state | steering_queue: state.steering_queue ++ [message]}
    {:reply, :ok, state}
  end

  def handle_call({:follow_up, message}, _from, state) do
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

  def handle_call(:tools, _from, state) do
    {:reply, state.tools, state}
  end

  def handle_call(:messages, _from, state) do
    {:reply, state.messages, state}
  end

  @impl true
  def handle_call(:running_status, _from, state) do
    {:reply, state.running?, state}
  end

  def handle_call(:has_queued_messages?, _from, state) do
    {:reply, state.steering_queue != [] or state.follow_up_queue != [], state}
  end

  def handle_call(:pop_latest_steering, _from, state) do
    case state.steering_queue do
      [] -> {:reply, nil, state}
      queue -> {:reply, List.last(queue), %{state | steering_queue: Enum.drop(queue, -1)}}
    end
  end

  def handle_call(:pop_latest_follow_up, _from, state) do
    case state.follow_up_queue do
      [] -> {:reply, nil, state}
      queue -> {:reply, List.last(queue), %{state | follow_up_queue: Enum.drop(queue, -1)}}
    end
  end

  def handle_call(:clear_queues, _from, state) do
    snapshot = %{steering: state.steering_queue, follow_up: state.follow_up_queue}
    {:reply, snapshot, %{state | steering_queue: [], follow_up_queue: []}}
  end

  def handle_call(:pending_message_count, _from, state) do
    {:reply, length(state.steering_queue) + length(state.follow_up_queue), state}
  end

  def handle_call(:queued_messages, _from, state) do
    {:reply, %{steering: state.steering_queue, follow_up: state.follow_up_queue}, state}
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

  def handle_info(%{__struct__: mod} = event, state) when mod in @event_modules do
    if state.coding_session_pid, do: send(state.coding_session_pid, event)
    {:noreply, state}
  end

  def handle_info(%{__struct__: _mod} = _event, state) do
    {:noreply, state}
  end

  # -- Private --

  defp run(prompts, state) do
    harness_pid = self()

    pid =
      spawn_link(fn ->
        Loop.run(
          provider_pid: state.provider_pid,
          harness_pid: harness_pid,
          model: state.model,
          system_prompt: state.system_prompt,
          messages: state.messages,
          prompts: prompts,
          tools: state.tools,
          max_turns: state.max_turns,
          before_tool_call: state.before_tool_call,
          after_tool_call: state.after_tool_call
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
  # it has AssistantMessages with tool calls but no matching ToolResultMessages for them.
  # Providers reject that as malformed.
  # This walks all messages, finds every assistant tool call that lacks a result,
  # and synthesizes failure ToolResultMessage stubs ("Tool call interrupted by user").
  # This lets the next prompt or continue start with a valid transcript.
  defp repair_tool_calls(%{messages: messages} = state) do
    returned_ids =
      messages
      |> Enum.filter(&match?(%Messages.ToolResultMessage{}, &1))
      |> MapSet.new(& &1.tool_call_id)

    repaired =
      messages
      |> Enum.flat_map(fn
        %Messages.AssistantMessage{} = message ->
          Messages.AssistantMessage.tool_calls(message)
          |> Enum.reject(&MapSet.member?(returned_ids, &1.id))
          |> Enum.map(fn tc ->
            %Messages.ToolResultMessage{
              tool_call_id: tc.id,
              tool_name: tc.name,
              content: %Messages.TextContent{text: "Tool call interrupted by user"},
              is_error: true
            }
          end)

        _ ->
          []
      end)

    %{state | messages: messages ++ repaired}
  end
end
