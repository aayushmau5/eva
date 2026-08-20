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

  The name is prefixed `eva_ext_` by default, because that is how Eva finds extension nodes
  through epmd. Pass `extension_name?: false` for a peer that must only be found through
  Eva's already-connected-node scan, like a phone that dialled the host first.

  Requires the test VM to be distributed — run with `mix test.dist`.
  """
  @spec start(atom(), keyword()) :: {:ok, %{peer: pid(), node: node()}} | {:error, term()}
  def start(name, opts \\ []) do
    if Node.alive?() do
      kernel = [~c"-kernel", ~c"prevent_overlapping_partitions", ~c"false"]
      paths = kernel ++ Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
      name = if Keyword.get(opts, :extension_name?, true), do: :"eva_ext_#{name}", else: name

      {:ok, peer, node} =
        :peer.start_link(%{
          name: name,
          host: ~c"127.0.0.1",
          longnames: true,
          connection: :standard_io,
          args: paths
        })

      :peer.call(peer, :erlang, :set_cookie, [:erlang.get_cookie()])
      cookie_path = Application.fetch_env!(:eva_core, :cookie_path)
      :peer.call(peer, Application, :put_env, [:eva_core, :cookie_path, cookie_path])
      true = Node.connect(node)

      {:ok, %{peer: peer, node: node}}
    else
      {:error, :not_distributed}
    end
  end

  @doc """
  Starts `eva_core` on the node and puts an extension up to be served from it.

  This is what an extension's own application does in production; here it is done by hand
  so a test can choose the module and the moment.

  The node tells nobody it exists — that is the inversion. So this scans on Eva's behalf
  and returns once the result has been applied, which spares every test a two-second wait
  for the next tick and keeps them free of `wait_until` around joining.
  """
  @spec serve(map(), String.t(), module(), keyword()) :: {:ok, pid()} | {:error, term()}
  def serve(%{peer: peer}, name, module, opts \\ []) do
    {:ok, _apps} = :peer.call(peer, Application, :ensure_all_started, [:eva_core])

    node_opts = Keyword.merge([name: name, module: module], opts)

    result = :peer.call(peer, Eva.Core.Extension.Node, :start_link, [node_opts])

    if Eva.Cluster.running?(), do: :ok = Eva.Cluster.scan_now()

    result
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
