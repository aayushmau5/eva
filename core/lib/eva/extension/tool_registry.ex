defmodule Eva.Extension.ToolRegistry do
  @moduledoc """
  Keeps tool executors on the node that defined them, and runs them there on request.

  A closure is not code. It is a reference to *(module, index, hash)* plus whatever it
  captured, so calling one requires its defining module on the receiving side. An
  extension's modules are its own — that is the entire point of running it on its own node
  — so a `%AgentTool{executor: fn ... end}` sent to the host fails with `badfun`.

  So the closure never leaves. `Eva.Extension.API.update_tools/2` puts it here and sends
  the host a description with `executor: nil`; the host binds a proxy of its own that calls
  back to `{Eva.Extension.ToolRegistry, node}`. The extension author writes
  `executor: fn args, ctx -> ... end` and none of this is visible to them.

  ## Keyed by session

  One node serves every session, and `setup/1` runs per session — so two sessions using the
  same extension can have executors that captured different things. Keying by extension
  name alone would let the second session's registration wipe the first one's tools, so the
  session is part of the key.

  Sessions are monitored, and a session going away takes its executors with it. That covers
  the ordinary end of a session and an Eva that crashed, without either having to remember.

  Started by `eva_core`'s application, so it exists wherever extensions run — including
  in-VM, where it simply never gets used.
  """

  use GenServer

  alias Eva.Agent.Tools

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Swaps executors for descriptions, keeping the originals here.

  Replaces whatever this extension had registered for this session, because
  `update_tools/2` replaces rather than appends — a tool that goes away must not leave a
  callable closure behind.
  """
  @spec register(String.t(), pid(), [Tools.AgentTool.t()]) :: [Tools.AgentTool.t()]
  def register(extension, session_pid, tools) when is_list(tools) do
    executors =
      for %Tools.AgentTool{executor: executor, name: name} <- tools,
          is_function(executor, 2),
          into: %{},
          do: {name, executor}

    :ok = GenServer.call(__MODULE__, {:register, extension, session_pid, executors})

    Enum.map(tools, fn
      %Tools.AgentTool{executor: executor} = tool when is_function(executor, 2) ->
        %Tools.AgentTool{tool | executor: nil}

      %Tools.AgentTool{} = tool ->
        tool
    end)
  end

  @doc """
  Runs a registered executor.

  The reply comes from a task, never from this process: a tool can take minutes, and a
  registry that ran them inline would serialize every tool on the node behind the slowest
  one — including the registrations an extension makes while it is working.
  """
  @spec run(String.t(), pid(), String.t(), map(), term()) :: {:ok, term()} | {:error, String.t()}
  def run(extension, session_pid, tool, arguments, exec_context) do
    GenServer.call(
      __MODULE__,
      {:run, extension, session_pid, tool, arguments, exec_context},
      :infinity
    )
  end

  @doc """
  What this session has registered for an extension. For tests and for looking.
  """
  @spec tools(String.t(), pid()) :: [String.t()]
  def tools(extension, session_pid) do
    GenServer.call(__MODULE__, {:tools, extension, session_pid})
  end

  @impl true
  def init(_opts), do: {:ok, %{executors: %{}, monitored: %{}}}

  @impl true
  def handle_call({:register, extension, session_pid, executors}, _from, state) do
    state =
      state
      |> monitor_session(session_pid)
      |> put_in([:executors, {extension, session_pid}], executors)

    {:reply, :ok, state}
  end

  def handle_call({:run, extension, session_pid, tool, arguments, exec_context}, from, state) do
    case get_in(state.executors, [{extension, session_pid}, tool]) do
      nil ->
        {:reply, {:error, "#{extension} has no registered tool named #{tool}"}, state}

      executor ->
        run_in_task(executor, arguments, exec_context, from)
        {:noreply, state}
    end
  end

  def handle_call({:tools, extension, session_pid}, _from, state) do
    tools = state.executors |> Map.get({extension, session_pid}, %{}) |> Map.keys()
    {:reply, Enum.sort(tools), state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    executors =
      state.executors
      |> Enum.reject(fn {{_extension, session_pid}, _executors} -> session_pid == pid end)
      |> Map.new()

    {:noreply, %{state | executors: executors, monitored: Map.delete(state.monitored, pid)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # -- Private --

  defp monitor_session(state, session_pid) do
    if Map.has_key?(state.monitored, session_pid) do
      state
    else
      put_in(state.monitored[session_pid], Process.monitor(session_pid))
    end
  end

  defp run_in_task(executor, arguments, exec_context, from) do
    Task.start(fn ->
      result =
        try do
          {:ok, executor.(arguments, exec_context)}
        rescue
          e -> {:error, Exception.message(e)}
        catch
          kind, reason -> {:error, Exception.format(kind, reason)}
        end

      GenServer.reply(from, result)
    end)
  end
end
