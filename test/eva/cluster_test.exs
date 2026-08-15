defmodule Eva.ClusterTest do
  @moduledoc """
  The directory's own behaviour, with no second VM involved.

  Eva dials, so the two steps of dialling — finding candidates and asking one to take this
  Eva on — are handed in rather than reaching epmd. What comes back is a struct and a pid;
  whether it arrived over distribution is not something this has an opinion about. The
  real two-node dial is `test/eva/cluster_node_test.exs`, which is slower and tagged.

  Scanning is driven by hand (`scan_interval: :never`), so nothing here depends on timing.
  """

  use ExUnit.Case, async: false

  alias Eva.Cluster
  alias Eva.Core.Cluster.Protocol
  alias Eva.Coding.Resources
  alias Eva.Extension.Registry

  setup do
    # Descriptions the next scan will find. A queue rather than a fixed list so a test can
    # say "now this one appears" and scan again.
    {:ok, found} = Agent.start_link(fn -> [] end)

    start_directory(found, allow: nil)

    %{found: found}
  end

  # `allow: nil` because most of this file is about joining rather than about who may: the
  # default reads the registry, and none of these fixtures are registered.
  defp start_directory(found, opts) do
    opts =
      Keyword.merge(opts,
        scan_interval: :never,
        look: fn _known, _resources -> Agent.get_and_update(found, &{&1, []}) end,
        consent: fn _description, _generation -> :ok end
      )

    start_supervised!({Cluster, opts})
  end

  defp member_process do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  # Queues a node for the next scan and runs one, so a test reads as "this is out there;
  # go and look".
  defp offer(found, name, overrides \\ %{}) do
    description =
      :extension
      |> Protocol.description(name, member_process())
      |> Map.merge(overrides)

    Agent.update(found, &(&1 ++ [{description.node, description}]))
    description
  end

  defp scan(server \\ Cluster) do
    :ok = GenServer.call(server, :scan_now)
  end

  describe "joining" do
    test "an extension is dialled and can be found", %{found: found} do
      offer(found, "fixture")
      scan()

      assert [member] = Cluster.members(:extension)
      assert member.name == "fixture"
      assert member.node == node()
      assert is_integer(member.generation)

      assert {:ok, ^member} = Cluster.fetch(:extension, "fixture")
      assert Cluster.fetch(:extension, "nope") == :error
      assert Cluster.members(:harness) == []
    end

    test "generations increase, so a reconnect is distinguishable from the first join",
         %{found: found} do
      offer(found, "fixture")
      scan()
      [%{generation: first}] = Cluster.members(:extension)

      offer(found, "fixture")
      scan()
      [%{generation: second}] = Cluster.members(:extension)

      assert second > first
      # The same node dialled again replaces itself rather than joining twice.
      assert length(Cluster.members(:extension)) == 1
    end

    test "members come back in join order", %{found: found} do
      offer(found, "a")
      scan()
      offer(found, "b")
      scan()

      assert Enum.map(Cluster.members(:extension), & &1.name) == ["a", "b"]
    end

    # The point of the inversion: nothing is waiting to be told, so a node that appears
    # later is picked up by simply looking again.
    test "a node that was not there yet is found on a later scan", %{found: found} do
      scan()
      assert Cluster.members(:extension) == []

      offer(found, "fixture")
      scan()

      assert [%{name: "fixture"}] = Cluster.members(:extension)
    end

    test "a node already taken on is not offered again", %{found: found} do
      # The real `look/1` filters by the known set rather than by anything the node says,
      # so what it is handed has to be right.
      me = self()

      start_supervised!(
        Supervisor.child_spec(
          {Cluster,
           name: :known_directory,
           allow: nil,
           scan_interval: :never,
           consent: fn _d, _g -> :ok end,
           look: fn known, _resources ->
             send(me, {:known, known})
             Agent.get_and_update(found, &{&1, []})
           end},
          id: :known_directory
        )
      )

      # Starting the directory scans once by itself, so that one is accounted for first.
      assert_receive {:known, _on_startup}

      offer(found, "fixture")
      scan(:known_directory)
      assert_receive {:known, first}
      assert MapSet.size(first) == 0

      scan(:known_directory)
      assert_receive {:known, second}
      assert MapSet.member?(second, node())
    end
  end

  describe "refusing" do
    test "a mismatched core version, because the struct shapes would not match",
         %{found: found} do
      offer(found, "fixture", %{core_version: "0.0.1"})
      scan()

      assert Cluster.members(:extension) == []
      assert {:core_version, mine, "0.0.1"} = Cluster.refusals()[node()]
      assert mine == Protocol.core_version()
    end

    test "a protocol from another era", %{found: found} do
      offer(found, "fixture", %{protocol_version: 99})
      scan()

      assert {:protocol_version, _mine, 99} = Cluster.refusals()[node()]
    end

    test "a role nobody has heard of", %{found: found} do
      offer(found, "fixture", %{role: :printer})
      scan()

      assert Cluster.refusals()[node()] == {:unknown_role, :printer}
    end

    # A name is exclusive per machine, not per cluster. Two VMs here both calling themselves
    # `fixture` is a mistake; the same name on another machine is the whole feature.
    test "a name another node on this machine already holds", %{found: found} do
      offer(found, "fixture")
      scan()

      offer(found, "fixture", %{node: :other_vm@nohost})
      scan()

      assert Cluster.refusals()[:other_vm@nohost] == {:name_taken, node()}
      assert length(Cluster.members(:extension)) == 1
    end

    test "both same-machine claimants in one scan, so the second does not race the first",
         %{found: found} do
      # Refusals are decided as the answers are folded in rather than in parallel, which is
      # the only reason a name taken microseconds earlier counts as taken.
      offer(found, "fixture")
      offer(found, "fixture", %{node: :other_vm@nohost})
      scan()

      assert [%{node: mine}] = Cluster.members(:extension)
      assert mine == node()
      assert Cluster.refusals()[:other_vm@nohost] == {:name_taken, node()}
    end

    test "the same name on another machine is not a collision at all", %{found: found} do
      offer(found, "fixture")
      scan()

      offer(found, "fixture", %{node: :"eva_ext_fixture@100.64.5.20"})
      scan()

      assert Cluster.refusals() == %{}
      assert [here, there] = Cluster.members(:extension)
      assert here.name == "fixture" and here.machine == nil
      assert there.name == "fixture" and there.machine == "100_64_5_20"
    end

    test "a name that is not on the allowlist", %{found: found} do
      :ok = Cluster.allow(["mcp"])

      offer(found, "fixture")
      scan()
      assert Cluster.refusals()[node()] == :not_allowed

      offer(found, "mcp")
      scan()
      assert [%{name: "mcp"}] = Cluster.members(:extension)

      # `nil` means "anything".
      :ok = Cluster.allow(nil)
      offer(found, "fixture")
      scan()
      assert length(Cluster.members(:extension)) == 2
    end

    test "a node that declines to serve this Eva", %{found: found} do
      # The other half of the handshake: Eva chooses who it dials, the node chooses who it
      # answers, and neither can force the other.
      start_supervised!(
        Supervisor.child_spec(
          {Cluster,
           name: :declined_directory,
           allow: nil,
           scan_interval: :never,
           look: fn _known, _resources -> Agent.get_and_update(found, &{&1, []}) end,
           consent: fn _description, _generation -> {:error, :not_consented} end},
          id: :declined_directory
        )
      )

      offer(found, "fixture")
      scan(:declined_directory)

      assert GenServer.call(:declined_directory, {:members, :extension}) == []
      assert GenServer.call(:declined_directory, :refusals)[node()] == :not_consented
    end

    # The bug this replaced: the allowlist used to be read once, at application start, and
    # copied into state. Registering an extension into a *running* Eva then did nothing —
    # the node was refused forever with its name sitting in the file.
    test "the registry is read at each scan, not memorised", %{found: found} do
      root = Path.join(System.tmp_dir!(), "cluster_allow_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(root) end)

      resources = %Resources{root: root}

      start_supervised!(
        Supervisor.child_spec(
          {Cluster,
           name: :allowlist_directory,
           allow: :registry,
           resources: resources,
           scan_interval: :never,
           look: fn _known, _resources -> Agent.get_and_update(found, &{&1, []}) end,
           consent: fn _d, _g -> :ok end},
          id: :allowlist_directory
        )
      )

      offer(found, "mcp")
      scan(:allowlist_directory)
      assert GenServer.call(:allowlist_directory, {:members, :extension}) == []

      # Registered after the directory is already up, which is the whole point.
      :ok = Registry.put(resources, %{"name" => "mcp", "kind" => "project", "dir" => root})

      offer(found, "mcp")
      scan(:allowlist_directory)
      assert [%{name: "mcp"}] = GenServer.call(:allowlist_directory, {:members, :extension})
    end

    test "a refusal explains itself in words" do
      assert Protocol.describe_refusal({:core_version, "0.2.0", "0.1.0"}) =~
               "built against eva_core 0.1.0"

      assert Protocol.describe_refusal(:not_allowed) =~ "allowlist"
      assert Protocol.describe_refusal(:not_consented) =~ ":serve"
    end
  end

  describe "leaving" do
    test "a member that dies is dropped", %{found: found} do
      %{pid: pid} = offer(found, "fixture")
      scan()

      assert [_member] = Cluster.members(:extension)

      Process.exit(pid, :kill)

      # The monitor fires asynchronously; the next call is ordered behind it.
      wait_until(fn -> Cluster.members(:extension) == [] end)
    end

    test "and is dialled again when it comes back", %{found: found} do
      %{pid: pid} = offer(found, "fixture")
      scan()
      Process.exit(pid, :kill)
      wait_until(fn -> Cluster.members(:extension) == [] end)

      # Re-dialling is not its own mechanism — the node is simply no longer known, so the
      # next ordinary scan picks it up.
      offer(found, "fixture")
      scan()

      assert [%{name: "fixture"}] = Cluster.members(:extension)
    end
  end

  describe "what a remote extension is told about paths" do
    alias Eva.Core.Extension.Context
    alias Eva.Extension.Set

    test "a context from the same machine says its paths are readable" do
      context = %Context{name: "mcp", cwd: "/home/me/project", machine: nil}

      assert Context.same_machine?(context)
    end

    test "a context from another machine says they are not" do
      # The failure this exists for has no error message: `~/project/config.exs` may exist
      # on both boxes with different contents, and reading it just returns the wrong file.
      context = %Context{name: "mcp", cwd: "/home/me/project", machine: "devbox"}

      refute Context.same_machine?(context)
      # The path is still there. Blanking it would lose what the session is *about*, which
      # an extension may legitimately want to know.
      assert context.cwd == "/home/me/project"
    end

    test "the slot and the tool prefix agree with the label" do
      assert Set.slot(%{name: "mcp", machine: nil}) == "mcp"
      assert Set.slot(%{name: "mcp", machine: "devbox"}) == "devbox__mcp"
    end

    # The bug this replaced: the session dropped a departing member by `member.name`, but a
    # remote extension sits under its slot — so it stayed in the set with its tools bound to
    # a node that had gone.
    test "a departing member is dropped by the key it was filed under" do
      remote = %{name: "mcp", machine: "devbox", node: :"eva_ext_mcp@100.64.5.20"}
      local = %{name: "mcp", machine: nil, node: node()}

      assert Set.slot(remote) == "devbox__mcp"
      assert Set.slot(local) == "mcp"
      refute Set.slot(remote) == remote.name
    end
  end

  describe "detaching" do
    test "drops the member and stops dialling it", %{found: found} do
      offer(found, "fixture")
      scan()
      assert [_member] = Cluster.members(:extension)

      assert Cluster.detach(:extension, "fixture", node()) == :ok
      assert Cluster.members(:extension) == []
      assert Cluster.detached() == [{:extension, "fixture", node()}]

      # The half that matters. Disconnecting alone would be undone two seconds later by the
      # very scan that makes re-dialling work.
      offer(found, "fixture")
      scan()
      assert Cluster.members(:extension) == []
    end

    test "tells sessions, the same as any other departure", %{found: found} do
      :ok = Cluster.subscribe()
      offer(found, "fixture")
      scan()
      assert_receive {:cluster_member_up, _member}

      :ok = Cluster.detach(:extension, "fixture", node())
      assert_receive {:cluster_member_down, %{name: "fixture"}}
    end

    test "detaching something that is not here still stops it being dialled",
         %{found: found} do
      assert Cluster.detach(:extension, "fixture", node()) == :error

      offer(found, "fixture")
      scan()
      assert Cluster.members(:extension) == []
    end

    # The bug this replaced: `detach` matched on role and name only, picked whichever member
    # the map happened to yield first, and then blocked the name everywhere — so it detached
    # an arbitrary one of the two and stopped the other coming back. The node is required
    # now precisely so there is nothing to pick.
    test "with the same name on two machines, only the named one goes", %{found: found} do
      here = offer(found, "mcp")
      there = offer(found, "mcp", %{node: :"eva_ext_mcp@100.64.5.20"})
      scan()
      assert length(Cluster.members(:extension)) == 2

      assert Cluster.detach(:extension, "mcp", there.node) == :ok

      assert [survivor] = Cluster.members(:extension)
      assert survivor.node == here.node

      # And the one left behind is still dialable — the block was for that node, not the name.
      offer(found, "mcp")
      scan()
      assert [%{node: still_here}] = Cluster.members(:extension)
      assert still_here == here.node
    end

    test "reattaching lets the next scan take it back", %{found: found} do
      offer(found, "fixture")
      scan()
      :ok = Cluster.detach(:extension, "fixture", node())

      :ok = Cluster.reattach(:extension, "fixture", node())
      assert Cluster.detached() == []

      offer(found, "fixture")
      scan()
      assert [%{name: "fixture"}] = Cluster.members(:extension)
    end
  end

  describe "a connection that drops" do
    test "is held rather than reported, so a blip does not reach a turn", %{found: found} do
      :ok = Cluster.subscribe()
      %{pid: pid} = offer(found, "fixture")
      scan()
      assert_receive {:cluster_member_up, _member}

      send(Cluster, {:DOWN, make_ref(), :process, pid, :noconnection})

      # Still a member, and nothing told the session.
      assert [%{name: "fixture"}] = Cluster.members(:extension)
      refute_receive {:cluster_member_down, _member}, 100
    end

    test "and comes back is silent all the way through", %{found: found} do
      :ok = Cluster.subscribe()
      description = offer(found, "fixture")
      scan()
      assert_receive {:cluster_member_up, member}

      send(Cluster, {:DOWN, make_ref(), :process, description.pid, :noconnection})

      # The same process answering again: the connection blipped and nothing else did.
      Agent.update(found, &(&1 ++ [{description.node, description}]))
      scan()

      assert [restored] = Cluster.members(:extension)
      # Same generation, so a session holding one is not suddenly stale.
      assert restored.generation == member.generation
      refute_receive {:cluster_member_down, _member}, 100
    end

    test "but comes back as a different process is a real restart", %{found: found} do
      :ok = Cluster.subscribe()
      first = offer(found, "fixture")
      scan()
      assert_receive {:cluster_member_up, _member}

      send(Cluster, {:DOWN, make_ref(), :process, first.pid, :noconnection})

      offer(found, "fixture")
      scan()

      # Sessions have to hear: their generation is stale and their tools are gone.
      assert_receive {:cluster_member_down, %{name: "fixture"}}
      assert [%{name: "fixture"}] = Cluster.members(:extension)
    end

    test "a process that actually died is reported at once", %{found: found} do
      :ok = Cluster.subscribe()
      %{pid: pid} = offer(found, "fixture")
      scan()
      assert_receive {:cluster_member_up, _member}

      # Not `:noconnection` — nothing to wait for.
      Process.exit(pid, :kill)

      assert_receive {:cluster_member_down, %{name: "fixture"}}
      wait_until(fn -> Cluster.members(:extension) == [] end)
    end
  end

  describe "subscribers" do
    test "hear about members arriving and leaving", %{found: found} do
      :ok = Cluster.subscribe()

      %{pid: pid} = offer(found, "fixture")
      scan()

      assert_receive {:cluster_member_up, %{name: "fixture"}}

      Process.exit(pid, :kill)
      assert_receive {:cluster_member_down, %{name: "fixture"}}
    end

    test "subscribing twice does not double up", %{found: found} do
      :ok = Cluster.subscribe()
      :ok = Cluster.subscribe()

      offer(found, "fixture")
      scan()

      assert_receive {:cluster_member_up, _member}
      refute_receive {:cluster_member_up, _member}, 50
    end
  end

  describe "when Eva is not accepting members" do
    test "asking is answered, not an exit" do
      stop_supervised!(Eva.Cluster)

      assert Cluster.members(:extension) == []
      assert Cluster.fetch(:extension, "mcp") == :error
      assert Cluster.refusals() == %{}
      refute Cluster.running?()
    end
  end

  defp wait_until(fun, remaining \\ 100) do
    cond do
      fun.() -> :ok
      remaining <= 0 -> flunk("condition never became true")
      true -> Process.sleep(10) && wait_until(fun, remaining - 10)
    end
  end
end
