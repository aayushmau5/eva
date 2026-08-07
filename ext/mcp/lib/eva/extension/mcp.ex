defmodule Eva.Extension.MCP do
  @moduledoc """
  MCP servers, as an extension.

  This used to be part of Eva: the session held a `%SessionServers{}`, merged its tools
  into every prompt, folded client events into a snapshot, and exposed
  `list_mcp_servers/1` and `set_mcp_enabled/4` for a frontend to call. All of that is
  here now, behind the same contract every other extension uses — tools arrive through
  `API.update_tools/2`, toggles persist through `API.append_entry/2`, and a frontend
  watches `%ExtensionEvent{extension: "mcp"}` instead of `Eva.MCP.Events.*`.

  What did **not** move is the client: `Eva.Extension.MCP.Client` processes live under
  this application's own supervisor, shared by every session and refcounted through
  `:pg`, so two sessions using the same server share one connection and the last one out
  stops it. This process is a *subscriber* to those clients, not their owner.

  ## Commands

      /mcp                       list servers, their status and tool counts
      /mcp enable <server>       for this session
      /mcp disable <server>
      /mcp enable <server> --persist    write it back to the mcp.json it came from
      /mcp disable <server> --persist
  """

  use Eva.Core.Extension

  alias Eva.Extension.MCP.{Config, Events, Servers}

  @mcp_events Events.modules()

  @impl true
  def setup(_ctx) do
    {:ok,
     %Spec{
       commands: [
         %Spec.Command{
           name: "mcp",
           description: "List and toggle MCP servers",
           arg_hint: "[enable|disable <server> [--persist]]"
         }
       ]
     }}
  end

  @impl true
  def init(%{} = ctx) do
    paths = %Config.Paths{cwd: ctx.cwd}

    # Subscribing happens in this process, so client events arrive as ordinary messages
    # in `handle_info/2` — the same place a session used to receive them.
    servers = Servers.new(paths, overrides_from(ctx.entries))

    state = %{ctx: ctx, servers: servers}
    push_tools(state)

    {:ok, state}
  end

  @impl true
  def handle_info(%{__struct__: module} = event, state) when module in @mcp_events do
    state = %{state | servers: Servers.apply_event(state.servers, event)}

    # Tools change as servers finish discovery, so republish on every event rather than
    # trying to work out which ones matter — `update_tools` is a message, not a rebuild.
    push_tools(state)

    # Frontends used to match `Eva.MCP.Events.*` on the `:mcp` class. Those modules are
    # no longer core's to publish, so the event travels as this extension's payload.
    API.publish_event(state.ctx, event)

    {:ok, state}
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def handle_command("mcp", args, state) do
    case String.split(args, ~r/\s+/, trim: true) do
      [] -> {{:text, render(state.servers)}, state}
      ["list"] -> {{:text, render(state.servers)}, state}
      ["enable", server | rest] -> toggle(state, server, true, rest)
      ["disable", server | rest] -> toggle(state, server, false, rest)
      _other -> {{:text, "usage: /mcp [enable|disable <server> [--persist]]"}, state}
    end
  end

  @impl true
  def handle_request(:list, state), do: {{:ok, Servers.list(state.servers)}, state}

  def handle_request({:set_enabled, server, enabled?, scope}, state)
      when is_boolean(enabled?) and scope in [:session, :persist] do
    case apply_toggle(state, server, enabled?, scope) do
      {:ok, state} -> {{:ok, Servers.list(state.servers)}, state}
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  def handle_request(_request, state), do: {{:error, :not_implemented}, state}

  @impl true
  def terminate(_reason, state) do
    # Leaving the `:pg` groups is what drops the refcount, so a server nobody else is
    # using stops with the session rather than lingering as an orphaned OS process.
    Servers.unsubscribe_all(state.servers)
    :ok
  end

  # -- Private --

  defp toggle(state, server, enabled?, flags) do
    scope = if "--persist" in flags, do: :persist, else: :session

    case apply_toggle(state, server, enabled?, scope) do
      {:ok, state} ->
        word = if enabled?, do: "enabled", else: "disabled"
        where = if scope == :persist, do: " (written to mcp.json)", else: " for this session"
        {{:text, "#{server} #{word}#{where}"}, state}

      {:error, :not_found} ->
        {{:text, "no MCP server named #{server}"}, state}

      {:error, reason} ->
        {{:text, "could not update #{server}: #{inspect(reason)}"}, state}
    end
  end

  defp apply_toggle(state, server, enabled?, scope) do
    case Servers.set_enabled(state.servers, server, enabled?, scope) do
      {:ok, servers} ->
        state = %{state | servers: servers}

        # A session-scoped choice is this extension's to remember; a persisted one lives
        # in the user's `mcp.json` and must not be shadowed by a stale entry.
        if scope == :session do
          API.append_entry(state.ctx, %{"server" => server, "enabled" => enabled?})
        end

        push_tools(state)
        {:ok, state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp push_tools(state), do: API.update_tools(state.ctx, Servers.tools(state.servers))

  # Entry data round-trips through JSON, so these keys are strings — see
  # `API.append_entry/2`. Later entries win, which is what replaying a session means.
  defp overrides_from(entries) do
    for %{"server" => name, "enabled" => enabled} <- entries,
        is_binary(name) and is_boolean(enabled),
        into: %{},
        do: {name, enabled}
  end

  defp render(servers) do
    case Servers.list(servers) do
      [] ->
        "no MCP servers configured — add one to ~/.eva/mcp.json or .eva/mcp.json"

      infos ->
        Enum.map_join(infos, "\n", fn info ->
          scope = if info.scope_dir == :global, do: "global", else: "project"

          "#{info.name}  #{info.status}  #{info.tool_count} tools  (#{info.type}, #{scope})"
        end)
    end
  end
end
