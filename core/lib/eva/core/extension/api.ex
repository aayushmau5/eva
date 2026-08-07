defmodule Eva.Core.Extension.API do
  @moduledoc """
  Called by extensions to reach back into the system.

  Messages to the session are fire-and-forget.

  The session receives:

      {:extension_user_message, name, text}
      {:extension_custom_message, name, %Messages.CustomMessage{}}
      {:extension_entry, namespace, data}
      {:extension_notify, level, name, text}
      {:extension_update_tools, name, tools}
  """

  require Logger

  alias Eva.Core.Agent.Messages
  alias Eva.Core.Agent.Tools
  alias Eva.Core.Extension.Context
  alias Eva.Core.Extension.Processes
  alias Eva.Core.Extension.ToolRegistry

  @default_timeout 5_000

  @type level :: :info | :warning | :error

  @spec send_user_message(Context.t(), String.t()) :: :ok
  def send_user_message(%Context{session_pid: session_pid, name: name}, text)
      when is_binary(text) do
    send(session_pid, {:extension_user_message, name, text})
    :ok
  end

  @spec send_custom_message(Context.t(), String.t(), String.t(), map()) :: :ok
  def send_custom_message(
        %Context{session_pid: session_pid, name: name},
        text,
        custom_type,
        details \\ %{}
      )
      when is_binary(text) and is_binary(custom_type) and is_map(details) do
    message = %Messages.CustomMessage{
      custom_type: custom_type,
      content: text,
      details: details
    }

    send(session_pid, {:extension_custom_message, name, message})
    :ok
  end

  @doc """
  Publishes an extension event on this session's bus.

  Primary audience is the Frontend that sees extension events.
  However, other extensions can also get these events(enables things like extension events logger, etc.)
  """
  @spec publish_event(Context.t(), term()) :: :ok
  def publish_event(%Context{session_pid: session_pid, name: name}, payload) do
    Eva.Core.Bus.publish(
      session_pid,
      %Eva.Core.Agent.Events.ExtensionEvent{extension: name, payload: payload},
      :extension
    )
  end

  @doc """
  Replaces the tools this extension contributes.

  For tools an extension only learns about after `setup/1` — an MCP server that has
  finished its handshake, say. Replaces rather than appends, so a tool that goes away
  can be removed and calling twice with the same list is a no-op.
  """
  @spec update_tools(Context.t(), [Tools.AgentTool.t()]) :: :ok
  def update_tools(%Context{session_pid: session_pid, name: name}, tools) when is_list(tools) do
    # A closure cannot be called on a node that lacks its module, so when the session is
    # elsewhere the executors stay here and only descriptions travel. The host binds a
    # proxy that calls back — see `Eva.Core.Extension.ToolRegistry`. Nothing an extension author
    # writes changes between the two cases.
    tools =
      if remote?(session_pid) do
        ToolRegistry.register(name, session_pid, tools)
      else
        tools
      end

    send(session_pid, {:extension_update_tools, name, tools})
    :ok
  end

  defp remote?(session_pid), do: node(session_pid) != node()

  @doc """
  Persists a map for this extension. Comes back in `Context.entries` next session.

  Keys **must be strings**. The data round-trips through JSON, so atom keys come back
  as strings and stop matching whatever you wrote.
  """
  @spec append_entry(Context.t(), map()) :: :ok
  def append_entry(%Context{session_pid: session_pid, name: name}, data) when is_map(data) do
    warn_on_atom_keys(name, data)
    send(session_pid, {:extension_entry, name, data})
    :ok
  end

  @spec notify(Context.t(), String.t(), level()) :: :ok
  def notify(%Context{session_pid: session_pid, name: name}, text, level \\ :info)
      when is_binary(text) and level in [:info, :warning, :error] do
    send(session_pid, {:extension_notify, level, name, text})
    :ok
  end

  @spec whereis(Context.t() | pid(), String.t()) :: pid() | nil
  def whereis(%Context{session_pid: session_pid}, name), do: whereis(session_pid, name)

  def whereis(session_pid, name) when is_pid(session_pid) and is_binary(name) do
    case Registry.whereis_name({Processes, {session_pid, name}}) do
      :undefined -> nil
      pid -> pid
    end
  end

  @spec call(Context.t() | pid(), String.t(), term(), timeout()) :: term()
  def call(context_or_pid, name, request, timeout \\ @default_timeout) do
    case whereis(context_or_pid, name) do
      nil -> raise "extension #{inspect(name)} has no running process"
      pid -> GenServer.call(pid, {:extension_request, request}, timeout)
    end
  end

  @spec cast(Context.t() | pid(), String.t(), term()) :: :ok
  def cast(context_or_pid, name, request) do
    case whereis(context_or_pid, name) do
      nil ->
        Logger.debug("extension #{inspect(name)} has no running process; cast dropped")
        :ok

      pid ->
        GenServer.cast(pid, {:extension_cast, request})
    end
  end

  # Warn rather than raise: `append_entry/2` is fire-and-forget, and the entry is still
  # written — it just will not match on resume. Failing the call would be worse.
  defp warn_on_atom_keys(name, data) do
    if Enum.any?(Map.keys(data), &(not is_binary(&1))) do
      Logger.warning(
        "extension #{name}: append_entry/2 keys must be strings; " <>
          "atom keys become strings on resume and will not match what you wrote"
      )
    end
  end
end
