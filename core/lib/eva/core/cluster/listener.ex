defmodule Eva.Core.Cluster.Listener do
  @moduledoc """
  Brings this VM up as a node, and decides where its distribution socket listens.

  Both halves start distribution themselves — Eva, and every extension node, which is its
  own VM — so the decision lives here once rather than in each of them.

  ## Name and socket are one decision

  A node name is `name@host`, and the host half is the address a dialer resolves. Erlang
  checks it during the handshake: dial `foo@A` and reach a node that calls itself `foo@B`
  and the connection is dropped. So a node cannot name itself for one address and listen on
  another, and there is no way to ask for that here — the caller says how reachable it wants
  to be, and gets the matching name.

      Listener.start(fn host -> :"eva_ext_mcp@\#{host}" end, :loopback)
      # => eva_ext_mcp@127.0.0.1

      Listener.start(fn host -> :"eva_ext_mcp@\#{host}" end, {:reachable, 9000})
      # => eva_ext_mcp@100.64.5.20

  ## Nothing listens on every interface by accident

  The default with a fixed port and no interface set is `*:9000` — every network the machine
  is attached to, unasked and unwarned, on a cookie-authenticated port that runs code. So
  `:inet_dist_use_interface` is always set, including for loopback, where it is the whole
  protection rather than a formality.

  Binding the listener does not restrict dialling out: `:inet_dist_use_interface` is read
  only when the listen socket is opened, and outgoing connections take a separate set of
  options that never look at it. A loopback-bound node still reaches a remote one.

  """

  require Logger

  alias Eva.Core.Cluster.{Cookie, Host}

  @typedoc """
  How reachable this node intends to be.

  * `:loopback` — nothing off this machine can reach it, and it is named `@127.0.0.1`
  * `{:reachable, port}` — bound to this machine's address at exactly this port, and named
    for that address
  """
  @type binding :: :loopback | {:reachable, :inet.port_number()}

  # Erlang's default, stated rather than inherited. Two members with different tick times
  # disconnect each other for no visible reason, and the only way everyone agrees is if
  # everyone is told. Both halves come through here, so they are.
  @net_ticktime 60

  @doc """
  Starts distribution, naming the node for the address it will listen on.

  `build_name` is given this machine's address and returns the node name.

  Already being distributed is success: the name is whatever it already was.
  """
  @spec start((String.t() -> node()), binding()) :: {:ok, node()} | {:error, term()}
  def start(build_name, binding) when is_function(build_name, 1) do
    if Node.alive?() do
      warn_not_ours()
      apply_cookie()

      # tick interval(health check between nodes done implicitly by BEAM). Must match for every node otherwise they are declared dead.
      :net_kernel.set_net_ticktime(@net_ticktime)

      {:ok, node()}
    else
      with {:ok, host, address} <- resolve(binding) do
        configure(address, binding)
        boot(build_name.(host), host, binding)
      end
    end
  end

  @doc """
  Takes distribution down, so `start/2` can bring it back under a different name.

  A node name cannot be edited; this is the only way it changes. Everything local survives
  — processes keep their pids — but from outside it is a death and an unrelated arrival:
  every connection drops, every monitor across one fires `:noconnection`, and a pid a peer
  was holding still points at the old name and silently swallows sends.

  Returns `{:error, :not_allowed}` when the VM was named by `-name`/`-sname` on the command
  line.
  """
  @spec stop() :: :ok | {:error, term()}
  def stop, do: :net_kernel.stop()

  # -- Private --

  # Already distributed means the socket was opened before we got here — by `--name` on the
  # command line, or by something else in this VM — and where it listens was decided by
  # whoever did that. With no interface pinned the default is every interface the machine
  # has, so this is worth saying rather than letting the caller assume the binding above
  # applied. Once per VM, since more than one caller may pass through here.
  defp warn_not_ours do
    if :persistent_term.get({__MODULE__, :warned}, false) do
      :ok
    else
      :persistent_term.put({__MODULE__, :warned}, true)

      Logger.warning(
        "distribution was already up as #{node()}; its listener was not bound by us, " <>
          "and an unbound one accepts connections on every interface"
      )
    end
  end

  defp resolve(:loopback), do: {:ok, Host.loopback(), {127, 0, 0, 1}}

  defp resolve({:reachable, _port}) do
    case Host.current() do
      # Asking to be reachable on a machine with no address to be reachable at.
      {_host, :loopback} ->
        {:error, :no_reachable_address}

      {host, _source} ->
        case Host.ip(host) do
          {:ok, address} -> {:ok, host, address}
          {:error, reason} -> {:error, {:unresolvable_host, host, reason}}
        end
    end
  end

  defp configure(address, binding) do
    # Binds the "listener" to given address only, otherwise it listens on every interface.
    Application.put_env(:kernel, :inet_dist_use_interface, address)

    # tick interval(health check between nodes done implicitly by BEAM). Must match for every node otherwise they are declared dead.
    Application.put_env(:kernel, :net_ticktime, @net_ticktime)

    case binding do
      {:reachable, port} ->
        # Pins the listener port to exactly one port
        Application.put_env(:kernel, :inet_dist_listen_min, port)
        Application.put_env(:kernel, :inet_dist_listen_max, port)

      :loopback ->
        # Local only, specific port not needed
        Application.delete_env(:kernel, :inet_dist_listen_min)
        Application.delete_env(:kernel, :inet_dist_listen_max)
    end
  end

  # Long names throughout: a long-named VM cannot talk to a short-named one.
  defp boot(name, host, binding) do
    case :net_kernel.start(name, %{name_domain: :longnames}) do
      {:ok, _pid} ->
        apply_cookie()
        log_info(host, binding)
        {:ok, node()}

      {:error, {:already_started, _pid}} ->
        {:ok, node()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # After distribution, never before: setting a cookie needs a VM that is already a node.
  defp apply_cookie do
    with {:error, reason} <- Cookie.apply() do
      Logger.error("could not set the cluster cookie: #{inspect(reason)}")
    end
  end

  defp log_info(host, binding) do
    where =
      case binding do
        :loopback -> "loopback"
        {:reachable, port} -> "#{host}:#{port}"
      end

    Logger.info(
      "distribution up as #{node()}, listening on #{where} (host from #{Host.source()})"
    )
  end
end
