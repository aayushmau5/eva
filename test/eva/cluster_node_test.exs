defmodule Eva.ClusterNodeTest do
  @moduledoc """
  A real extension, on a real second node, joining a real directory.

  Everything here needs distribution, so it is tagged and excluded from the default run.
  `mix test.dist` starts a named VM and includes it.
  """

  use ExUnit.Case, async: false

  @moduletag :distributed
  @moduletag timeout: 120_000

  alias Eva.Cluster
  alias Eva.Coding.Resources
  alias Eva.Core.Extension.Context
  alias Eva.Extension.Set
  alias Eva.Test.ClusterNode

  setup_all do
    unless Node.alive?() do
      raise "these tests need a distributed VM — run `mix test.dist`"
    end

    :ok
  end

  setup do
    # `allow: nil` because none of this is about the allowlist — the default reads the
    # registry, and these fixtures were never registered.
    # A short grace: a node being killed is indistinguishable from a connection dropping,
    # so the real 8 seconds would be spent waiting in every test that stops a peer.
    start_supervised!({Eva.Cluster, allow: nil, grace: 200})

    {:ok, remote} = ClusterNode.start(:"fixture_#{System.unique_integer([:positive])}")
    on_exit(fn -> ClusterNode.stop(remote) end)

    %{remote: remote}
  end

  defp wait_until(fun, remaining \\ 5_000) do
    cond do
      value = fun.() -> value
      remaining <= 0 -> flunk("condition never became true")
      true -> Process.sleep(25) && wait_until(fun, remaining - 25)
    end
  end

  test "a node is dialled and lands in the directory", %{remote: remote} do
    :ok = Cluster.subscribe()

    {:ok, _pid} = ClusterNode.serve(remote, "fixture", Eva.Extension.Fixture)

    # Matched by name rather than taking the first message: Eva dials every extension
    # node on this machine, and a real one the developer happens to be running joins
    # this cluster too — including immediately, since `subscribe/0` replays members
    # that were already connected.
    assert_receive {:cluster_member_up, %{name: "fixture"} = member}, 5_000
    assert member.node == remote.node
    assert member.core_version == Eva.Core.Cluster.Protocol.core_version()

    # `in` rather than an exact list: Eva dials every extension node on the machine, and a
    # peer from an earlier test may still be shutting down. Not what this is about.
    assert member in Cluster.members(:extension)
  end

  test "the extension runs on the other node, not here", %{remote: remote} do
    {:ok, _pid} = ClusterNode.serve(remote, "fixture", Eva.Extension.Fixture)
    member = wait_until(fn -> match?({:ok, _}, Cluster.fetch(:extension, "fixture")) && one() end)

    context = %Context{
      name: "fixture",
      cwd: "/tmp/somewhere",
      model: "test-model",
      session_pid: self(),
      entries: [%{"remembered" => true}]
    }

    {:ok, pid, spec} =
      GenServer.call(member.pid, {:instantiate, context, member.generation})

    # The Server process lives on the extension's node — the pid is remote, and everything
    # from here on is ordinary message passing that happens to cross a machine boundary.
    assert node(pid) == remote.node
    assert node(pid) != node()

    assert spec.guidelines == ["fixture guideline for /tmp/somewhere"]
    assert [%{name: "fixture"}] = spec.commands

    # `setup/1` and `init/1` ran over there, with this session's context.
    assert GenServer.call(pid, {:command, "fixture", "hello"}) ==
             {:text, "fixture on #{remote.node} says hello"}

    assert GenServer.call(pid, {:extension_request, :where}) == {:ok, remote.node}
    assert GenServer.call(pid, {:extension_request, :entries}) == {:ok, [%{"remembered" => true}]}
  end

  test "the node reports which Evas it is serving", %{remote: remote} do
    {:ok, _pid} = ClusterNode.serve(remote, "fixture", Eva.Extension.Fixture)
    wait_until(fn -> match?({:ok, _}, Cluster.fetch(:extension, "fixture")) end)

    status = ClusterNode.call(remote, Eva.Core.Extension.Node, :status, [])

    assert status.name == "fixture"
    assert status.serving == [node()]
    # Out of the node name in T1, so it has to be reported somewhere or it is lost.
    assert is_binary(status.os_pid)
  end

  # The other half of the handshake. Eva chooses who it dials; the node chooses who it
  # answers. Being reachable is not the same as being available.
  test "a node that will not serve this Eva is not taken on", %{remote: remote} do
    {:ok, _pid} =
      ClusterNode.serve(remote, "fixture", Eva.Extension.Fixture,
        serve: [:"someone_else@127.0.0.1"]
      )

    refute Enum.any?(Cluster.members(:extension), &(&1.node == remote.node))
    assert Cluster.refusals()[remote.node] == :not_consented

    status = ClusterNode.call(remote, Eva.Core.Extension.Node, :status, [])
    assert status.serving == []
  end

  # Nothing on the node re-announces any more, so the only thing `nodedown` is still for is
  # forgetting: an Eva that died leaves a generation behind, and a node that keeps claiming
  # to serve it is lying.
  test "an Eva that goes away is forgotten", %{remote: remote} do
    {:ok, _pid} = ClusterNode.serve(remote, "fixture", Eva.Extension.Fixture)
    wait_until(fn -> match?({:ok, _}, Cluster.fetch(:extension, "fixture")) end)

    assert ClusterNode.call(remote, Eva.Core.Extension.Node, :status, []).serving == [node()]

    # Delivered by hand rather than by killing this VM, which the test is running in. It
    # is the same message `monitor_nodes/1` would send.
    send({Eva.Core.Extension.Node, remote.node}, {:nodedown, node()})

    wait_until(fn ->
      ClusterNode.call(remote, Eva.Core.Extension.Node, :status, []).serving == []
    end)
  end

  # §9's whole point, end to end. The label is what turns "are these paths mine?" from a
  # guess into a comparison, and a peer on this machine must say `nil` — a separate VM, but
  # the same disk.
  test "a node on this machine is told its paths are readable", %{remote: remote} do
    {:ok, _pid} = ClusterNode.serve(remote, "fixture", Eva.Extension.Fixture)
    member = wait_until(fn -> match?({:ok, _}, Cluster.fetch(:extension, "fixture")) && one() end)

    assert member.machine == nil

    context = %Context{name: "fixture", cwd: "/tmp", session_pid: self(), machine: member.machine}
    assert Context.same_machine?(context)

    {:ok, _pid, _spec} = GenServer.call(member.pid, {:instantiate, context, member.generation})
  end

  test "a stale generation is refused", %{remote: remote} do
    {:ok, _pid} = ClusterNode.serve(remote, "fixture", Eva.Extension.Fixture)
    member = wait_until(fn -> match?({:ok, _}, Cluster.fetch(:extension, "fixture")) && one() end)

    context = %Context{name: "fixture", cwd: "/tmp", session_pid: self()}

    assert GenServer.call(member.pid, {:instantiate, context, member.generation - 1}) ==
             {:error, :stale_generation}
  end

  test "the node going away removes it, and the session hears", %{remote: remote} do
    :ok = Cluster.subscribe()
    {:ok, _pid} = ClusterNode.serve(remote, "fixture", Eva.Extension.Fixture)
    assert_receive {:cluster_member_up, %{name: "fixture"}}, 5_000

    ClusterNode.stop(remote)

    assert_receive {:cluster_member_down, %{name: "fixture"}}, 5_000
    # Only that the fixture is gone: any extension node the developer is running on
    # this machine is also in the directory, and is not this test's business.
    refute Enum.any?(Cluster.members(:extension), &(&1.name == "fixture"))
  end

  test "an extension refused by the allowlist stays out", %{remote: remote} do
    :ok = Cluster.allow(["something-else"])
    on_exit(fn -> Cluster.allow(nil) end)

    # A name no other test uses, so the only reason this can be refused is the allowlist.
    {:ok, _pid} = ClusterNode.serve(remote, "refused-fixture", Eva.Extension.Fixture)

    # Nothing to wait for: `serve` scans, so if it were going to be taken on it already
    # would have been. Eva keeps looking rather than giving up, so the refusal is re-made
    # every scan — which is what makes editing the registry work on a running Eva.
    refute Enum.any?(Cluster.members(:extension), &(&1.node == remote.node))
    assert Cluster.refusals()[remote.node] == :not_allowed
  end

  # `wait_until` wants a truthy value; the member itself comes from the fetch.
  defp one do
    {:ok, member} = Cluster.fetch(:extension, "fixture")
    member
  end
end

defmodule Eva.ClusterSetTest do
  @moduledoc """
  A session's `Set` with an extension that lives on another node.

  The point of these: a remote extension is not a special case anywhere except in how it
  is found. Commands, guidelines, ordering and teardown all go through the same code an
  in-VM extension does.
  """

  use ExUnit.Case, async: false

  @moduletag :distributed
  @moduletag timeout: 120_000

  alias Eva.Cluster
  alias Eva.Coding.Resources
  alias Eva.Extension.Set
  alias Eva.Test.ClusterNode

  setup do
    # `allow: nil` because none of this is about the allowlist — the default reads the
    # registry, and these fixtures were never registered.
    start_supervised!({Eva.Cluster, allow: nil})

    {:ok, remote} = ClusterNode.start(:"set_#{System.unique_integer([:positive])}")
    on_exit(fn -> ClusterNode.stop(remote) end)

    {:ok, _pid} = ClusterNode.serve(remote, "fixture", Eva.Extension.Fixture)
    wait_until(fn -> Cluster.members(:extension) != [] end)

    root = Path.join(System.tmp_dir!(), "cluster_set_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    %{remote: remote, resources: %Resources{root: root}}
  end

  defp wait_until(fun, remaining \\ 5_000) do
    cond do
      value = fun.() -> value
      remaining <= 0 -> flunk("condition never became true")
      true -> Process.sleep(25) && wait_until(fun, remaining - 25)
    end
  end

  test "a session picks up an already-served extension at load", %{
    remote: remote,
    resources: resources
  } do
    set = Set.load(resources, self(), %{cwd: "/tmp/project"})

    assert "fixture" in set.order
    assert set.diagnostics == []
    assert "fixture guideline for /tmp/project" in Set.guidelines(set)

    # It runs over there, and the command round-trips.
    assert Set.run_command(set, "fixture", "hi") == {:text, "fixture on #{remote.node} says hi"}

    # By name, not by being the only one: any extension node reachable with this cookie
    # joins here too — including one running on another machine — and `Cluster.subscribe/0`
    # replays those immediately rather than a scan later.
    info = Enum.find(Set.list(set), &(&1.name == "fixture"))
    assert info.node == remote.node
    assert info.path == nil
    assert info.running?
  end

  test "an extension that appears later joins the session", %{
    remote: remote,
    resources: resources
  } do
    # A set that has never heard of it — the state a session is in when someone runs
    # `mix eva.ext.start` a minute after opening Eva.
    empty = Set.empty()
    assert empty.order == []

    {:ok, member} = Cluster.fetch(:extension, "fixture")
    set = Set.add_member(empty, member, self(), %{cwd: "/tmp/project"})

    assert set.order == ["fixture"]

    assert Set.run_command(set, "fixture", "later") ==
             {:text, "fixture on #{remote.node} says later"}
  end

  test "a local script of the same name wins", %{resources: resources} do
    dir = Path.join(resources.root, "extensions")
    File.mkdir_p!(dir)

    # The script below defines a module this VM already has, from `test/support`. Put the
    # compiled one back afterwards so nothing later inherits the stub.
    on_exit(fn ->
      :code.purge(Eva.Extension.Fixture)
      :code.delete(Eva.Extension.Fixture)
      Code.ensure_loaded(Eva.Extension.Fixture)
    end)

    File.write!(Path.join(dir, "fixture.exs"), """
    defmodule Eva.Extension.Fixture.Local do
      @moduledoc "Named to avoid colliding with the fixture module this VM already has."
    end

    defmodule Eva.Extension.Fixture do
      use Eva.Core.Extension

      def setup(_ctx), do: {:ok, %Eva.Core.Extension.Spec{guidelines: ["the local one"]}}
    end
    """)

    set = Set.load(resources, self(), %{cwd: "/tmp/project"})

    # The local script's guideline is present and the served node's is not — that is what
    # "wins" means here. Not an exact list: other extension nodes on this machine
    # contribute their own guidelines and are not what this test is about.
    guidelines = Set.guidelines(set)
    assert "the local one" in guidelines
    refute "fixture guideline for /tmp/project" in guidelines

    assert Map.has_key?(set.loaded, "fixture")
    refute Map.has_key?(set.remote, "fixture")
  end

  test "the node going away drops the extension from the set", %{
    remote: remote,
    resources: resources
  } do
    set = Set.load(resources, self(), %{cwd: "/tmp/project"})
    pid = Map.fetch!(set.remote, "fixture")

    ClusterNode.stop(remote)

    # Whoever owns the set monitors the pid; here that is the test process.
    assert_receive {:DOWN, _ref, :process, ^pid, _reason}, 5_000

    dropped = Set.drop(set, pid, :shutdown)

    # Only the fixture's departure is asserted: another machine's extension node may be
    # in this set too, and dropping this one says nothing about that one.
    refute "fixture" in dropped.order
    refute Map.has_key?(dropped.remote, "fixture")
    refute Map.has_key?(dropped.members, "fixture")
  end

  test "shutdown stops the remote extension", %{resources: resources} do
    set = Set.load(resources, self(), %{cwd: "/tmp/project"})
    pid = Map.fetch!(set.remote, "fixture")

    # `Process.alive?/1` refuses a remote pid — asking a node about its own processes is
    # the only way to know.
    assert alive?(pid)

    :ok = Set.shutdown(set, :shutdown)

    wait_until(fn -> not alive?(pid) end)
  end

  defp alive?(pid), do: :erpc.call(node(pid), Process, :alive?, [pid])
end

defmodule Eva.ClusterToolsTest do
  @moduledoc """
  The one thing that cannot cross a node boundary, and the proxy that makes it look as if
  it did.

  A closure carries a reference to its defining module, so an executor sent to a host that
  lacks the extension's modules fails with `badfun`. These assert that an author writing
  `executor: fn args, ctx -> ... end` gets a working tool anyway.
  """

  use ExUnit.Case, async: false

  @moduletag :distributed
  @moduletag timeout: 120_000

  alias Eva.Core.Agent.Tools
  alias Eva.Cluster
  alias Eva.Coding.Resources
  alias Eva.Extension.Set
  alias Eva.Test.ClusterNode

  setup do
    # `allow: nil` because none of this is about the allowlist — the default reads the
    # registry, and these fixtures were never registered.
    start_supervised!({Eva.Cluster, allow: nil})

    {:ok, remote} = ClusterNode.start(:"tools_#{System.unique_integer([:positive])}")
    on_exit(fn -> ClusterNode.stop(remote) end)

    {:ok, _pid} = ClusterNode.serve(remote, "fixture", Eva.Extension.Fixture)
    wait_until(fn -> Cluster.members(:extension) != [] end)

    root = Path.join(System.tmp_dir!(), "cluster_tools_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    set = Set.load(%Resources{root: root}, self(), %{cwd: "/tmp/project"})

    %{remote: remote, set: set}
  end

  defp wait_until(fun, remaining \\ 5_000) do
    cond do
      value = fun.() -> value
      remaining <= 0 -> flunk("condition never became true")
      true -> Process.sleep(25) && wait_until(fun, remaining - 25)
    end
  end

  # By name, never "the only tool in the set". Eva dials every extension node it can
  # reach, so a real one the developer is running contributes its tools here too — and
  # a developer working on extensions always has one running.
  defp fixture_tool(set) do
    Enum.find(Set.tools(set), &(&1.name == "fixture_echo")) ||
      flunk("fixture_echo not in the set")
  end

  test "a remote tool arrives without its closure", %{set: set, remote: remote} do
    tool = fixture_tool(set)

    assert tool.name == "fixture_echo"
    assert tool.description == "Echoes its argument back"

    # The executor is not the one the extension wrote — that one never left its node.
    assert is_function(tool.executor, 2)

    # It is still registered over there, keyed by this session.
    assert ClusterNode.call(remote, Eva.Core.Extension.ToolRegistry, :tools, ["fixture", self()]) ==
             ["fixture_echo"]
  end

  test "calling it runs the real body on the other node", %{set: set} do
    tool = fixture_tool(set)

    result = tool.executor.(%{"text" => "over there"}, nil)

    assert %Tools.AgentToolResult{content: [%{text: "echo: over there"}]} = result
  end

  test "a raise on the far side comes back as an error, not a hang", %{set: set, remote: remote} do
    tool = fixture_tool(set)

    # Replace the registered executor with one that blows up, the way a real tool would.
    register(remote, [:exploding])

    assert_raise RuntimeError, "tool exploded", fn ->
      tool.executor.(%{"text" => "boom"}, nil)
    end
  end

  test "a tool nobody registered says so rather than crashing", %{set: set, remote: remote} do
    tool = fixture_tool(set)

    register(remote, [])

    assert_raise RuntimeError, ~r/no registered tool named fixture_echo/, fn ->
      tool.executor.(%{"text" => "gone"}, nil)
    end
  end

  test "the registry does not serialize slow tools", %{set: set, remote: remote} do
    register(remote, [:slow, :quick])

    # Bind proxies for the new names, the way `{:extension_update_tools, ...}` would.
    set =
      Set.put_tools(set, "fixture", [
        Eva.Test.RemoteTools.description("slow"),
        Eva.Test.RemoteTools.description("quick")
      ])

    %{"slow" => slow_tool, "quick" => quick_tool} =
      Map.new(Set.tools(set), &{&1.name, &1})

    slow = Task.async(fn -> slow_tool.executor.(%{}, nil) end)
    # Long enough that the slow tool is definitely inside the registry.
    Process.sleep(50)

    # If executors ran in `handle_call`, this would queue behind the slow one and take
    # ~400ms. It should come back immediately.
    {elapsed, quick} = :timer.tc(fn -> quick_tool.executor.(%{}, nil) end)

    assert quick == :quick_done
    assert elapsed < 200_000, "quick tool waited #{div(elapsed, 1000)}ms behind a slow one"
    assert Task.await(slow) == :slow_done
  end

  defp register(remote, kinds) do
    ClusterNode.call(remote, Eva.Test.RemoteTools, :register, ["fixture", self(), kinds])
  end
end

defmodule Eva.ClusterCapabilitiesTest do
  @moduledoc """
  An extension on another node reaching back for a capability.

  The point of `Context.capabilities` is that an extension never names a host module. What
  it holds differs between the two tiers; what it *writes* does not.
  """

  use ExUnit.Case, async: false

  @moduletag :distributed
  @moduletag timeout: 120_000

  alias Eva.Cluster
  alias Eva.Coding.Resources
  alias Eva.Extension.Set
  alias Eva.Test.ClusterNode

  setup do
    # `allow: nil` because none of this is about the allowlist — the default reads the
    # registry, and these fixtures were never registered.
    start_supervised!({Eva.Cluster, allow: nil})

    {:ok, remote} = ClusterNode.start(:"caps_#{System.unique_integer([:positive])}")
    on_exit(fn -> ClusterNode.stop(remote) end)

    {:ok, _pid} = ClusterNode.serve(remote, "fixture", Eva.Extension.Fixture)

    root = Path.join(System.tmp_dir!(), "cluster_caps_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    wait_until(fn -> Cluster.members(:extension) != [] end)
    set = Set.load(%Resources{root: root}, self(), %{cwd: "/tmp/project"})

    %{remote: remote, set: set, pid: Map.fetch!(set.remote, "fixture")}
  end

  defp wait_until(fun, remaining \\ 5_000) do
    cond do
      value = fun.() -> value
      remaining <= 0 -> flunk("condition never became true")
      true -> Process.sleep(25) && wait_until(fun, remaining - 25)
    end
  end

  test "a remote extension gets the remote implementation", %{pid: pid} do
    assert GenServer.call(pid, {:extension_request, :capabilities_module}) ==
             {:ok, Eva.Core.Extension.Capabilities.Remote}
  end

  test "asking runs on the host and the answer comes back", %{pid: pid} do
    # The host's `ask/3` is still the stub that returns the caller's default, so what this
    # actually proves is the round trip: the call left the node, resolved a module that
    # exists only here, and returned.
    assert GenServer.call(pid, {:extension_request, {:ask, %{kind: :confirm}, :the_default}}) ==
             {:ok, :the_default}
  end

  test "a host that has gone away falls back rather than crashing the extension", %{
    remote: remote,
    pid: pid
  } do
    # A pid belonging to a node that has since died — what an extension is left holding
    # when Eva exits mid-question.
    {:ok, doomed} = ClusterNode.start(:"doomed_#{System.unique_integer([:positive])}")
    dead_pid = ClusterNode.call(doomed, Process, :whereis, [:init])
    ClusterNode.stop(doomed)

    # `ask/3` has to answer something, and the default is the same answer a host with no
    # frontend attached would give.
    answer =
      ClusterNode.call(remote, Eva.Core.Extension.Capabilities.Remote, :ask, [
        %{kind: :confirm},
        :fallback,
        [session_pid: dead_pid]
      ])

    assert answer == :fallback
    # And the extension itself is still alive to be asked again.
    assert GenServer.call(pid, {:extension_request, :where}) == {:ok, remote.node}
  end
end
