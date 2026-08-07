defmodule Eva.Cluster.Discovery do
  @moduledoc """
  Finding the other Eva VMs on this machine, with nobody writing down where they are.

  epmd already keeps this list. Every distributed VM registers with it as a condition of
  being distributed at all, and **the registration dies with the VM**.

  ## A name is a candidate, not proof

  Anything may call itself `eva_something`. A candidate is therefore connected to and asked
  whether the process that matters is registered there — the directory for an Eva, the node
  server for an extension. The prefix only keeps this from dialling every VM on the box.

  ## Scope

  One machine. Both node names are built with `127.0.0.1` and epmd answers for one host at
  a time, so reaching another machine is not supported yet.
  """

  alias Eva.Cluster.Protocol

  # Matches the host in the node names `Eva.Cluster.Distribution` and `Eva.Extension.Node`
  # generate. Change one, change all three.
  @host ~c"127.0.0.1"

  @eva_prefix "eva_"
  @extension_prefix "eva_ext_"

  # Generous for a local call that only does a `whereis`, but it is the first thing said to
  # a VM we have just met, and one that is still booting deserves a moment.
  @timeout 5_000

  @doc """
  Every Eva currently running, including this VM if it is one.

  An Eva is a node that answers to `Eva.Cluster` — a session host that has distribution
  switched on. Extension nodes share the `eva_` prefix and are excluded by name before
  anything is dialled.
  """
  @spec evas() :: [node()]
  def evas do
    discover(
      &(String.starts_with?(&1, @eva_prefix) and not String.starts_with?(&1, @extension_prefix)),
      Protocol.directory()
    )
  end

  @doc """
  Every extension node currently running, whether or not it has found an Eva to join.

  That distinction is the point: a node that is up but attached to nothing looks exactly
  like a node that never started, and only one of those is a problem you can act on. Ask
  `Eva.Extension.Node.status/0` on the result to tell them apart.
  """
  @spec extension_nodes() :: [node()]
  def extension_nodes do
    discover(&String.starts_with?(&1, @extension_prefix), Eva.Extension.Node)
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
    :erpc.call(node, Eva.Extension.Node, :status, [], @timeout)
  catch
    # Gone between being listed and being asked, or too old to answer.
    _kind, _reason -> nil
  end

  # -- Private --

  defp discover(match?, registered) do
    for {name, _port} <- names(),
        name = List.to_string(name),
        match?.(name),
        node = :"#{name}@#{@host}",
        registered?(node, registered),
        do: node
  end

  defp names do
    case :erl_epmd.names(@host) do
      {:ok, names} -> names
      # No epmd means no distribution at all, which reads the same as nobody being up.
      _other -> []
    end
  end

  # Connect then ask
  defp registered?(node, registered) do
    Node.alive?() and Node.connect(node) == true and
      :erpc.call(node, :erlang, :whereis, [registered], @timeout) != :undefined
  catch
    _kind, _reason -> false
  end
end
