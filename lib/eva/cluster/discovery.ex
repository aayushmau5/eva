defmodule Eva.Cluster.Discovery do
  @moduledoc """
  Finding the extension nodes running on this machine.

  epmd already keeps the list: every distributed VM registers with it, and the registration
  dies with the VM. So there is nothing to write down and nothing to keep in step.

  Eva's, not `eva_core`'s. An extension node never looks for anything — Eva dials — so this
  only ever runs here and in the Mix tasks.

  ## A name is a candidate, not proof

  Anything may call itself `eva_ext_something`. So a candidate is connected to and asked
  whether `Eva.Core.Extension.Node` is actually registered there. The prefix only keeps us
  from dialling every VM on the machine.

  ## epmd gives short names

  What comes back is `eva_ext_mcp`, not a node name, so the host has to be added. A node is
  named for where it listens, so a reachable one is `eva_ext_mcp@100.64.5.20` while its
  loopback neighbour is `eva_ext_mcp@127.0.0.1`. Both are tried.

  ## One machine

  This one. Nodes elsewhere are named in config and dialled directly, which is a different
  path — epmd is only ever asked about ourselves, over loopback.
  """

  alias Eva.Core.Cluster.Host
  alias Eva.Core.Extension.Node, as: ExtensionNode

  # Our own epmd, over loopback.
  @epmd_host ~c"127.0.0.1"

  # Only a `whereis`, but it is the first thing said to a VM that may still be booting.
  @timeout 5_000

  @doc """
  Every extension node running, whether or not an Eva has taken it on.
  """
  @spec extension_nodes() :: [node()]
  def extension_nodes do
    hosts = Host.local_hosts()

    for {name, _port} <- names(),
        name = List.to_string(name),
        ExtensionNode.node_name?(name),
        node = resolve(name, hosts),
        not is_nil(node),
        do: node
  end

  @doc """
  The extension node running `name`, if one is.

  Matched by asking each node what it is called rather than by reading its node name.
  """
  @spec extension_node(String.t()) :: {:ok, node()} | :error
  def extension_node(name) when is_binary(name) do
    Enum.reduce_while(extension_nodes(), :error, fn node, :error ->
      case status(node) do
        %{name: ^name} -> {:halt, {:ok, node}}
        _other -> {:cont, :error}
      end
    end)
  end

  @doc """
  What an extension node says about itself, or `nil` if it cannot be asked.
  """
  @spec status(node()) :: map() | nil
  def status(node) do
    :erpc.call(node, ExtensionNode, :status, [], @timeout)
  catch
    # Gone between being listed and being asked, or too old to answer.
    _kind, _reason -> nil
  end

  # -- Private --

  # Loopback first, since that is what almost everything is. A wrong guess costs one failed
  # connection and nothing else.
  defp resolve(name, hosts) do
    Enum.find_value(hosts, fn host ->
      node = :"#{name}@#{host}"
      if registered?(node), do: node
    end)
  end

  defp names do
    case :erl_epmd.names(@epmd_host) do
      {:ok, names} -> names
      # No epmd means no distribution at all.
      _other -> []
    end
  end

  # Connect, then ask.
  defp registered?(node) do
    Node.alive?() and Node.connect(node) == true and
      :erpc.call(node, :erlang, :whereis, [ExtensionNode], @timeout) != :undefined
  catch
    _kind, _reason -> false
  end
end
