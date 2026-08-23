defmodule Eva.Cluster.Distribution do
  @moduledoc """
  Brings Eva up as a node.

  **Off unless asked for.** Distribution opens a listening socket, and a user with no node
  extensions should never have one. Can be configured with setting:

      config :eva, distribution: true

  ## Loopback unless explicitly offered

  Eva's listener is bound to `127.0.0.1` and named for that by default. Nothing on another
  machine can reach it, which is right when Eva discovers and dials every extension itself.

  The loopback socket still matters even when Eva makes every connection. A node without a
  listener has its outgoing connections marked *hidden*, and hidden nodes are excluded from
  cluster-wide services — `:pg` among them, which `Eva.Core.Bus` runs on.

  A member that must initiate its own connection, such as a mobile extension, changes that trust
  boundary: Eva now intentionally accepts an inbound BEAM connection from the tailnet. Giving
  `:distribution` a port opts into a listener bound specifically to Eva's configured or detected
  tailnet address. A reachable Eva has the stable name `eva@<address>` so a caller that was given
  the address and port can derive its node identity without asking epmd. The connected node then
  appears in Eva's normal cluster scan and goes through the same description, allowlist, consent
  and attach flow as a node Eva dialled. Configure the instance at launch rather than assigning a
  port to every Eva in source:

      EVA_DISTRIBUTION_PORT=9001 iex -S mix

  Two reachable Evas on one machine need distinct ports and names. `EVA_DISTRIBUTION_NAME`
  changes the part before `@<address>` for that process:

      EVA_DISTRIBUTION_PORT=9002 EVA_DISTRIBUTION_NAME=eva_secondary iex -S mix

  With no non-loopback address, startup fails instead of silently exposing another interface.
  """

  require Logger

  alias Eva.Core.Cluster.{Host, Listener}

  @doc """
  Starts distribution, if configured to.

  Returns `{:ok, node}` when Eva is joinable, `:disabled` when it is not meant to be, and
  `{:error, reason}` when it was meant to be and could not.
  """
  @spec ensure_started(keyword()) :: {:ok, node()} | :disabled | {:error, term()}
  def ensure_started(opts \\ []) do
    opts = Keyword.merge(configured_options(), opts)

    if Keyword.get(opts, :enabled?, enabled?()) do
      check_vm_flags()
      start_node(opts)
    else
      :disabled
    end
  end

  @doc """
  Warns if this VM will tear down its own extension connections.

  Not an error: one extension works fine without the flag, and refusing to start would
  be worse than a degraded cluster. But the symptom — extensions joining and leaving on
  a loop — looks like a network problem or a broken extension, and costs an hour to
  trace back to a VM flag. So it is said once, plainly, at the point it starts to matter.
  """
  @spec check_vm_flags() :: :ok
  def check_vm_flags do
    unless :application.get_env(:kernel, :prevent_overlapping_partitions) == {:ok, false} do
      Logger.warning("""
      extensions on more than one node will disconnect and reconnect on a loop.

      `global` treats Eva's hub-and-spoke topology as a healed partition. Start Eva with
      `bin/eva`, which sets the flags, or set this yourself:

          ERL_FLAGS="-kernel prevent_overlapping_partitions false"

      It must be a boot flag — `global` reads it once, when the kernel starts, so config
      and `Application.put_env/3` are both too late.
      """)
    end

    :ok
  end

  @doc """
  Whether distribution is switched on.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    case Application.get_env(:eva, :distribution, false) do
      true -> true
      opts when is_list(opts) -> Keyword.get(opts, :enabled?, true)
      _other -> false
    end
  end

  @doc false
  @spec listener_binding(keyword()) :: Eva.Core.Cluster.Listener.binding()
  def listener_binding(opts) do
    case Keyword.get(opts, :port) do
      nil ->
        :loopback

      port when is_integer(port) and port in 1..65_535 ->
        {:reachable, port}

      port ->
        raise ArgumentError,
              "distribution port must be an integer from 1 to 65535, got: #{inspect(port)}"
    end
  end

  # -- Private --

  defp start_node(opts) do
    binding = listener_binding(opts)

    case Listener.start(name_builder(opts, binding), binding) do
      {:ok, node} ->
        {:ok, node}

      {:error, reason} ->
        Logger.error("could not start distribution: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp configured_options do
    case Application.get_env(:eva, :distribution, false) do
      opts when is_list(opts) -> opts
      _other -> []
    end
  end

  defp name_builder(opts, binding) do
    case Keyword.get(opts, :node_name) do
      nil -> default_name_builder(binding, opts)
      name when is_atom(name) -> fn _host -> name end
    end
  end

  defp default_name_builder(:loopback, _opts), do: &node_name/1

  defp default_name_builder({:reachable, _port}, opts) do
    name = Keyword.get(opts, :name, "eva")
    &reachable_node_name(&1, name)
  end

  @doc """
  The stable name used by an Eva that accepts connections at a configured address.

  A reachable Eva is addressed as a service rather than discovered as a local process. Keeping
  the name stable lets a mobile extension derive it from the address it was configured with. A
  host running more than one reachable Eva can give each instance a distinct `:name` alongside
  its port.
  """
  @spec reachable_node_name(String.t(), String.t()) :: node()
  def reachable_node_name(host, name \\ "eva")

  def reachable_node_name(host, name) when is_binary(name) do
    if Regex.match?(~r/^[a-zA-Z0-9_-]+$/, name) do
      String.to_atom("#{name}@#{host}")
    else
      raise ArgumentError,
            "distribution name may contain only letters, numbers, underscores and hyphens, " <>
              "got: #{inspect(name)}"
    end
  end

  @doc """
  The name Eva takes: `eva_<os pid>[_<machine>]@<host>`.

  The machine is added because node names must be unique across the whole cluster, and two
  Evas on two machines can have same process id. Nothing is added when hostnames aren't configured or detected(tailnet).
  """
  @spec node_name(String.t()) :: node()
  def node_name(host) do
    :"eva_#{System.pid()}#{machine()}@#{host}"
  end

  defp machine do
    loopback = Host.loopback()

    case Host.hostname() do
      # No remote machine reference. Only concerned with this machine.
      ^loopback -> ""
      # Converts non-letter/non-digit to _
      address -> "_" <> String.replace(address, ~r/[^a-zA-Z0-9]+/, "_")
    end
  end
end
