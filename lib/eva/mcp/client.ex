defmodule Eva.MCP.Client do
  use GenServer
  use TypedStruct

  require Logger

  alias Eva.MCP.{Config, Events, Protocol, Transport, Transports}

  @registry Eva.MCP.Registry

  @base_backoff_ms 1_000
  @max_backoff_ms 30_000
  @method_not_found -32_601

  @typedoc """
  Field names deliberately mirror `Events.ServerConnected` and
  `Events.ToolsDiscovered` so a subscriber can feed the sync catch-up and the
  async events into one update function.
  """
  @type snapshot :: %{
          server_name: String.t(),
          scope_dir: Events.scope_dir(),
          status: :connecting | :connected | :needs_auth | :failed,
          server_version: String.t() | nil,
          protocol_version: String.t() | nil,
          capabilities: Protocol.capabilities() | %{},
          tools: [Events.tool()]
        }

  typedstruct module: State do
    field :config, Config.t()
    field :transport, Transport.Stdio.t()
    field :status, :connecting | :connected | :needs_auth | :failed, default: :connecting
    field :pending, map(), default: %{}
    field :next_id, non_neg_integer(), default: 1
    field :tools, [Events.tool()], default: []
    field :server_info, map()
    field :attempt, non_neg_integer(), default: 0
  end

  @spec start_link(Config.t()) :: GenServer.on_start()
  def start_link(%Config{} = config) do
    GenServer.start_link(__MODULE__, config, name: via_tuple(config))
  end

  @spec whereis(Config.t()) :: pid() | nil
  def whereis(%Config{scope_dir: scope_dir, name: name} = _config) do
    case Registry.lookup(@registry, {scope_dir, name}) do
      [] -> nil
      [{pid, _}] -> pid
    end
  end

  @spec list_tools(pid()) :: [Events.tool()]
  def list_tools(pid) do
    GenServer.call(pid, :list_tools)
  end

  @spec call_tool(pid(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def call_tool(pid, name, args) do
    GenServer.call(pid, {:call_tool, name, args})
  end

  @spec call_tool_async(pid(), String.t(), map(), pid()) :: {:ok, reference()} | {:error, term()}
  def call_tool_async(pid, name, args, receiver_pid) do
    GenServer.call(pid, {:call_tool_async, name, args, receiver_pid})
  end

  @doc """
  Current server state, for a session that subscribed after the fact.

  Clients outlive sessions, so a new session usually joins a `:pg` group whose
  `ServerConnected`/`ToolsDiscovered` already fired and never will again. This
  is the catch-up.

  Answered straight from state — it never touches the wire, so subscribing to a
  hung server can't block `Session.handle_continue/2`.
  """
  @spec snapshot(pid()) :: snapshot()
  def snapshot(pid) do
    GenServer.call(pid, :snapshot)
  end

  @impl true
  def init(config) do
    # Trapping exit calls `terminate/2` to clean up
    Process.flag(:trap_exit, true)

    state = %State{config: config}

    {:ok, state, {:continue, :connect}}
  end

  # Spawning the server and completing the MCP handshake are two different
  # things. This only gets us a live transport — the connection is not usable
  # until `initialize` comes back and `notifications/initialized` goes out, so
  # the status stays `:connecting` throughout.
  @impl true
  def handle_continue(:connect, %State{} = state) do
    case Transports.connect(state.config) do
      {:ok, transport} -> send_initialize(%State{state | transport: transport})
      {:error, reason} -> {:noreply, fail(state, :spawn, reason)}
    end
  end

  @impl true
  def handle_call({:call_tool, name, args}, from, state) do
    case request(state, "tools/call", Protocol.tools_call_params(name, args), {:caller, from}) do
      {:ok, state} -> {:noreply, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:list_tools, _from, state) do
    {:reply, state.tools, state}
  end

  def handle_call(:snapshot, _from, %State{} = state) do
    {:reply, build_snapshot(state), state}
  end

  def handle_call({:call_tool_async, name, args, receiver_pid}, _from, state) do
    ref = make_ref()

    case request(
           state,
           "tools/call",
           Protocol.tools_call_params(name, args),
           {:async, receiver_pid, ref}
         ) do
      {:ok, state} ->
        {:reply, {:ok, ref}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(:reconnect, %State{} = state) do
    {:noreply, state, {:continue, :connect}}
  end

  def handle_info(_message, %State{transport: nil} = state), do: {:noreply, state}

  # The single funnel for everything the server says. The transport translates, we route.
  def handle_info(message, %State{} = state) do
    case Transport.handle_message(state.transport, message) do
      # A chunk can carry several complete messages, so this must fold over all
      # of them rather than handling the first.
      {:frames, frames, transport} ->
        {:noreply, Enum.reduce(frames, %State{state | transport: transport}, &handle_frame/2)}

      {:log, lines, transport} ->
        state = %State{state | transport: transport}
        Enum.each(lines, &publish(state, stderr_log(state, &1)))
        {:noreply, state}

      {:closed, reason} ->
        {:noreply, disconnected(state, reason)}

      :ignore ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, %{transport: nil}) do
    :ok
  end

  def terminate(_reason, %{transport: transport}) do
    Transport.close(transport)
  end

  defp send_initialize(%State{} = state) do
    {:noreply,
     request_or_fail(
       state,
       "initialize",
       Protocol.initialize_params(),
       {:internal, :initialize},
       :initialize
     )}
  end

  # -- Frame routing --

  defp handle_frame(line, %State{} = state) do
    case Protocol.decode(line) do
      {:ok, {:response, id, result}} ->
        route_response(state, id, result)

      {:ok, {:notification, method, params}} ->
        route_notification(state, method, params)

      # Modern servers never send requests; legacy ones can. Answer rather than
      # ignore, or the server blocks on that id forever.
      {:ok, {:request, id, _method, _params}} ->
        Transport.send_message(
          state.transport,
          Protocol.encode_error(id, @method_not_found, "Method not found")
        )

        state

      # One malformed line must not cost us the valid ones alongside it.
      {:error, reason} ->
        Logger.warning("#{log_prefix(state)} undecodable frame: #{inspect(reason)}")
        state
    end
  end

  defp route_response(%State{} = state, id, result) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        # Late reply from a pre-reconnect process, or a server bug.
        Logger.debug("#{log_prefix(state)} response for unknown id #{inspect(id)}")
        state

      {waiter, pending} ->
        dispatch(%State{state | pending: pending}, waiter, result)
    end
  end

  # The waiter tag recorded at request time carries everything needed to handle
  # the reply, so nothing else has to remember what id 3 was for.
  defp dispatch(%State{} = state, {:internal, :initialize}, {:ok, result}) do
    case Protocol.parse_initialize_result(result) do
      {:ok, server_info} -> complete_handshake(state, server_info)
      {:error, reason} -> fail(state, :initialize, reason)
    end
  end

  defp dispatch(%State{} = state, {:internal, :initialize}, {:error, error}) do
    fail(state, :initialize, error)
  end

  defp dispatch(%State{} = state, {:internal, {:tools_list, acc}}, {:ok, result}) do
    {tools, cursor} = Protocol.parse_tools(result)
    acc = acc ++ tools

    # A non-nil cursor means the server has more to hand over. Carrying the
    # accumulator in the tag keeps pagination self-contained.
    if is_nil(cursor) do
      state = %State{state | tools: acc}

      publish(state, %Events.ToolsDiscovered{
        server_name: state.config.name,
        scope_dir: state.config.scope_dir,
        tools: acc
      })

      state
    else
      request_or_fail(
        state,
        "tools/list",
        Protocol.tools_list_params(cursor),
        {:internal, {:tools_list, acc}},
        :request
      )
    end
  end

  # Discovery failing is not a dead connection — keep the client up.
  defp dispatch(%State{} = state, {:internal, {:tools_list, _acc}}, {:error, error}) do
    publish_error(state, :request, error)
    state
  end

  defp dispatch(%State{} = state, {:caller, from}, result) do
    GenServer.reply(from, result)
    state
  end

  defp dispatch(%State{} = state, {:async, pid, ref}, {:ok, result}) do
    send(pid, {:mcp_result, ref, result})
    state
  end

  defp dispatch(%State{} = state, {:async, pid, ref}, {:error, error}) do
    send(pid, {:mcp_error, ref, error})
    state
  end

  defp complete_handshake(%State{} = state, server_info) do
    # No other request may go out before this notification lands — servers
    # legitimately reject a tools/list that arrives ahead of it.
    case notify(state, "notifications/initialized", nil) do
      :ok ->
        # `attempt` resets here, not on transport connect: a server that spawns
        # cleanly then dies immediately must keep backing off.
        state = %State{state | status: :connected, server_info: server_info, attempt: 0}

        publish(state, %Events.ServerConnected{
          server_name: state.config.name,
          scope_dir: state.config.scope_dir,
          server_version: server_info.server_version,
          protocol_version: server_info.protocol_version,
          capabilities: server_info.capabilities
        })

        discover_tools(state)

      {:error, reason} ->
        fail(state, :initialize, reason)
    end
  end

  defp discover_tools(%State{server_info: %{capabilities: %{tools: %{supported: true}}}} = state) do
    request_or_fail(
      state,
      "tools/list",
      Protocol.tools_list_params(),
      {:internal, {:tools_list, []}},
      :request
    )
  end

  defp discover_tools(%State{} = state), do: state

  # -- Notifications --

  # TODO: add progress updates as well
  defp route_notification(%State{} = state, "notifications/message", params) do
    publish(state, %Events.ServerLog{
      server_name: state.config.name,
      scope_dir: state.config.scope_dir,
      level: log_level(params["level"]),
      logger: params["logger"],
      message: to_message(params["data"])
    })

    state
  end

  defp route_notification(%State{} = state, "notifications/tools/list_changed", _params) do
    request_or_fail(
      state,
      "tools/list",
      Protocol.tools_list_params(),
      {:internal, {:tools_list, []}},
      :request
    )
  end

  defp route_notification(%State{} = state, _method, _params), do: state

  # -- Disconnect --

  defp disconnected(%State{} = state, reason) do
    Logger.debug("#{log_prefix(state)} transport closed: #{inspect(reason)}")

    state = fail_pending(state, :disconnected)

    publish(state, %Events.ServerDisconnected{
      server_name: state.config.name,
      scope_dir: state.config.scope_dir,
      reason: :process_exit
    })

    state
    |> close_transport()
    |> schedule_reconnect()
  end

  # Without this, a Loop process blocked in a GenServer.call hangs until its
  # timeout waiting for a reply that can never come.
  defp fail_pending(%State{pending: pending} = state, reason) do
    Enum.each(pending, fn
      {_id, {:caller, from}} -> GenServer.reply(from, {:error, reason})
      {_id, {:async, pid, ref}} -> send(pid, {:mcp_error, ref, reason})
      {_id, {:internal, _}} -> :ok
    end)

    %State{state | pending: %{}}
  end

  # Every outbound request goes through here so `pending` can never disagree
  # with what actually made it onto the wire — the id is only recorded once the
  # transport has accepted the message.
  defp request(%State{} = state, method, params, waiter) do
    {id, state} = next_id(state)

    case Transport.send_message(state.transport, Protocol.encode_request(id, method, params)) do
      :ok -> {:ok, %State{state | pending: Map.put(state.pending, id, waiter)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_snapshot(%State{} = state) do
    Map.merge(
      %{
        server_name: state.config.name,
        scope_dir: state.config.scope_dir,
        status: state.status,
        tools: state.tools
      },
      snapshot_info(state.server_info)
    )
  end

  # `server_info` is nil until the handshake completes — which is exactly the
  # window a late subscriber is most likely to call in.
  defp snapshot_info(nil) do
    %{server_version: nil, protocol_version: nil, capabilities: %{}}
  end

  defp snapshot_info(server_info) do
    Map.take(server_info, [:server_version, :protocol_version, :capabilities])
  end

  defp request_or_fail(%State{} = state, method, params, waiter, phase) do
    case request(state, method, params, waiter) do
      {:ok, state} -> state
      {:error, reason} -> fail(state, phase, reason)
    end
  end

  # Notifications carry no id, so nothing is recorded in `pending`.
  defp notify(%State{} = state, method, params) do
    Transport.send_message(state.transport, Protocol.encode_notification(method, params))
  end

  defp next_id(%State{next_id: id} = state), do: {id, %State{state | next_id: id + 1}}

  # Failure is never a crash. The DynamicSupervisor's restart budget is shared
  # across every client, so a server with a typo'd command must not be able to
  # take down the working ones.
  defp fail(%State{} = state, phase, reason) do
    publish_error(state, phase, reason)

    state
    |> close_transport()
    |> schedule_reconnect()
  end

  defp publish_error(%State{} = state, phase, reason) do
    publish(state, %Events.ServerError{
      server_name: state.config.name,
      scope_dir: state.config.scope_dir,
      error: format_error(reason),
      phase: phase
    })
  end

  defp close_transport(%State{transport: nil} = state), do: state

  defp close_transport(%State{transport: transport} = state) do
    Transport.close(transport)
    %State{state | transport: nil}
  end

  # `attempt` is deliberately *not* reset here — it resets when the handshake
  # completes. A server that spawns cleanly and then dies immediately would
  # otherwise restart in a tight loop, since every attempt would look like the
  # first one.
  defp schedule_reconnect(%State{} = state) do
    Process.send_after(self(), :reconnect, backoff_ms(state.attempt))
    %State{state | status: :failed, attempt: state.attempt + 1}
  end

  defp backoff_ms(attempt) do
    min(@base_backoff_ms * Integer.pow(2, min(attempt, 5)), @max_backoff_ms)
  end

  defp publish(%State{} = state, event) do
    Eva.PG
    |> :pg.get_members({:mcp, state.config.scope_dir, state.config.name})
    |> Enum.each(&send(&1, event))
  end

  defp format_error(:missing_command), do: "No command configured"
  defp format_error({:executable_not_found, command}), do: "Executable not found: #{command}"
  defp format_error(%{"message" => message}), do: message

  defp format_error({:unsupported_version, version}),
    do: "Unsupported protocol version: #{version}"

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  # The spec is explicit that stderr output does not imply an error condition,
  # so these are :info rather than :error.
  defp stderr_log(%State{} = state, line) do
    %Events.ServerLog{
      server_name: state.config.name,
      scope_dir: state.config.scope_dir,
      level: :info,
      logger: "stderr",
      message: line
    }
  end

  defp log_level("debug"), do: :debug
  defp log_level("warning"), do: :warning
  defp log_level(level) when level in ~w(error critical alert emergency), do: :error
  defp log_level(_level), do: :info

  defp to_message(data) when is_binary(data), do: data
  defp to_message(data), do: inspect(data)

  defp log_prefix(%State{config: config}), do: "[mcp #{config.name}]"

  defp via_tuple(%Config{} = config) do
    {:via, Registry, {@registry, {config.scope_dir, config.name}}}
  end
end
