defmodule Eva.Extension.API do
  @moduledoc """
  Called by extensions to reach back into the system.

  Messages to the session are fire-and-forget. An extension may be inside a hook that
  the Loop process is blocked on, so a synchronous call back into the session could
  wait on a session that is itself waiting on the harness.

  The session receives:

      {:extension_user_message, name, text}
      {:extension_custom_message, name, %Messages.CustomMessage{}}
      {:extension_entry, namespace, data}
      {:extension_notify, level, name, text}
      {:extension_update_tools, name, tools}
  """

  require Logger

  alias Eva.Agent.Messages
  alias Eva.Agent.Tools
  alias Eva.Extension.Context
  alias Eva.Extension.Processes

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
  Replaces the tools this extension contributes.

  For tools an extension only learns about after `setup/1` — an MCP server that has
  finished its handshake, say. Replaces rather than appends, so a tool that goes away
  can be removed and calling twice with the same list is a no-op.

  Takes effect at the *next* prompt, not immediately: `Harness.update_tools/2` is inert
  mid-run, so a call made while the agent is working lands on the user's next message.
  """
  @spec update_tools(Context.t(), [Tools.AgentTool.t()]) :: :ok
  def update_tools(%Context{session_pid: session_pid, name: name}, tools) when is_list(tools) do
    send(session_pid, {:extension_update_tools, name, tools})
    :ok
  end

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
end
