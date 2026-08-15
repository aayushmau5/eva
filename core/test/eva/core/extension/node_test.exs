defmodule Eva.Core.Extension.NodeTest do
  @moduledoc """
  The naming a node gives itself when it brings up distribution on its own.

  Announcing is exercised for real by Eva's `mix test.dist`; what is here is the part
  that decides whether a second node can start at all, and whether another machine can
  work out the name without asking.
  """

  use ExUnit.Case, async: true

  alias Eva.Core.Extension.Node, as: ExtensionNode

  describe "node_name/2" do
    test "is the name and the host, and nothing else" do
      assert ExtensionNode.node_name("mcp", "127.0.0.1") == :"eva_ext_mcp@127.0.0.1"
      assert ExtensionNode.node_name("mcp", "100.64.5.20") == :"eva_ext_mcp@100.64.5.20"
    end

    test "carries no OS pid, so a remote Eva can derive it from config alone" do
      # It used to. The pid made the name unguessable from another machine, which is the
      # one thing a configured entry has to be able to do — and it was never doing
      # uniqueness work, since `refuse_if_running` already allows one node per name per
      # machine.
      name = ExtensionNode.node_name("mcp", "127.0.0.1") |> Atom.to_string()

      refute name =~ System.pid()
      assert name == "eva_ext_mcp@127.0.0.1"
    end

    test "distinguishes extensions running on the same machine" do
      assert ExtensionNode.node_name("mcp", "127.0.0.1") !=
               ExtensionNode.node_name("worklog", "127.0.0.1")
    end

    test "distinguishes the same extension on two machines" do
      assert ExtensionNode.node_name("mcp", "100.64.5.20") !=
               ExtensionNode.node_name("mcp", "100.64.5.21")
    end

    # These two have to agree or extensions stop being found, with nothing to say why —
    # which is the whole reason the prefix lives here rather than in Eva's scanner.
    test "matches node_name?/1, which is what Eva scans epmd with" do
      assert ExtensionNode.node_name("mcp", "127.0.0.1")
             |> Atom.to_string()
             |> String.split("@")
             |> hd()
             |> ExtensionNode.node_name?()

      refute ExtensionNode.node_name?("eva_4711")
      refute ExtensionNode.node_name?("evacli_4711")
      refute ExtensionNode.node_name?("something_else")
    end

    test "is a long name, because a long-named VM cannot talk to a short-named one" do
      assert ExtensionNode.node_name("mcp", "127.0.0.1")
             |> Atom.to_string()
             |> String.contains?("@")
    end
  end
end
