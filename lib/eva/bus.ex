defmodule Eva.Bus do
  @moduledoc """
  Eva.Bus allows multiple listeners to subscribe to harness' events.
  """
  alias Eva.Agent.Events, as: AgentEvents
  alias Eva.MCP.Events, as: MCPEvents

  @classes [:stream, :lifecycle, :tools, :mcp, :extension]
  @type class :: :stream | :lifecycle | :tools | :mcp | :extension
  @mcp_events MCPEvents.modules()

  @doc """
  Classes of events that "frontend" listeners can subscribe to.
  """
  def classes() do
    @classes
  end

  @doc """
  Subscribe self to a session and desired class of event.
  """
  @spec subscribe(pid(), [class()]) :: :ok
  def subscribe(session_pid, classes \\ [:lifecycle, :tools]) do
    subscribe_pid(self(), session_pid, classes)
  end

  @doc """
  Subscribe pid to a session and desired class of event.
  """
  @spec subscribe_pid(pid(), pid(), [class()]) :: :ok
  def subscribe_pid(pid, session_pid, classes \\ [:lifecycle, :tools]) do
    Enum.each(classes, fn class ->
      group = group(session_pid, class)

      if pid in :pg.get_members(Eva.PG, group) do
        :ok
      else
        :pg.join(Eva.PG, group, pid)
      end
    end)
  end

  @doc """
  Unsubscribe self from events.
  """
  def unsubscribe(session_pid, classes \\ classes()) do
    Enum.each(classes, fn class ->
      :pg.leave(Eva.PG, group(session_pid, class), self())
    end)
  end

  @doc """
  Publish events to listeners. Class is extracted from the event internally.
  """
  @spec publish(pid(), AgentEvents.t() | MCPEvents.t()) :: :ok
  def publish(session_pid, event), do: publish(session_pid, event, classify(event))

  @doc """
  Publish events to listeners. Class is provided explicitly.
  """
  @spec publish(pid(), AgentEvents.t() | MCPEvents.t(), class()) :: :ok
  def publish(session_pid, event, class) do
    Eva.PG
    |> :pg.get_members(group(session_pid, class))
    |> Enum.each(&send(&1, event))
  end

  defp group(session_pid, class) do
    {:eva_session, session_pid, class}
  end

  # Classified the event into classes
  defp classify(%AgentEvents.MessageUpdate{}), do: :stream
  defp classify(%AgentEvents.ToolExecutionStart{}), do: :tools
  defp classify(%AgentEvents.ToolExecutionUpdate{}), do: :tools
  defp classify(%AgentEvents.ToolExecutionEnd{}), do: :tools

  defp classify(%{__struct__: mod}) when mod in @mcp_events, do: :mcp
  defp classify(_event), do: :lifecycle
end
