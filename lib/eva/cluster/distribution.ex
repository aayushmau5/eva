defmodule Eva.Cluster.Distribution do
  @moduledoc """
  Brings Eva up as a node other things can join.

  **Off unless asked for.** Distribution opens a listening socket, and a user with no node
  extensions should never have one. Can be configured with setting:

      config :eva, distribution: true

  Starting distribution registers this VM with epmd, and that registration is what joiners read — see `Eva.Core.Cluster.Discovery`.

  ## Trust

  The cookie is the boundary, and it is Erlang's own: `~/.erlang.cookie`, shared because
  both processes run as the same user.
  """

  require Logger

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
    if Node.alive?() do
      {:ok, node()}
    else
      name = Keyword.get(opts, :node_name, default_node_name())

      case :net_kernel.start(name, %{name_domain: :longnames}) do
        {:ok, _pid} ->
          {:ok, node()}

        {:error, {:already_started, _pid}} ->
          {:ok, node()}

        {:error, reason} ->
          Logger.error("could not start distribution: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  # The OS pid rather than a counter, so `epmd -names` can be read against `ps` — which is
  # most of what you want from it when two Evas are up and one of them is misbehaving. It
  # is unique for the same reason: one node per OS process.
  #
  # Long names throughout: a long-named VM cannot talk to a short-named one, and the
  # failure is a bare `:noconnection` with nothing to say why.
  defp default_node_name do
    :"eva_#{System.pid()}@127.0.0.1"
  end
end
