defmodule Eva.Cluster.DiscoveryTest do
  @moduledoc """
  Finding this machine's extension nodes through epmd rather than a file they wrote down.

  There is no `evas/0` to test any more. Nothing looks for an Eva — Eva dials outward — so
  the only thing worth enumerating is what can be dialled.

  The interesting half needs a named VM, so it is `:distributed` — run `mix test.dist`.
  Finding a node that is genuinely running the node server is `cluster_node_test.exs`,
  which has a second VM to find.
  """

  use ExUnit.Case, async: false

  alias Eva.Cluster.Discovery
  alias Eva.Core.Cluster.Host

  # Not tagged `:distributed`, so this runs in the ordinary suite — where the VM is
  # `nonode@nohost`. A VM that is not a node cannot connect to one, and answering "nobody
  # is running" is better than raising at every caller.
  test "answers nothing when this VM is not distributed" do
    refute Node.alive?()
    assert Discovery.extension_nodes() == []
    assert Discovery.extension_node("mcp") == :error
  end

  describe "with a named VM" do
    @describetag :distributed

    test "an extension node that is not running is not found" do
      assert Discovery.extension_node("nothing-under-this-name") == :error
    end

    # The regression T1 would otherwise have introduced. epmd hands back a bare name and
    # the host has to be glued on; a node that made itself reachable is
    # `eva_ext_mcp@100.64.5.20` rather than `@127.0.0.1`, and guessing only loopback would
    # make it invisible to its own machine.
    test "candidates are built against every host this machine answers to" do
      hosts = Host.local_hosts()

      assert "127.0.0.1" in hosts
      assert hosts == Enum.uniq(hosts)

      case Host.source() do
        :loopback -> assert hosts == ["127.0.0.1"]
        _resolved -> assert Host.hostname() in hosts
      end
    end
  end
end
