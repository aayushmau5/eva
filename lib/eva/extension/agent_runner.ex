defmodule Eva.Extension.AgentRunner do
  @moduledoc """
  Runs one child agent for an extension.

  Owns a provider and a `Harness`, points the harness's event stream at itself, and
  relays it to whoever asked for the agent. Relaying rather than pointing the harness
  straight at the caller matters twice over: events get tagged with a `ref` so several
  agents can run at once, and they arrive as tuples rather than bare event structs —
  `Eva.Extension.Server` routes bare structs to `handle_event/2`, where they would be
  indistinguishable from the extension's own bus subscriptions.

  The receiver gets:

      {:agent_event, ref, event}     every harness event, as it happens
      {:agent_done, ref, messages}   the full transcript, once
      {:agent_failed, ref, reason}   the run died

  Supervised rather than linked to its caller: a tool executor is long gone by the
  time a background agent finishes, and linking to the loop would be wrong for both
  shapes. Instead the runner *monitors* its receiver and stops when that goes away, so
  an extension shutting down still takes its agents with it.
  """

  use GenServer, restart: :temporary

  alias Eva.AI.OpenAICompatibleProvider
  alias Eva.Agent.{Events, Harness, Messages}

  @agent_events Events.modules()

  @type opts :: %{
          required(:prompt) => String.t(),
          required(:provider_config) => term(),
          required(:reply_to) => pid(),
          optional(:model) => String.t(),
          optional(:system_prompt) => String.t(),
          optional(:tools) => [Eva.Agent.Tools.AgentTool.t()],
          optional(:max_turns) => pos_integer() | nil
        }

  def child_spec({ref, opts}) do
    %{id: {__MODULE__, ref}, start: {__MODULE__, :start_link, [{ref, opts}]}, restart: :temporary}
  end

  @spec start_link({reference(), opts()}) :: GenServer.on_start()
  def start_link({ref, opts}) do
    GenServer.start_link(__MODULE__, {ref, opts}, name: via(ref))
  end

  @doc "Finds a running agent by the ref `spawn_agent/2` handed out."
  @spec whereis(reference()) :: pid() | nil
  def whereis(ref) do
    case Registry.whereis_name({Eva.Extension.AgentRegistry, ref}) do
      :undefined -> nil
      pid -> pid
    end
  end

  @doc "Stops a running agent. Stopping one that already finished is fine."
  @spec stop(reference() | pid()) :: :ok
  def stop(ref) when is_reference(ref) do
    case whereis(ref) do
      nil -> :ok
      pid -> stop(pid)
    end
  end

  def stop(pid) when is_pid(pid) do
    # Bounded: a runner wedged in `terminate/2` must not hold up whoever cancelled it.
    GenServer.stop(pid, :normal, 5_000)
  catch
    :exit, _ ->
      Process.exit(pid, :kill)
      :ok
  end

  @impl true
  def init({ref, opts}) do
    reply_to = Map.fetch!(opts, :reply_to)

    # A provider or harness dying should reach the caller as `{:agent_failed, _, _}`
    # rather than silently taking this process down with it.
    Process.flag(:trap_exit, true)

    # If whoever is waiting on this agent goes away, so does the agent.
    Process.monitor(reply_to)

    state = %{ref: ref, reply_to: reply_to, opts: opts, provider: nil, harness: nil}
    {:ok, state, {:continue, :run}}
  end

  @impl true
  def handle_continue(:run, state) do
    with {:ok, provider} <- start_provider(state.opts),
         {:ok, harness} <- start_harness(provider, state.opts),
         {:ok, _} <- Harness.prompt(harness, %Messages.UserMessage{content: state.opts.prompt}) do
      {:noreply, %{state | provider: provider, harness: harness}}
    else
      {:error, reason} ->
        send(state.reply_to, {:agent_failed, state.ref, reason})
        {:stop, :normal, state}
    end
  end

  @impl true
  def handle_info(%Events.AgentEnd{messages: messages} = event, state) do
    send(state.reply_to, {:agent_event, state.ref, event})
    send(state.reply_to, {:agent_done, state.ref, messages})
    {:stop, :normal, state}
  end

  def handle_info(%{__struct__: module} = event, state) when module in @agent_events do
    send(state.reply_to, {:agent_event, state.ref, event})
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{reply_to: pid} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, _pid, reason}, state) when reason in [:normal, :shutdown] do
    {:noreply, state}
  end

  def handle_info({:EXIT, _pid, reason}, state) do
    send(state.reply_to, {:agent_failed, state.ref, reason})
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Both are linked, so they would follow anyway — stopping them explicitly means a
    # cancelled run does not hold a provider connection open while the link propagates.
    stop_child(state.harness)
    stop_child(state.provider)
    :ok
  end

  # -- Private --

  defp via(ref), do: {:via, Registry, {Eva.Extension.AgentRegistry, ref}}

  defp start_provider(opts) do
    case OpenAICompatibleProvider.start_link(config: Map.fetch!(opts, :provider_config)) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, {:provider_failed, reason}}
    end
  end

  defp start_harness(provider, opts) do
    Harness.start_link(
      provider_pid: provider,
      # Every loop event lands here rather than in a session — this is what makes a
      # bare harness usable with none of the session machinery around it.
      coding_session_pid: self(),
      model: Map.get(opts, :model, ""),
      system_prompt: Map.get(opts, :system_prompt, ""),
      tools: Map.get(opts, :tools, []),
      max_turns: Map.get(opts, :max_turns)
    )
  end

  defp stop_child(nil), do: :ok

  defp stop_child(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    :ok
  catch
    :exit, _ -> :ok
  end
end
