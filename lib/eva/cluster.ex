defmodule Eva.Cluster do
  @moduledoc """
  Who is connected, and what they claim to be.

  Extensions that run on their own node are **dialled** from here.
  Eva never launches a VM, and never sits waiting to be found. A member is
  up or it isn't; this knows which, and tells sessions when that changes.

  ## Eva does the reaching

  A scan enumerates locally discoverable and configured extension nodes, plus nodes that
  have already connected to Eva. It asks each candidate what it is, checks the answer, and
  attaches. Only the extension node needs a stable identity — one per name, long-lived —
  rather than Eva, of which there may be several per machine, coming and going with your work.

  Joining is not instant: `mix eva.ext.start mcp` lands on the next
  scan rather than the moment it comes up. What it buys is one path — the same one will
  dial a node on another machine, given its address — and no retry loop on the far side.

  Re-dialling happens out of the same scan. A member whose `:DOWN` arrives is removed, and
  the next scan finds it again if it came back.

  ## Two layers

  A node is attached **once**, saying an extension exists there. Each session then asks that
  member to instantiate the extension for itself, with its own `Context`. So one node
  serves every session.

  ## Trust

  The cookie is Erlang's boundary and anything holding it can already reach this VM, so the
  allowlist is a guard against mistakes rather than against an attacker — with one exception
  worth having: an extension registers tools the model will call and hooks that can rewrite
  them, so a name nobody asked for should never get that far.

  The allowlist is the registry — `mix eva.ext.add` writes it — and it is **read at each
  scan**. A copy taken at startup goes stale the moment someone registers
  an extension.

  The far side has the matching veto: a node's `:serve` (present in `core/extension/node.ex`)
  list decides which Evas it will answer, so being dialled is not the same as being taken.
  """

  use GenServer

  require Logger

  alias Eva.Cluster.{Discovery, Epmd}
  alias Eva.Core.Cluster.{Host, Protocol}
  alias Eva.Core.Cluster.Protocol.Description
  alias Eva.Coding.Resources
  alias Eva.Extension.{Package, Registry}

  # Fast enough that starting an extension feels immediate-ish, slow enough that the erpc
  # per non-member node is nothing. Only nodes we have *not* taken on are asked again.
  @scan_interval 2_000

  # Asking a node what it is does a `whereis` and builds a struct. Generous because it is
  # the first thing said to a VM that may still be booting.
  @ask_timeout 5_000

  # Short, because this one runs inside the directory rather than in the scan's task.
  @consent_timeout 2_000

  # How long a member that dropped its connection is kept before sessions are told it is
  # gone. Walking between two wifi networks should not tear the tools out of a turn.
  @grace 8_000

  @type member :: %{
          role: Protocol.role(),
          name: String.t(),
          # `nil` when it runs here. A label for the machine otherwise, which is what makes
          # two extensions called `mcp` on two machines tellable apart — by a person, by a
          # session, and by the model reading a tool name.
          machine: String.t() | nil,
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
  Every member with a role, in the order they joined (non-deterministic).
  """
  @spec members(Protocol.role()) :: [member()]
  def members(role), do: call({:members, role})

  @doc """
  One member by role and name.

  A name is no longer unique on its own — the same extension may be running on two
  machines — so this answers with whichever joined first (non-deterministic).
  """
  @spec fetch(Protocol.role(), String.t()) :: {:ok, member()} | :error
  def fetch(role, name), do: call({:fetch, role, name})

  @doc """
  Watches membership. The caller receives:

      {:cluster_member_up, member}
      {:cluster_member_down, member}

  Generally called by a session.
  Subscribers are monitored, so a session going away unsubscribes itself.

  **Distributed members already connected are replayed as `:cluster_member_up`** before this
  returns. Discovery's first scan happens when the application boots, long before any
  session exists, so without the replay a subscriber only ever learns about nodes that
  happen to join *after* it — and a node started before Eva, which is the normal way to
  run one, would never be taken on by any session.
  """
  @spec subscribe() :: :ok
  def subscribe, do: call({:subscribe, self()})

  @doc """
  Replaces what this directory will admit, until it is replaced again.

    * `:registry` — whatever `mix eva.ext.add` has registered, re-read at each scan.
      The default, and what a running Eva should normally be on.
    * a list — exactly these names, ignoring the registry. For a host that wants its own
      answer, and for tests.
    * `nil` — anything that reaches the cookie.
  """
  @spec allow(:registry | nil | [String.t()]) :: :ok
  def allow(names), do: call({:allow, names})

  @doc """
  Whether the directory is running, i.e., whether Eva is accepting members at all.
  """
  @spec running?() :: boolean()
  def running?, do: is_pid(Process.whereis(__MODULE__))

  @doc """
  Scans now rather than waiting for the next tick, and returns once it has been applied.

  For tests and for a command that has just started a node and does not want to wait.
  """
  @spec scan_now() :: :ok
  def scan_now, do: call(:scan_now)

  @doc """
  Drops a member and stops dialling it until something asks for it again.

  Disconnecting alone would not hold: the next scan is two seconds away and would pick it
  straight back up. So detaching is two things — drop it, and remember not to.

      Cluster.detach(:extension, "mcp", :"eva_ext_mcp@100.64.5.20")

  The node is required. `mcp` on the laptop and `mcp` on the devbox are two different members.

  Returns `:error` when there was no such member. The block is recorded either way, so
  detaching something before it turns up works.
  """
  @spec detach(Protocol.role(), String.t(), node()) :: :ok | :error
  def detach(role, name, node), do: call({:detach, role, name, node})

  @doc """
  Undoes `detach/3`, so the next scan may take that member on again.
  """
  @spec reattach(Protocol.role(), String.t(), node()) :: :ok
  def reattach(role, name, node), do: call({:reattach, role, name, node})

  @doc """
  What was detached by hand and is not being dialled.
  """
  @spec detached() :: [{Protocol.role(), String.t(), node()}]
  def detached, do: call(:detached)

  @doc """
  Nodes seen and not taken on, and why.
  """
  @spec refusals() :: %{node() => Protocol.refusal()}
  def refusals, do: call(:refusals)

  @impl true
  def init(opts) do
    state = %{
      # The connected extensions.
      members: %{},
      # Pids (usually session pids) who are interested in coming/going of extensions
      subscribers: %{},
      # allow list: :registry -> consult from registry file | [...] -> consult from provided list
      allow: Keyword.get(opts, :allow, :registry),
      # Where the registry is read from (~/.eva/extensions.json).
      resources: Keyword.get(opts, :resources, %Resources{}),
      # Each extension connection bumps up the generation
      generation: 0,
      # The nodes that refused connection.
      # Only so a node refused for the same reason every two seconds is logged once. Not a
      # decision — the registry can change under us, so a refused node is always re-asked.
      refused: %{},
      # Detached by hand: `{role, name, machine}` pairs the scan must keep skipping. Without this,
      # detaching would be undone by the next scan two seconds later.
      detached: MapSet.new(),
      # Members whose connection dropped, and when. Held rather than dropped so a blip does
      # not reach sessions: `{key => monotonic ms}`.
      dropped: %{},
      # A scan runs in a task; this is the ref of the one whose answers we still want.
      scanning: nil,
      # PIDs waiting on `:scan_now`
      waiting: [],
      # The two steps of dialling, replaceable.
      # Tests drive them directly rather than standing up VMs.
      look: Keyword.get(opts, :look, &__MODULE__.look/2),
      consent: Keyword.get(opts, :consent, &__MODULE__.consent/2),
      scan_interval: Keyword.get(opts, :scan_interval, @scan_interval),
      grace: Keyword.get(opts, :grace, @grace)
    }

    {:ok, state, {:continue, :scan}}
  end

  @impl true
  def handle_continue(:scan, state) do
    schedule_scan(state)
    {:noreply, start_scan(state)}
  end

  @impl true
  def handle_call(:scan_now, from, state) do
    # Answered when the scan lands, not when it is launched
    {:noreply, start_scan(%{state | waiting: [from | state.waiting]})}
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
    match =
      state.members
      |> Map.values()
      |> Enum.sort_by(& &1.generation)
      |> Enum.find(&(&1.role == role and &1.name == name))

    {:reply, if(match, do: {:ok, match}, else: :error), state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    if Map.has_key?(state.subscribers, pid) do
      {:reply, :ok, state}
    else
      ref = Process.monitor(pid)

      state.members
      |> Map.values()
      |> Enum.sort_by(& &1.generation)
      |> Enum.each(&send(pid, {:cluster_member_up, &1}))

      {:reply, :ok, put_in(state.subscribers[pid], ref)}
    end
  end

  def handle_call({:allow, names}, _from, state) do
    # Forget past refusals: the answer to "may this join" has just changed, and a stale
    # note would silence the log line explaining the new one.
    {:reply, :ok, %{state | allow: names, refused: %{}}}
  end

  def handle_call(:refusals, _from, state) do
    {:reply, state.refused, state}
  end

  def handle_call({:detach, role, name, node}, _from, state) do
    # Recorded before anything is dropped, so a member that turns up on the next scan is
    # skipped whether or not it was here when this was called.
    state = %{state | detached: MapSet.put(state.detached, {role, name, node})}

    case Map.fetch(state.members, {role, name, node}) do
      :error ->
        {:reply, :error, state}

      {:ok, member} ->
        Logger.info("detaching #{member.role} #{member.name} on #{member.node}")
        state = remove(state, member)
        Node.disconnect(member.node)
        {:reply, :ok, state}
    end
  end

  def handle_call({:reattach, role, name, node}, _from, state) do
    {:reply, :ok, %{state | detached: MapSet.delete(state.detached, {role, name, node})}}
  end

  def handle_call(:detached, _from, state) do
    {:reply, MapSet.to_list(state.detached), state}
  end

  @impl true
  def handle_info(:scan, state) do
    schedule_scan(state)
    {:noreply, start_scan(state)}
  end

  def handle_info({:scanned, ref, found}, state) do
    # Applied even when a newer scan has been started since.
    #
    # Sequentially, so a second node claiming a name the first just took is refused rather
    # than racing it.
    state = Enum.reduce(found, state, &consider(&2, &1))

    # Waiters belong to the newest scan, though answering them from an older one would
    # mean "I looked" before the look they asked for had finished.
    if ref == state.scanning do
      Enum.each(state.waiting, &GenServer.reply(&1, :ok))
      {:noreply, %{state | scanning: nil, waiting: []}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    case find_member(state, pid) do
      nil ->
        {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}

      {key, member} ->
        {:noreply, went_away(state, key, member, reason)}
    end
  end

  # A member held through a blip that never ended.
  def handle_info({:reap, key}, state) do
    case Map.fetch(state.members, key) do
      {:ok, member} when is_map_key(state.dropped, key) ->
        Logger.info("#{member.role} #{member.name} did not come back; dropping it")
        {:noreply, remove(state, member)}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # -- Private --

  # A process dying is gone. A connection dropping might be a closed lid or a wifi change,
  # and telling every session to tear down its tools mid-turn for that is worse than
  # waiting a moment — the pid survives a blip, so it can be picked back up unchanged.
  defp went_away(state, key, member, :noconnection) do
    Logger.info("#{member.role} #{member.name} lost its connection; holding it briefly")
    Process.send_after(self(), {:reap, key}, state.grace)
    put_in(state.dropped[key], System.monotonic_time(:millisecond))
  end

  defp went_away(state, _key, member, _reason) do
    Logger.info("#{member.role} #{member.name} left #{member.node}")
    remove(state, member)
  end

  # Tells sessions, and makes it eligible to be dialled again on the next scan.
  # Unless detached previously.
  defp remove(state, member) do
    key = {member.role, member.name, member.node}

    state = %{
      state
      | members: Map.delete(state.members, key),
        dropped: Map.delete(state.dropped, key)
    }

    notify(state, {:cluster_member_down, member})
    forget_refusal(state, member.node)
  end

  defp find_member(state, pid) do
    Enum.find(state.members, fn {_key, member} -> member.pid == pid end)
  end

  defp schedule_scan(%{scan_interval: :never}), do: :ok
  defp schedule_scan(%{scan_interval: ms}), do: Process.send_after(self(), :scan, ms)

  defp start_scan(state) do
    # We don't wait on a node that may be booting, sleeping or gone.
    parent = self()
    ref = make_ref()
    look = state.look
    resources = state.resources
    known = member_nodes(state)

    Task.start(fn -> send(parent, {:scanned, ref, look.(known, resources)}) end)

    %{state | scanning: ref}
  end

  @doc false
  # Everything worth asking: this machine's extension nodes found through epmd, the ones a
  # registry entry names outright, and nodes that established the connection themselves. The
  # last group is what makes a foregrounded phone work without a host-to-phone dial path.
  @spec look(MapSet.t(node()), Resources.t()) ::
          [{node(), Description.t() | {:error, term()}}]
  def look(known, %Resources{} = resources) do
    # Re-read every scan, so editing the registry on a running Eva takes effect.
    :ok = Epmd.install(resources)

    nodes = Discovery.extension_nodes() ++ configured(resources) ++ Node.list(:connected)

    for node <- Enum.uniq(nodes),
        not MapSet.member?(known, node),
        result = ask(node),
        result != :not_extension do
      {node, result}
    end
  end

  # Never enumerated, only named. There is no epmd to ask on another machine, which is
  # exactly why the entry has to carry the port.
  defp configured(resources) do
    resources |> Registry.remote() |> Enum.map(&Registry.node_name/1)
  end

  defp ask(node) do
    case :erpc.call(node, :erlang, :whereis, [Eva.Core.Extension.Node], @ask_timeout) do
      :undefined -> :not_extension
      _pid -> :erpc.call(node, Eva.Core.Extension.Node, :describe, [], @ask_timeout)
    end
  catch
    # when the node is unreachable, still booting, or gone
    # Ordinary; the next scan asks again.
    _kind, reason -> {:error, {:unreachable, reason}}
  end

  @doc false
  # Ask a node to take this Eva on. Short timeout on purpose: this runs inside the
  # directory, and the node it calls answered `describe` moments ago.
  @spec consent(Description.t(), pos_integer()) :: :ok | {:error, term()}
  def consent(%Description{} = description, generation) do
    :erpc.call(
      description.node,
      Eva.Core.Extension.Node,
      :attach,
      [node(), generation],
      @consent_timeout
    )
  catch
    _kind, reason -> {:error, {:unreachable, reason}}
  end

  defp consider(state, {node, {:error, reason}}), do: note(state, node, reason)

  defp consider(state, {_node, %Description{} = description}) do
    key = {description.role, description.name, description.node}

    cond do
      detached?(state, description) ->
        state

      Map.has_key?(state.dropped, key) ->
        restore(state, key, description)

      true ->
        case refuse(description, state) do
          nil -> attach(state, description)
          reason -> note(state, description.node, reason)
        end
    end
  end

  defp detached?(state, %Description{} = description) do
    MapSet.member?(
      state.detached,
      {description.role, description.name, description.node}
    )
  end

  # It answered during the grace period. If it is the same process, the connection blipped
  # and nothing else happened — put the monitor back and say nothing, so no session ever
  # learns there was a gap. A different pid means it restarted, which sessions do have to
  # hear about: their held generation is stale and their tools are gone.
  defp restore(state, key, %Description{} = description) do
    member = Map.fetch!(state.members, key)

    if member.pid == description.pid do
      Logger.info("#{member.role} #{member.name} came back")
      Process.monitor(description.pid)
      %{state | dropped: Map.delete(state.dropped, key)}
    else
      state |> remove(member) |> attach(description)
    end
  end

  defp attach(state, %Description{} = description) do
    generation = state.generation + 1
    state = %{state | generation: generation}

    case state.consent.(description, generation) do
      :ok ->
        {member, state} = admit(description, generation, state)
        Logger.info("#{member.role} #{member.name} joined from #{member.node}")
        notify(state, {:cluster_member_up, member})
        forget_refusal(state, description.node)

      {:error, reason} ->
        note(state, description.node, reason)
    end
  end

  # `nil` for anything on this machine.
  # extension nodes are separate VMs, and two VMs on one disk share every path. That is the
  # thing the label exists to warn about, so it is keyed to the machine.
  #
  # Otherwise whatever the registry entry called it, falling back to the address.
  defp machine_label(%Description{} = description, resources) do
    if description.node == node() or host_of(description.node) in Host.local_hosts() do
      nil
    else
      entry =
        resources
        |> Registry.remote()
        |> Enum.find(&(Registry.node_name(&1) == description.node))

      label = (entry && entry["machine"]) || host_of(description.node)
      slug(label)
    end
  end

  defp host_of(node) do
    node |> Atom.to_string() |> String.split("@") |> List.last()
  end

  # A tool name cannot hold a dot.
  defp slug(host), do: String.replace(host, ~r/[^a-zA-Z0-9]+/, "_")

  defp member_nodes(state) do
    # Members being held through a blip are deliberately *not* known: the next scan has to
    # ask them, because asking is the only way to find out they came back.
    for {key, member} <- state.members,
        not Map.has_key?(state.dropped, key),
        into: MapSet.new(),
        do: member.node
  end

  # A node refused for the same reason every couple of seconds is one line, not a stream.
  # Still re-asked each scan: the registry it failed against is a file someone may edit.
  defp note(state, node, reason) do
    if Map.get(state.refused, node) == reason do
      state
    else
      Logger.warning("not taking on #{node}: #{Protocol.describe_refusal(reason)}")
      put_in(state.refused[node], reason)
    end
  end

  defp forget_refusal(state, node), do: %{state | refused: Map.delete(state.refused, node)}

  defp call(request) do
    GenServer.call(__MODULE__, request)
  catch
    # Distribution off, or Eva shutting down. Callers treat it as "nobody is connected",
    # which is true.
    :exit, _reason -> empty_for(request)
  end

  defp empty_for({:members, _role}), do: []
  defp empty_for({:fetch, _role, _name}), do: :error
  defp empty_for(:refusals), do: %{}
  defp empty_for(_request), do: :ok

  defp refuse(%Description{} = description, state) do
    mine = Protocol.protocol_version()
    core = Protocol.core_version()

    cond do
      description.protocol_version != mine ->
        {:protocol_version, mine, description.protocol_version}

      description.core_version != core ->
        {:core_version, core, description.core_version}

      description.role not in [:extension, :harness] ->
        {:unknown_role, description.role}

      not allowed?(state, description) ->
        :not_allowed

      true ->
        taken_by(state, description)
    end
  end

  # A name is only exclusive *per machine*. `mcp` on the laptop and `mcp` on the devbox are
  # two different extensions, and wanting both in one session is the point of all this — so
  # the collision to catch is two VMs on the *same* machine claiming one name.
  defp taken_by(state, %Description{} = description) do
    clash =
      Enum.find(Map.values(state.members), fn member ->
        member.role == description.role and member.name == description.name and
          member.node != description.node and
          host_of(member.node) == host_of(description.node)
      end)

    if clash, do: {:name_taken, clash.node}
  end

  defp allowed?(%{allow: nil}, _description), do: true

  defp allowed?(%{allow: :registry} = state, %Description{role: :extension, name: name}) do
    name in Package.allowed_names(state.resources)
  end

  defp allowed?(%{allow: names}, %Description{role: :extension, name: name})
       when is_list(names) do
    name in names
  end

  # Only extensions are filtered by name. A `:harness` has no registry to be in.
  defp allowed?(_state, _description), do: true

  defp admit(%Description{} = description, generation, state) do
    key = {description.role, description.name, description.node}
    state = demote_previous(state, key)

    member = %{
      role: description.role,
      name: description.name,
      machine: machine_label(description, state.resources),
      node: description.node,
      pid: description.pid,
      core_version: description.core_version,
      generation: generation,
      joined_at: DateTime.utc_now()
    }

    # Monitoring the member's own process rather than its node: it fires for a crash and,
    # across a network, for a dropped connection — `:noconnection` arrives the same way.
    Process.monitor(description.pid)

    {member, %{state | members: Map.put(state.members, key, member)}}
  end

  # A node that restarted is attached again while its old entry may still be here — its
  # monitor has not necessarily fired yet. Drop the old one silently rather than letting a
  # late `:DOWN` remove the new one.
  defp demote_previous(state, key) do
    %{state | members: Map.delete(state.members, key)}
  end

  defp notify(state, message) do
    Enum.each(Map.keys(state.subscribers), &send(&1, message))
  end
end
