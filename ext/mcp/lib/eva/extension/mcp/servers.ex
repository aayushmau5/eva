defmodule Eva.Extension.MCP.Servers do
  @moduledoc """
  The MCP servers one session is using.
  """
  use TypedStruct
  require Logger

  alias Eva.Agent.Tools
  alias Eva.Extension.MCP.{Client, Config, Events, Supervisor, ToolAdapter}
  alias Eva.Extension.MCP.Config.Paths

  typedstruct do
    field :paths, Paths.t()
    field :servers, [Config.t()], default: []
    field :overrides, %{String.t() => boolean()}, default: %{}
    field :snapshots, %{String.t() => Client.snapshot()}, default: %{}
  end

  @typedoc """
  One configured server as a frontend sees it.

  `config_enabled` is what the `mcp.json` says and `session_enabled` is this
  session's override (`nil` when it hasn't set one) — a UI needs both to know
  which scope a toggle would be changing. `status` is `:disabled` when the
  session isn't running the server at all.
  """
  @type server_info :: %{
          name: String.t(),
          scope_dir: Events.scope_dir(),
          type: :stdio | :http,
          config_enabled: boolean(),
          session_enabled: boolean() | nil,
          status: :disabled | :connecting | :connected | :needs_auth | :failed,
          tool_count: non_neg_integer(),
          tools: [Events.tool()]
        }

  @doc """
  Reads the MCP config and subscribes to every server this session should run.

  Order matters: joining before starting means a cold client's `ServerConnected`
  cannot slip through the gap, and `snapshot/1` covers everything before that.
  Nothing here waits for a connection — servers are still handshaking when this
  returns, which is why `tools/1` is read fresh at each prompt.
  """
  @spec new(Paths.t(), %{String.t() => boolean()}) :: t()
  def new(%Paths{} = paths, overrides \\ %{}) do
    # TODO: bubble up diagnostics as a separate entity
    {servers, _diagnostics} = Config.parse(paths)

    snapshots =
      servers
      |> Enum.filter(&server_enabled?(overrides, &1))
      |> Enum.reduce(%{}, fn config, acc ->
        case subscribe(config) do
          {:ok, snapshot} -> Map.put(acc, config.name, snapshot)
          :error -> acc
        end
      end)

    %__MODULE__{
      paths: paths,
      servers: servers,
      overrides: overrides,
      snapshots: snapshots
    }
  end

  @doc """
  Agent tools for every enabled server that currently has a live client.

  Pulled from the clients rather than from `snapshots`, so a server that finished
  discovery since the last prompt is picked up without depending on an event
  having been processed. A client that is down contributes nothing.
  """
  @spec tools(t()) :: [Tools.AgentTool.t()]
  def tools(%__MODULE__{} = mcp) do
    mcp
    |> enabled_servers()
    |> Enum.flat_map(fn config ->
      case Client.whereis(config) do
        nil -> []
        pid -> ToolAdapter.to_agent_tools(config, Client.list_tools(pid))
      end
    end)
  end

  @doc """
  Every configured server, disabled ones included, for a settings UI.
  """
  @spec list(t()) :: [server_info()]
  def list(%__MODULE__{} = mcp) do
    Enum.map(mcp.servers, fn config ->
      enabled? = server_enabled?(mcp.overrides, config)
      snapshot = Map.get(mcp.snapshots, config.name, %{})
      tools = if enabled?, do: Map.get(snapshot, :tools, []), else: []

      %{
        name: config.name,
        scope_dir: config.scope_dir,
        type: config.type,
        config_enabled: config.enabled,
        session_enabled: Map.get(mcp.overrides, config.name),
        status: if(enabled?, do: Map.get(snapshot, :status, :failed), else: :disabled),
        tool_count: length(tools),
        tools: tools
      }
    end)
  end

  @doc """
  Enables or disables a server.

  `:session` affects this session only. `:persist` writes `enabled` back to the
  `mcp.json` the server was defined in and clears any session override — the file
  is the source of truth once written, so a leftover override must not be allowed
  to shadow what the user just asked for.

  Recording a `:session` toggle in the transcript is the caller's job; this owns
  the config and the client lifecycle, not the session's storage.
  """
  @spec set_enabled(t(), String.t(), boolean(), :session | :persist) ::
          {:ok, t()} | {:error, term()}
  def set_enabled(%__MODULE__{} = mcp, server_name, enabled?, scope)
      when is_boolean(enabled?) and scope in [:session, :persist] do
    case find(mcp, server_name) do
      nil -> {:error, :not_found}
      config -> apply_scope(mcp, config, enabled?, scope)
    end
  end

  defp apply_scope(%__MODULE__{} = mcp, config, enabled?, :session) do
    mcp = %__MODULE__{mcp | overrides: Map.put(mcp.overrides, config.name, enabled?)}
    {:ok, apply_enabled(mcp, config, enabled?)}
  end

  defp apply_scope(%__MODULE__{} = mcp, config, enabled?, :persist) do
    case Config.set_enabled(mcp.paths, config, enabled?) do
      {:ok, updated} ->
        mcp = %__MODULE__{
          mcp
          | servers: replace(mcp.servers, updated),
            overrides: Map.delete(mcp.overrides, updated.name)
        }

        {:ok, apply_enabled(mcp, updated, enabled?)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Leaves every server this instance subscribed to.

  Nothing called this while MCP was part of the session — a session dying dropped its
  `:pg` membership on its own. An extension's process is restarted for a reload or a
  disable while the VM keeps running, so the refcount has to be given back explicitly, or
  a server nobody is using stays up with its OS process attached.
  """
  @spec unsubscribe_all(t()) :: :ok
  def unsubscribe_all(%__MODULE__{} = mcp) do
    mcp |> enabled_servers() |> Enum.each(&unsubscribe/1)
  end

  @doc """
  Folds a client event into the snapshot this session holds.

  `snapshot/1` catches a session up at subscribe time; this keeps it current
  afterwards. Field names line up on purpose (see `Client.snapshot/0`) so both
  paths feed the same map.
  """
  @spec apply_event(t(), Events.t()) :: t()
  def apply_event(%__MODULE__{} = mcp, event) do
    with changes when not is_nil(changes) <- changes_for(event),
         {:ok, snapshot} <- Map.fetch(mcp.snapshots, event.server_name) do
      snapshots = Map.put(mcp.snapshots, event.server_name, Map.merge(snapshot, changes))
      %__MODULE__{mcp | snapshots: snapshots}
    else
      _ -> mcp
    end
  end

  # -- Private --

  defp find(%__MODULE__{servers: servers}, server_name) do
    Enum.find(servers, &(&1.name == server_name))
  end

  defp enabled_servers(%__MODULE__{} = mcp) do
    Enum.filter(mcp.servers, &server_enabled?(mcp.overrides, &1))
  end

  # A session-scoped toggle wins over the config file; with no toggle recorded,
  # the file decides.
  defp server_enabled?(overrides, %Config{} = config) do
    Map.get(overrides, config.name, config.enabled)
  end

  defp apply_enabled(%__MODULE__{} = mcp, config, true) do
    case subscribe(config) do
      {:ok, snapshot} ->
        %__MODULE__{mcp | snapshots: Map.put(mcp.snapshots, config.name, snapshot)}

      :error ->
        mcp
    end
  end

  defp apply_enabled(%__MODULE__{} = mcp, config, false) do
    unsubscribe(config)
    %__MODULE__{mcp | snapshots: Map.delete(mcp.snapshots, config.name)}
  end

  defp replace(servers, %Config{} = updated) do
    Enum.map(servers, fn config ->
      if config.name == updated.name, do: updated, else: config
    end)
  end

  defp subscribe(%Config{} = config) do
    join(config)

    case Supervisor.ensure_started(config) do
      {:ok, client_pid} ->
        {:ok, Client.snapshot(client_pid)}

      {:error, reason} ->
        Logger.warning("MCP server #{config.name} failed to start: #{inspect(reason)}")
        :error
    end
  end

  # `:pg` membership doubles as the refcount — sessions are the only members of an
  # `{:mcp, scope, name}` group — so an empty group after leaving means nobody is
  # left to talk to that server and its process can go.
  defp unsubscribe(%Config{} = config) do
    group = group(config)
    :pg.leave(Eva.PG, group, self())

    case :pg.get_members(Eva.PG, group) do
      [] -> Supervisor.stop(config)
      _members -> :ok
    end

    :ok
  end

  # `:pg` happily records the same pid twice, which would leave a phantom member
  # behind after one leave and defeat the refcount above.
  defp join(%Config{} = config) do
    group = group(config)

    if self() in :pg.get_members(Eva.PG, group) do
      :ok
    else
      :pg.join(Eva.PG, group, self())
    end
  end

  defp group(%Config{} = config), do: {:mcp, config.scope_dir, config.name}

  defp changes_for(%Events.ServerConnected{} = event) do
    %{
      status: :connected,
      server_version: event.server_version,
      protocol_version: event.protocol_version,
      capabilities: event.capabilities
    }
  end

  # The client schedules a reconnect and parks in `:failed` on the way there, so
  # this mirrors the client rather than inventing a `:disconnected` status.
  defp changes_for(%Events.ServerDisconnected{}), do: %{status: :failed}
  defp changes_for(%Events.AuthRequired{}), do: %{status: :needs_auth}
  defp changes_for(%Events.ToolsDiscovered{tools: tools}), do: %{tools: tools}
  defp changes_for(%Events.ToolsChanged{tools: tools}), do: %{tools: tools}

  # `ServerError` deliberately leaves status alone: a `:request`-phase error is
  # transient and the client stays up. A fatal one is followed by a disconnect.
  defp changes_for(_event), do: nil
end
