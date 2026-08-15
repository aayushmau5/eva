defmodule Eva.Core.Cluster.Epmdless do
  @moduledoc """
  An epmd client that registers with nothing, for a node reached by an address someone
  already wrote down.

  `:net_kernel.start/2` fails outright when registration fails, so a machine with no epmd
  running cannot bring distribution up at all — even when nothing will ever look this node
  up by name. Remote extensions are exactly that case: the registry entry carries the host
  and port, and `Eva.Cluster.Epmd` resolves from it without asking any daemon.

  The cost is that the node is absent from `epmd -names`, so an Eva on this machine cannot
  discover it. Opt in per node with `epmd: false`, never by default.

  Only registration is stubbed; resolution still goes to `:erl_epmd`.
  """

  @doc """
  `net_sup` supervises the epmd module. `:erl_epmd` is a gen_server because it owns the
  socket to the daemon; there is no socket here.
  """
  @spec start_link() :: :ignore
  def start_link, do: :ignore

  @doc """
  Claims the name without telling anyone.

  The creation number separates one incarnation of a node from the next. epmd hands these
  out; with no epmd, the classic range is picked at random.
  """
  @spec register_node(atom() | charlist(), :inet.port_number()) :: {:ok, pos_integer()}
  def register_node(name, port), do: register_node(name, port, :inet)

  @spec register_node(atom() | charlist(), :inet.port_number(), :inet | :inet6) ::
          {:ok, pos_integer()}
  def register_node(_name, _port, _family), do: {:ok, :rand.uniform(3)}

  @doc false
  def address_please(name, host, family), do: :erl_epmd.address_please(name, host, family)

  @doc false
  def port_please(name, host), do: :erl_epmd.port_please(name, host)

  @doc false
  def names(host), do: :erl_epmd.names(host)
end
