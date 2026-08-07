defmodule Eva.Cluster do
  @moduledoc """
  Who is connected, and what they claim to be.

  Extensions that run on their own node announce themselves here rather than being spawned
  — Eva never launches a VM. A member is up or it isn't; this knows which, and tells sessions
  when that changes.

  Registered under its own name, because a joining node addresses it as
  `{Eva.Cluster, eva_node}` with no pid and no module of ours.

  ## Two layers

  A node announces **once**, saying an extension exists there. Each session then asks that
  member to instantiate the extension for itself, with its own `Context`. So one node
  serves every session, and a session that starts later needs nothing new — see
  `Eva.Extension.Set`.

  ## Trust

  Anything that can connect to this VM can call this. Erlang distribution's boundary is the
  cookie, and a connected node can already reach anything here, so the allowlist below is a
  guard against mistakes rather than against an attacker who has the cookie — with one
  exception worth having: an extension registers tools the model will call and hooks that
  can rewrite them, so a name nobody asked for should never get that far.

  The allowlist is the registry — `mix eva.ext.add` writes it — and it is **read at each
  announcement rather than held**. A copy taken at startup goes stale the moment someone
  registers an extension, and the failure is a quiet one: the node knocks, is refused, and
  retries forever while the name it needs sits in the file all along. Announcing happens
  once per node start, so reading a small file there costs nothing.
  """

  use GenServer

  require Logger

  alias Eva.Core.Cluster.Protocol
  alias Eva.Coding.Resources
  alias Eva.Extension.Package
  alias Eva.Core.Cluster.Protocol.Announcement

  @type member :: %{
          role: Protocol.role(),
          name: String.t(),
          node: node(),
          pid: pid(),
          core_version: String.t(),
          generation: pos_integer(),
          joined_at: DateTime.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Every member with a role, in the order they joined.
  """
  @spec members(Protocol.role()) :: [member()]
  def members(role), do: call({:members, role})

  @doc """
  One member by role and name.
  """
  @spec fetch(Protocol.role(), String.t()) :: {:ok, member()} | :error
  def fetch(role, name), do: call({:fetch, role, name})

  @doc """
  Watches membership. The caller receives:

      {:cluster_member_up, member}
      {:cluster_member_down, member}

  Subscribers are monitored, so a session going away unsubscribes itself.

  Generally called by a session.
  """
  @spec subscribe() :: :ok
  def subscribe, do: call({:subscribe, self()})

  @doc """
  Replaces what this directory will admit, until it is replaced again.

    * `:registry` — whatever `mix eva.ext.add` has registered, re-read at each announcement.
      The default, and what a running Eva should normally be on.
    * a list — exactly these names, ignoring the registry. For a host that wants its own
      answer, and for tests.
    * `nil` — anything that reaches the cookie.

  Nothing needs to call this to keep the registry in step; that is what `:registry` is for.
  """
  @spec allow(:registry | nil | [String.t()]) :: :ok
  def allow(names), do: call({:allow, names})

  @doc """
  Whether the directory is running — that is, whether Eva is accepting members at all.
  """
  @spec running?() :: boolean()
  def running?, do: is_pid(Process.whereis(__MODULE__))

  @impl true
  def init(opts) do
    {:ok,
     %{
       members: %{},
       subscribers: %{},
       allow: Keyword.get(opts, :allow, :registry),
       # Where the registry is read from. Only interesting to a test pointing at a
       # temporary root; everything else wants the one under `~/.eva`.
       resources: Keyword.get(opts, :resources, %Resources{}),
       generation: 0
     }}
  end

  @impl true
  def handle_call({:announce, %Announcement{} = announcement}, _from, state) do
    case refuse(announcement, state) do
      nil ->
        {member, state} = admit(announcement, state)
        Logger.info("#{member.role} #{member.name} joined from #{member.node}")
        notify(state, {:cluster_member_up, member})
        {:reply, {:ok, member.generation}, state}

      reason ->
        Logger.warning(
          "refused #{announcement.role} #{announcement.name} from #{announcement.node}: " <>
            Protocol.describe_refusal(reason)
        )

        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:members, role}, _from, state) do
    members =
      state.members
      |> Map.values()
      |> Enum.filter(&(&1.role == role))
      |> Enum.sort_by(& &1.generation)

    {:reply, members, state}
  end

  def handle_call({:fetch, role, name}, _from, state) do
    {:reply, Map.fetch(state.members, {role, name}), state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    if Map.has_key?(state.subscribers, pid) do
      {:reply, :ok, state}
    else
      ref = Process.monitor(pid)
      {:reply, :ok, put_in(state.subscribers[pid], ref)}
    end
  end

  def handle_call({:allow, names}, _from, state) do
    {:reply, :ok, %{state | allow: names}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    state =
      case pop_member(state, pid) do
        {nil, state} ->
          %{state | subscribers: Map.delete(state.subscribers, pid)}

        {member, state} ->
          Logger.info("#{member.role} #{member.name} left #{member.node}")
          notify(state, {:cluster_member_down, member})
          state
      end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # -- Private --

  defp call(request) do
    GenServer.call(__MODULE__, request)
  catch
    # Distribution off, or Eva shutting down. Callers treat it as "nobody is connected",
    # which is true.
    :exit, _reason -> empty_for(request)
  end

  defp empty_for({:members, _role}), do: []
  defp empty_for({:fetch, _role, _name}), do: :error
  defp empty_for(_request), do: :ok

  defp refuse(%Announcement{} = announcement, state) do
    mine = Protocol.protocol_version()
    core = Protocol.core_version()

    cond do
      announcement.protocol_version != mine ->
        {:protocol_version, mine, announcement.protocol_version}

      announcement.core_version != core ->
        {:core_version, core, announcement.core_version}

      announcement.role not in [:extension, :harness] ->
        {:unknown_role, announcement.role}

      not allowed?(state, announcement) ->
        :not_allowed

      true ->
        taken_by(state, announcement)
    end
  end

  # A different *node* claiming a name already in use is a collision. The same node
  # re-announcing is a reconnect, and replaces its own entry.
  defp taken_by(state, %Announcement{} = announcement) do
    case Map.fetch(state.members, {announcement.role, announcement.name}) do
      {:ok, %{node: node}} when node != announcement.node -> {:name_taken, node}
      _other -> nil
    end
  end

  defp allowed?(%{allow: nil}, _announcement), do: true

  defp allowed?(%{allow: :registry} = state, %Announcement{role: :extension, name: name}) do
    name in Package.allowed_names(state.resources)
  end

  defp allowed?(%{allow: names}, %Announcement{role: :extension, name: name})
       when is_list(names) do
    name in names
  end

  # Only extensions are filtered by name. A `:harness` has no registry to be in.
  defp allowed?(_state, _announcement), do: true

  defp admit(%Announcement{} = announcement, state) do
    key = {announcement.role, announcement.name}
    state = demote_previous(state, key)
    generation = state.generation + 1

    member = %{
      role: announcement.role,
      name: announcement.name,
      node: announcement.node,
      pid: announcement.pid,
      core_version: announcement.core_version,
      generation: generation,
      joined_at: DateTime.utc_now()
    }

    Process.monitor(announcement.pid)

    {member, %{state | members: Map.put(state.members, key, member), generation: generation}}
  end

  # A node that restarted announces again while its old entry may still be here — its
  # monitor has not necessarily fired yet. Drop the old one silently rather than letting a
  # late `:DOWN` remove the new one.
  defp demote_previous(state, key) do
    %{state | members: Map.delete(state.members, key)}
  end

  defp pop_member(state, pid) do
    case Enum.find(state.members, fn {_key, member} -> member.pid == pid end) do
      nil -> {nil, state}
      {key, member} -> {member, %{state | members: Map.delete(state.members, key)}}
    end
  end

  defp notify(state, message) do
    Enum.each(Map.keys(state.subscribers), &send(&1, message))
  end
end
