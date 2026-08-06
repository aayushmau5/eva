defmodule Eva.Cluster.Distribution do
  @moduledoc """
  Brings Eva up as a node other things can join, and tells them where to find it.

  **Off unless asked for.** Distribution opens a listening socket, and a user with no node
  extensions should never have one. Can be configured with setting:

      config :eva, distribution: true

  ## Trust

  The cookie is the boundary, and it is Erlang's own: `~/.erlang.cookie`, shared because
  both processes run as the same user.
  """

  require Logger

  @discovery_file "node"

  @doc """
  Starts distribution and publishes where we are, if configured to.

  Returns `{:ok, node}` when Eva is joinable, `:disabled` when it is not meant to be, and
  `{:error, reason}` when it was meant to be and could not.
  """
  @spec ensure_started(keyword()) :: {:ok, node()} | :disabled | {:error, term()}
  def ensure_started(opts \\ []) do
    if Keyword.get(opts, :enabled?, enabled?()) do
      with {:ok, node} <- start_node(opts),
           :ok <- publish(node, opts) do
        {:ok, node}
      end
    else
      :disabled
    end
  end

  @doc """
  Removes the discovery file. A node name left behind points at a VM that is gone.
  """
  @spec stop(keyword()) :: :ok
  def stop(opts \\ []) do
    _ = File.rm(discovery_path(opts))
    :ok
  end

  @doc """
  Whether distribution is switched on.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:eva, :distribution, false)

  @doc """
  Where the node name is published for joiners to read.

  A sibling of `trust.json` and `extensions.json`.
  """
  @spec discovery_path(keyword()) :: String.t()
  def discovery_path(opts \\ []) do
    Keyword.get_lazy(opts, :discovery_path, fn ->
      root = Keyword.get_lazy(opts, :root, fn -> %Eva.Coding.Resources{}.root end)
      Path.join(root, @discovery_file)
    end)
  end

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

  # Long names throughout: a long-named VM cannot talk to a short-named one, and the
  # failure is a bare `:noconnection` with nothing to say why.
  defp default_node_name do
    :"eva_#{:erlang.unique_integer([:positive])}@127.0.0.1"
  end

  defp publish(node, opts) do
    path = discovery_path(opts)
    contents = JSON.encode!(%{"node" => Atom.to_string(node)})

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, contents),
         # Readable only by the user, matching `~/.erlang.cookie` — knowing where Eva is
         # should not be easier than knowing the cookie.
         :ok <- File.chmod(path, 0o600) do
      :ok
    end
  end
end
