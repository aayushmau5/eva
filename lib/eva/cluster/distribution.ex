defmodule Eva.Cluster.Distribution do
  @moduledoc """
  Brings Eva up as a node.

  **Off unless asked for.** Distribution opens a listening socket, and a user with no node
  extensions should never have one. Can be configured with setting:

      config :eva, distribution: true

  ## Loopback, always

  Eva's listener is bound to `127.0.0.1` and it is named for that. Nothing on any network
  can reach it, good for machine running sessions.

  The socket exists anyway because a node without one has its connections marked *hidden*,
  and hidden nodes are excluded from cluster-wide services — `:pg` among them, which
  `Eva.Core.Bus` runs on. So the listener is not a service being protected; it is a socket
  nobody uses, put somewhere nobody can reach.
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
    if Keyword.get(opts, :enabled?, enabled?()) do
      start_node(opts)
    else
      :disabled
    end
  end

  @doc """
  Whether distribution is switched on.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:eva, :distribution, false)

  # -- Private --

  defp start_node(opts) do
    case Listener.start(name_builder(opts), :loopback) do
      {:ok, node} ->
        {:ok, node}

      {:error, reason} ->
        Logger.error("could not start distribution: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp name_builder(opts) do
    case Keyword.get(opts, :node_name) do
      nil -> &node_name/1
      name when is_atom(name) -> fn _host -> name end
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
