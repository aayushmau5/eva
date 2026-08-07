defmodule Eva.Cluster.DiscoveryTest do
  @moduledoc """
  Finding Evas through epmd rather than a file they wrote down.

  The interesting half needs a named VM, so it is `:distributed` — run `mix test.dist`.
  """

  use ExUnit.Case, async: false

  alias Eva.Cluster.Discovery

  # Not tagged `:distributed`, so this runs in the ordinary suite — where the VM is
  # `nonode@nohost`. A VM that is not a node cannot connect to one, and answering "nobody
  # is running" is better than raising at every caller.
  test "answers nothing when this VM is not distributed" do
    refute Node.alive?()
    assert Discovery.evas() == []
    assert Discovery.extension_nodes() == []
    assert Discovery.extension_node("mcp") == :error
  end

  describe "with a named VM" do
    @describetag :distributed

    # The name is a candidate; the directory is the proof. `mix test.dist` names this VM
    # `eva_test@127.0.0.1`, which matches the prefix — and it must still not count as an
    # Eva until something is actually listening.
    test "a node matching the prefix is not an Eva without a directory" do
      refute Process.whereis(Eva.Cluster)
      refute node() in Discovery.evas()
    end

    test "a node running the directory is found" do
      start_supervised!({Eva.Cluster, allow: nil})

      assert node() in Discovery.evas()
    end

    # Extension nodes share the `eva_` prefix, and an Eva sweeping for other Evas must not
    # try to instantiate sessions on one.
    test "extension nodes are not mistaken for Evas" do
      start_supervised!({Eva.Cluster, allow: nil})

      refute Enum.any?(Discovery.evas(), &String.starts_with?(Atom.to_string(&1), "eva_ext_"))
    end

    test "an extension node that is not running is not found" do
      assert Discovery.extension_node("nothing-under-this-name") == :error
    end
  end
end
