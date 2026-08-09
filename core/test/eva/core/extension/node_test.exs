defmodule Eva.Core.Extension.NodeTest do
  @moduledoc """
  The naming a node gives itself when it brings up distribution on its own.

  Announcing is exercised for real by Eva's `mix test.dist`; what is here is the part
  that decides whether a second node can start at all.
  """

  use ExUnit.Case, async: true

  alias Eva.Core.Extension.Node, as: ExtensionNode

  describe "node_name/1" do
    test "is stable within one OS process" do
      assert ExtensionNode.node_name("mcp") == ExtensionNode.node_name("mcp")
    end

    test "is the OS pid, so two VMs never pick the same name" do
      assert ExtensionNode.node_name("mcp") == :"eva_ext_mcp_#{System.pid()}@127.0.0.1"
    end

    test "is not a per-VM counter, which restarts low in a fresh VM and collides" do
      # The bug this replaced: `:erlang.unique_integer([:positive])` counts from near
      # zero in every new VM, so restarting a node while the old one still held the name
      # picked the same one again — and the collision was swallowed.
      refute ExtensionNode.node_name("mcp") == :"eva_ext_mcp_1@127.0.0.1"
      refute ExtensionNode.node_name("mcp") == :"eva_ext_mcp_2@127.0.0.1"
    end

    test "distinguishes extensions running in the same process space" do
      assert ExtensionNode.node_name("mcp") != ExtensionNode.node_name("worklog")
    end

    test "is a long name, because a long-named VM cannot talk to a short-named one" do
      assert ExtensionNode.node_name("mcp") |> Atom.to_string() |> String.contains?("@127.0.0.1")
    end
  end
end
