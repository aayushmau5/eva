defmodule Eva.Cluster.EpmdTest do
  @moduledoc """
  Answering "where does that node live" from the registry instead of from epmd.

  A real dial across the mechanism is `mcp_node_test.exs`; what is here is the lookup
  itself and the fallback that keeps local nodes working.
  """

  use ExUnit.Case, async: false

  alias Eva.Cluster.Epmd
  alias Eva.Coding.Resources
  alias Eva.Extension.Registry

  setup do
    root = Path.join(System.tmp_dir!(), "epmd_#{System.unique_integer([:positive])}")
    routes = :persistent_term.get({Epmd, :routes}, nil)

    on_exit(fn ->
      File.rm_rf!(root)
      if routes, do: Epmd.put(routes), else: :persistent_term.erase({Epmd, :routes})
    end)

    %{resources: %Resources{root: root}}
  end

  describe "routes_from/1" do
    test "one route per remote entry, keyed by the name epmd would use", %{resources: r} do
      :ok =
        Registry.put(r, %{
          "name" => "gpu",
          "kind" => "remote",
          "host" => "100.64.5.20",
          "port" => 9001
        })

      :ok =
        Registry.put(r, %{"name" => "mcp", "kind" => "project", "dir" => "/tmp", "start" => []})

      # `eva_ext_` is on the front because that is what the other machine's node registered
      # itself as, and the name has to be derivable from the entry alone.
      assert Epmd.routes_from(r) == %{{"eva_ext_gpu", "100.64.5.20"} => 9001}
    end

    test "a registry with nothing remote in it implies no routes", %{resources: r} do
      :ok =
        Registry.put(r, %{"name" => "mcp", "kind" => "project", "dir" => "/tmp", "start" => []})

      assert Epmd.routes_from(r) == %{}
    end
  end

  describe "address_please/3" do
    test "answers a configured node without asking anyone" do
      Epmd.put(%{{"eva_ext_gpu", "127.0.0.1"} => 9001})

      assert {:ok, {127, 0, 0, 1}, 9001, version} =
               Epmd.address_please(~c"eva_ext_gpu", ~c"127.0.0.1", :inet)

      # 6 since OTP 23. A configured node has no epmd to tell us, so we state it.
      assert version == 6
    end

    test "falls through for anything not configured, so local nodes are untouched" do
      Epmd.put(%{})

      # `erl_epmd`'s own answer is the address and nothing else — no port, because it
      # expects `port_please` to be asked next.
      assert Epmd.address_please(~c"whatever", ~c"127.0.0.1", :inet) == {:ok, {127, 0, 0, 1}}
    end

    test "a configured name on a different host is not a match" do
      Epmd.put(%{{"eva_ext_gpu", "100.64.5.20"} => 9001})

      assert Epmd.address_please(~c"eva_ext_gpu", ~c"127.0.0.1", :inet) == {:ok, {127, 0, 0, 1}}
    end

    test "hosts arrive in more than one shape" do
      Epmd.put(%{{"eva_ext_gpu", "127.0.0.1"} => 9001})

      # Erlang hands over charlists, and a host may already be resolved to a tuple.
      assert {:ok, _ip, 9001, _v} = Epmd.address_please(~c"eva_ext_gpu", ~c"127.0.0.1", :inet)
      assert {:ok, _ip, 9001, _v} = Epmd.address_please(~c"eva_ext_gpu", {127, 0, 0, 1}, :inet)
    end
  end

  describe "install/1" do
    # The bug this replaced: only `Eva.Cluster` installed the routes, so `mix eva.ext.list`
    # asking a registered remote extension how it was doing fell back to `erl_epmd` and
    # tried to reach an epmd on the *other* machine — which is deliberately not exposed. A
    # perfectly healthy remote read as unreachable.
    test "is what the Mix tasks depend on too, not only the directory", %{resources: r} do
      :ok =
        Registry.put(r, %{
          "name" => "gpu",
          "kind" => "remote",
          "host" => "10.0.0.9",
          "port" => 9001
        })

      :ok = Epmd.install(r)

      assert Epmd.address_please(~c"eva_ext_gpu", ~c"10.0.0.9", :inet) ==
               {:ok, {10, 0, 0, 9}, 9001, 6}
    end

    test "loads the module before naming it, which OTP requires", %{resources: r} do
      :ok =
        Registry.put(r, %{
          "name" => "gpu",
          "kind" => "remote",
          "host" => "10.0.0.9",
          "port" => 9001
        })

      :ok = Epmd.install(r)

      assert Application.get_env(:kernel, :epmd_module) == Epmd
      assert Epmd.routes() == %{{"eva_ext_gpu", "10.0.0.9"} => 9001}

      # The trap this guards: OTP checks `function_exported/3` before calling us, and that
      # is false for a module that is only *loadable*. It then falls back to `erl_epmd`
      # without a word, and the dial quietly goes to the wrong port.
      assert :erlang.function_exported(Epmd, :address_please, 3)
    end

    test "re-reads the registry, so editing it on a running Eva takes effect", %{resources: r} do
      :ok = Epmd.install(r)
      assert Epmd.routes() == %{}

      :ok =
        Registry.put(r, %{
          "name" => "gpu",
          "kind" => "remote",
          "host" => "10.0.0.9",
          "port" => 9001
        })

      :ok = Epmd.install(r)

      assert Epmd.routes() == %{{"eva_ext_gpu", "10.0.0.9"} => 9001}
    end
  end
end
