defmodule Eva.Test.ClusterNode do
  @moduledoc """
  Starts a real second BEAM node for tests, standing in for an extension someone ran.

  Production does not spawn nodes — that is the whole point of the design — but a *test*
  has to get one from somewhere, and `:peer` is the right tool for that. The incantation
  is fussier than it looks, so it lives here once:

    * args must be **charlists**; strings are rejected by `verify_args`
    * the peer needs the parent's code paths or it has no Elixir on it at all
    * long and short node names cannot connect to each other
    * the cookie has to be set before the first connection, which means a `:standard_io`
      control channel, then `set_cookie`, then `Node.connect/1`
  """

  @doc """
  Boots a node with this VM's code paths and connects it.

  Requires the test VM to be distributed — run with `mix test.dist`.
  """
  @spec start(atom()) :: {:ok, %{peer: pid(), node: node()}} | {:error, term()}
  def start(name) do
    if Node.alive?() do
      paths = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])

      {:ok, peer, node} =
        :peer.start_link(%{
          name: name,
          host: ~c"127.0.0.1",
          longnames: true,
          connection: :standard_io,
          args: paths
        })

      :peer.call(peer, :erlang, :set_cookie, [:erlang.get_cookie()])
      true = Node.connect(node)

      {:ok, %{peer: peer, node: node}}
    else
      {:error, :not_distributed}
    end
  end

  @doc """
  Starts `eva_core` on the node and announces an extension from it.

  This is what an extension's own application does in production; here it is done by hand
  so a test can choose the module and the moment.
  """
  @spec announce(map(), String.t(), module()) :: {:ok, pid()} | {:error, term()}
  def announce(%{peer: peer}, name, module) do
    {:ok, _apps} = :peer.call(peer, Application, :ensure_all_started, [:eva_core])

    :peer.call(peer, Eva.Extension.Node, :start_link, [
      [name: name, module: module, eva_node: node()]
    ])
  end

  @doc "Runs a function on the node."
  @spec call(map(), module(), atom(), [term()]) :: term()
  def call(%{peer: peer}, module, function, args), do: :peer.call(peer, module, function, args)

  @doc "Stops the node, as an extension exiting or being killed."
  @spec stop(map()) :: :ok
  def stop(%{peer: peer}) do
    :peer.stop(peer)
  catch
    :exit, _reason -> :ok
  end
end
