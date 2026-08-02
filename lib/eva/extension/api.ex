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
  """

  require Logger

  alias Eva.Agent.Messages
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

  @spec append_entry(Context.t(), map()) :: :ok
  def append_entry(%Context{session_pid: session_pid, name: name}, data) when is_map(data) do
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
end
