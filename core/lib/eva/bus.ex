defmodule Eva.Bus do
  @moduledoc """
  Eva.Bus allows multiple listeners to subscribe to harness' events.
  """
  alias Eva.Agent.Events, as: AgentEvents

  @classes [:stream, :lifecycle, :tools, :extension]
  @type class :: :stream | :lifecycle | :tools | :extension | atom()

  @agent_events AgentEvents.modules()

  @registry {__MODULE__, :host_events}

  @doc """
  Teaches the bus about events it does not ship with, and the class they belong to.

  The host has events of its own. The host registers them at boot, and `classify/1` and
  `event?/1` pick them up.

  Anything an *extension* publishes needs none of this: it arrives wrapped in
  `Eva.Agent.Events.ExtensionEvent`, which the bus already knows.
  """
  @spec register_events([module()], class()) :: :ok
  def register_events(modules, class) when is_list(modules) and is_atom(class) do
    # Written once at application start, never per event: `:persistent_term.put/2`
    # triggers a global GC scan, while reads are free.
    registered = Map.new(modules, &{&1, class})
    :persistent_term.put(@registry, Map.merge(host_events(), registered))
  end

  @doc """
  Classes of events that "frontend" listeners can subscribe to.
  """
  def classes() do
    @classes ++ (host_events() |> Map.values() |> Enum.uniq())
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
  @spec publish(pid(), struct()) :: :ok
  def publish(session_pid, event), do: publish(session_pid, event, classify(event))

  @doc """
  Publish events to listeners. Class is provided explicitly.
  """
  @spec publish(pid(), struct(), class()) :: :ok
  def publish(session_pid, event, class) do
    Eva.PG
    |> :pg.get_members(group(session_pid, class))
    |> Enum.each(&send(&1, event))
  end

  @doc """
  Whether a message is an event this bus publishes.

  Events arrive as bare structs, exactly like a message an extension's own process
  sent it. `Eva.Extension.Server` uses this to decide between `handle_event/2` and
  `handle_info/2`.

  Anything an extension publishes is wrapped in `Eva.Agent.Events.ExtensionEvent`.
  """
  @spec event?(term()) :: boolean()
  def event?(%{__struct__: module}),
    do: module in @agent_events or Map.has_key?(host_events(), module)

  def event?(_other), do: false

  defp host_events, do: :persistent_term.get(@registry, %{})

  defp group(session_pid, class) do
    {:eva_session, session_pid, class}
  end

  # Classified the event into classes
  defp classify(%AgentEvents.MessageUpdate{}), do: :stream
  defp classify(%AgentEvents.ToolExecutionStart{}), do: :tools
  defp classify(%AgentEvents.ToolExecutionUpdate{}), do: :tools
  defp classify(%AgentEvents.ToolExecutionEnd{}), do: :tools

  # Whatever the extension put inside is its own business — a listener matches on
  # `extension` and reads `payload`, so core never needs a class per extension.
  defp classify(%AgentEvents.ExtensionEvent{}), do: :extension

  defp classify(%{__struct__: module}) when is_atom(module) do
    Map.get(host_events(), module, :lifecycle)
  end

  defp classify(_event), do: :lifecycle
end
