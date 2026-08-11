defmodule Eva.Core.Extension.Agents do
  @moduledoc """
  Runs child agents on an extension's behalf.

  This is how a subagent extension delegates — "research this", "check that" — without
  reaching into `Eva.Agent.Harness` itself. Dispatches through `Context.capabilities`
  like every other capability, so an extension written against it keeps working
  wherever it happens to be running.

  Two shapes, and the difference matters:

    * `run_agent/2` blocks until the child finishes. Call it from a **tool executor**,
      which runs in the loop's process and has no deadline. Simplest thing that works,
      and what a foreground `agent` tool wants.

    * `spawn_agent/2` returns immediately with a `ref`. Results arrive as messages at
      the extension's own process, so it needs `handle_info/2`. For background work
      the model shouldn't wait on.

  ## Depth

  An extension that hands its own agent tool to a child creates a loop: the child
  calls the tool, which reaches the same extension, which spawns another child. Pass
  `depth: depth + 1` when you build the tools for a child, and these functions refuse
  once it reaches `max_depth/0`. Nothing else can enforce it — only the extension
  knows whether it handed its own tool down.

  ## Tools

  A child gets exactly the tools you pass, and nothing by default. Resist inheriting
  the parent's set: a background child would inherit hooks like a permission gate and
  start asking the user questions about work they are not watching.
  """

  alias Eva.Core.Extension.Context

  @max_depth 30

  @type opts :: %{
          required(:prompt) => String.t(),
          optional(:model) => String.t(),
          optional(:system_prompt) => String.t(),
          optional(:tools) => [Eva.Core.Agent.Tools.AgentTool.t()],
          optional(:max_turns) => pos_integer() | nil,
          optional(:depth) => non_neg_integer(),
          optional(:timeout) => timeout(),
          optional(:on_event) => (Eva.Core.Agent.Events.t() -> any())
        }

  @doc "How deep a chain of agents may go before `spawn_agent/2` refuses."
  @spec max_depth() :: pos_integer()
  def max_depth, do: @max_depth

  @doc """
  Runs a child agent and waits for it.

  Blocks the calling process, so call it from a tool executor — never from a hook,
  where the five second budget applies, and never from a command handler, which would
  stall the extension for the whole run.

  `:timeout` defaults to five minutes; on expiry the child is stopped and
  `{:error, :timeout}` comes back.

  Pass `:on_event` to watch the child work — it fires for every harness event, which
  is where `Eva.Core.Agent.Tools.report_update/2` goes if you want the parent's tool row to
  show progress instead of sitting there.
  """
  @spec run_agent(Context.t(), opts()) ::
          {:ok, [Eva.Core.Agent.Messages.agent_message()]} | {:error, term()}
  def run_agent(%Context{} = ctx, opts) do
    timeout = Map.get(opts, :timeout, :timer.minutes(5))
    on_event = Map.get(opts, :on_event)

    with :ok <- check_depth(opts),
         {:ok, ref, pid} <- start(ctx, opts, self()) do
      await(ctx, ref, pid, on_event, timeout)
    end
  end

  @doc """
  Starts a child agent and returns straight away.

  The extension's own process receives:

      {:agent_event, ref, event}     every harness event, as it happens
      {:agent_done, ref, messages}   the transcript, once
      {:agent_failed, ref, reason}   the run died

  They arrive at `handle_info/2` rather than `handle_event/2` — tuples, not bare event
  structs, so they cannot be confused with the bus subscriptions in the Spec.
  """
  @spec spawn_agent(Context.t(), opts()) :: {:ok, reference()} | {:error, term()}
  def spawn_agent(%Context{} = ctx, opts) do
    with :ok <- check_depth(opts),
         # Results go to the extension's process, not whoever called this — a tool
         # executor is gone long before a background agent finishes.
         {:ok, pid} <- extension_process(ctx),
         {:ok, ref, _runner} <- start(ctx, opts, pid) do
      {:ok, ref}
    end
  end

  @doc """
  Stops a running child agent. Stopping one that already finished is fine.
  """
  @spec stop_agent(Context.t(), reference()) :: :ok
  def stop_agent(%Context{capabilities: impl} = ctx, ref), do: impl.stop_agent(ctx, ref)

  # -- Private --

  defp start(%Context{capabilities: impl} = ctx, opts, reply_to) do
    impl.spawn_agent(ctx, Map.put(opts, :reply_to, reply_to))
  end

  defp check_depth(opts) do
    if Map.get(opts, :depth, 0) >= @max_depth do
      {:error, :max_depth_exceeded}
    else
      :ok
    end
  end

  defp extension_process(%Context{} = ctx) do
    case Eva.Core.Extension.API.whereis(ctx, ctx.name) do
      nil -> {:error, :no_extension_process}
      pid -> {:ok, pid}
    end
  end

  defp await(ctx, ref, pid, on_event, timeout) do
    monitor = Process.monitor(pid)
    result = receive_loop(ctx, ref, pid, monitor, on_event, timeout)
    Process.demonitor(monitor, [:flush])
    result
  end

  defp receive_loop(ctx, ref, pid, monitor, on_event, timeout) do
    receive do
      {:agent_done, ^ref, messages} ->
        {:ok, messages}

      {:agent_failed, ^ref, reason} ->
        {:error, reason}

      {:agent_event, ^ref, event} ->
        if on_event, do: safe_notify(on_event, event)
        receive_loop(ctx, ref, pid, monitor, on_event, timeout)

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, reason}
    after
      timeout ->
        # Through the capability, not the runner directly.
        stop_agent(ctx, ref)
        {:error, :timeout}
    end
  end

  # A caller's progress reporting must not be able to kill the run that produced it.
  defp safe_notify(fun, event) do
    fun.(event)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
