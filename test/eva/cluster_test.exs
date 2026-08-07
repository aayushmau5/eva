defmodule Eva.ClusterTest do
  @moduledoc """
  The directory's own behaviour, with no second VM involved.

  An announcement is a struct and a pid; whether it arrived over distribution is not
  something this has an opinion about. The two-node join is
  `test/eva/cluster_node_test.exs`, which is slower and tagged.
  """

  use ExUnit.Case, async: false

  alias Eva.Cluster
  alias Eva.Cluster.Protocol
  alias Eva.Cluster.Protocol.Announcement
  alias Eva.Coding.Resources
  alias Eva.Extension.Registry

  setup do
    # The application only starts the directory when distribution is on, so tests own it.
    # `allow: nil` because most of this file is about joining rather than about who may:
    # the default reads the registry, and none of these fixtures are registered.
    start_supervised!({Eva.Cluster, allow: nil})
    :ok
  end

  defp member_process do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp announce(name, overrides \\ %{}), do: announce_to(Cluster, name, overrides)

  defp announce_to(server, name, overrides \\ %{}) do
    announcement =
      :extension
      |> Protocol.announcement(name, member_process())
      |> Map.merge(overrides)

    GenServer.call(server, {:announce, announcement})
  end

  describe "joining" do
    test "an extension joins and can be found" do
      assert {:ok, generation} = announce("fixture")
      assert is_integer(generation)

      assert [member] = Cluster.members(:extension)
      assert member.name == "fixture"
      assert member.node == node()
      assert member.generation == generation

      assert {:ok, ^member} = Cluster.fetch(:extension, "fixture")
      assert Cluster.fetch(:extension, "nope") == :error
      assert Cluster.members(:harness) == []
    end

    test "generations increase, so a reconnect is distinguishable from the first join" do
      {:ok, first} = announce("fixture")
      {:ok, second} = announce("fixture")

      assert second > first
      # The same node re-announcing replaces itself rather than joining twice.
      assert length(Cluster.members(:extension)) == 1
    end

    test "members come back in join order" do
      {:ok, _} = announce("a")
      {:ok, _} = announce("b")

      assert Enum.map(Cluster.members(:extension), & &1.name) == ["a", "b"]
    end
  end

  describe "refusing" do
    test "a mismatched core version, because the struct shapes would not match" do
      assert {:error, {:core_version, mine, "0.0.1"}} =
               announce("fixture", %{core_version: "0.0.1"})

      assert mine == Protocol.core_version()
      assert Cluster.members(:extension) == []
    end

    test "a protocol from another era" do
      assert {:error, {:protocol_version, _mine, 99}} =
               announce("fixture", %{protocol_version: 99})
    end

    test "a role nobody has heard of" do
      assert {:error, {:unknown_role, :printer}} = announce("fixture", %{role: :printer})
    end

    test "a name another node already holds" do
      {:ok, _} = announce("fixture")

      assert {:error, {:name_taken, held_by}} =
               announce("fixture", %{node: :"someone_else@127.0.0.1"})

      assert held_by == node()
    end

    test "a name that is not on the allowlist" do
      :ok = Cluster.allow(["mcp"])

      assert {:error, :not_allowed} = announce("fixture")
      assert {:ok, _generation} = announce("mcp")

      # `nil` means "anything".
      :ok = Cluster.allow(nil)
      assert {:ok, _generation} = announce("fixture")
    end

    # The bug this replaced: the allowlist used to be read once, at application start, and
    # copied into state. Registering an extension into a *running* Eva then did nothing —
    # the node knocked, was refused, and retried forever with its name sitting in the file.
    test "the registry is read at each announcement, not memorised" do
      root = Path.join(System.tmp_dir!(), "cluster_allow_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(root) end)

      resources = %Resources{root: root}

      directory =
        start_supervised!(
          Supervisor.child_spec(
            {Cluster, name: :allowlist_directory, allow: :registry, resources: resources},
            id: :allowlist_directory
          )
        )

      assert {:error, :not_allowed} = announce_to(directory, "mcp")

      # Registered after the directory is already up, which is the whole point.
      :ok = Registry.put(resources, %{"name" => "mcp", "kind" => "project", "dir" => root})

      assert {:ok, _generation} = announce_to(directory, "mcp")
      assert {:error, :not_allowed} = announce_to(directory, "something-else")
    end

    test "a refusal explains itself in words" do
      assert Protocol.describe_refusal({:core_version, "0.2.0", "0.1.0"}) =~
               "built against eva_core 0.1.0"

      assert Protocol.describe_refusal(:not_allowed) =~ "allowlist"
    end
  end

  describe "leaving" do
    test "a member that dies is dropped" do
      pid = member_process()

      {:ok, _} =
        GenServer.call(Cluster, {:announce, Protocol.announcement(:extension, "fixture", pid)})

      assert [_member] = Cluster.members(:extension)

      Process.exit(pid, :kill)

      # The monitor fires asynchronously; the next call is ordered behind it.
      wait_until(fn -> Cluster.members(:extension) == [] end)
    end
  end

  describe "subscribers" do
    test "hear about members arriving and leaving" do
      :ok = Cluster.subscribe()
      pid = member_process()

      {:ok, _} =
        GenServer.call(Cluster, {:announce, Protocol.announcement(:extension, "fixture", pid)})

      assert_receive {:cluster_member_up, %{name: "fixture"}}

      Process.exit(pid, :kill)
      assert_receive {:cluster_member_down, %{name: "fixture"}}
    end

    test "subscribing twice does not double up" do
      :ok = Cluster.subscribe()
      :ok = Cluster.subscribe()

      {:ok, _} = announce("fixture")

      assert_receive {:cluster_member_up, _member}
      refute_receive {:cluster_member_up, _member}, 50
    end
  end

  describe "when Eva is not accepting members" do
    test "asking is answered, not an exit" do
      stop_supervised!(Eva.Cluster)

      assert Cluster.members(:extension) == []
      assert Cluster.fetch(:extension, "mcp") == :error
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
