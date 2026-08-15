defmodule Eva.Core.Extension.Node do
  @moduledoc """
  Runs this VM as an extension node: sit still, and answer whoever is allowed to ask.

  Start it from your extension's own application.

      children = [{Eva.Core.Extension.Node, name: "mcp", module: Eva.Extension.MCP}]

  Eva does not start this VM and does not own it. That is the point: an extension node is
  an ordinary Mix project with ordinary dependencies, and in development it is an
  `iex -S mix` you can recompile into while a session is running.

  ## Eva dials

  Eva finds this node, asks `describe/1` what it is, and `attach/3`es if it likes the
  answer. One path serves an extension on this machine and one on another.

  Two consequences worth knowing. Starting a node while Eva is running is no longer
  instant — Eva notices on its next scan, a second or two later. And several Evas can use
  this node at once, which is why generations are kept per Eva rather than as one number.

  ## Which machines can see it

  By default, only this one: distribution listens on loopback and the node is named
  `eva_ext_<name>@127.0.0.1`. Passing `:port` offers it to the rest of your tailnet
  instead — this machine's address, that one port, and a node name that says so.

      children = [{Eva.Core.Extension.Node, name: "mcp", module: Eva.Extension.MCP, port: 9000}]

  ## Which Evas it will serve

  `:serve` is the other half of that. Being dialable means anything reaching the cookie can
  ask this node to instantiate an extension; `:serve` says which Evas get an answer.

      {Eva.Core.Extension.Node, name: "mcp", module: MCP, serve: [:"eva_9@100.64.5.20"]}

  It defaults to `:any`, which is right for a loopback-only node — everything able to reach
  it is already you, on your own machine. Eva decides who it dials and this decides who it
  serves, so neither side can force the other.

  ## What a session gets

  Attaching says only "this extension exists here". Each session then asks for its own
  instance, and `setup/1` and `init/1` run *here*, per session, with that session's
  context — the same lifecycle an in-VM extension has.
  """

  use GenServer

  require Logger

  alias Eva.Core.Cluster.{Listener, Protocol}
  alias Eva.Core.Extension.{Context, Spec, Supervisor, ToolRegistry}

  @prefix "eva_ext_"

  @typedoc """
  * `:name` — the extension's name, which must match its module's namespace
  * `:module` — the module with `use Eva.Core.Extension`
  * `:port` — offer this node to other machines, on this machine's address at this port.
    Absent, it listens on loopback and only its own machine can see it.
  * `:serve` — which Evas may attach: `:any` (the default) or a list of node names
  """
  @type option ::
          {:name, String.t()}
          | {:module, module()}
          | {:port, :inet.port_number()}
          | {:serve, :any | [node()]}

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  What this node is. Eva's first question, asked over `:erpc`.
  """
  @spec describe(GenServer.server()) :: Protocol.Description.t()
  def describe(server \\ __MODULE__), do: GenServer.call(server, :describe)

  @doc """
  Takes an Eva on, at the generation it minted for this node.

  Refused when `:serve` does not name that Eva. Eva calls this over `:erpc` once it likes
  what `describe/1` said, and the generation is what `instantiate` is checked against.
  """
  @spec attach(GenServer.server(), node(), pos_integer()) :: :ok | {:error, :not_consented}
  def attach(server \\ __MODULE__, eva_node, generation) when is_atom(eva_node) do
    GenServer.call(server, {:attach, eva_node, generation})
  end

  @doc """
  What this node is called, and which Evas it is currently serving.
  """
  @spec status(GenServer.server()) :: %{
          name: String.t(),
          serving: [node()],
          os_pid: String.t(),
          port: :inet.port_number() | nil
        }
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(opts) do
    state = %{
      name: Keyword.fetch!(opts, :name),
      module: Keyword.fetch!(opts, :module),
      port: Keyword.get(opts, :port),
      serve: Keyword.get(opts, :serve, :any),
      # One generation per Eva. Each mints from its own private counter.
      generations: %{}
    }

    # Ensure node
    case ensure_distributed(state) do
      :ok ->
        :ok

      # Asked to be reachable with no address to be reachable at. Carrying on would produce
      # a node that looks fine and can never be dialled, so we raise.
      {:error, :no_reachable_address} ->
        raise unreachable_message(state)

      # Also fatal, and for the same reason.
      {:error, reason} ->
        raise """
        #{state.name}: could not start distribution.

        Most often the name is already taken, meaning another VM is running this same extension — `mix eva.ext.list` \
        will say which.

        #{inspect(reason, limit: 3)}\
        """
    end

    # To forget an Eva that dies.
    :ok = :net_kernel.monitor_nodes(true)

    {:ok, state}
  end

  @impl true
  def handle_call(:describe, _from, state) do
    {:reply, Protocol.description(:extension, state.name, self()), state}
  end

  def handle_call({:attach, eva_node, generation}, _from, state) do
    if serves?(state, eva_node) do
      Logger.info("#{state.name}: attached to #{eva_node} at generation #{generation}")
      {:reply, :ok, put_in(state.generations[eva_node], generation)}
    else
      Logger.warning("#{state.name}: declined #{eva_node} — not in :serve")
      {:reply, {:error, :not_consented}, state}
    end
  end

  def handle_call(:status, _from, state) do
    status = %{
      name: state.name,
      serving: Map.keys(state.generations),
      os_pid: System.pid(),
      port: state.port
    }

    {:reply, status, state}
  end

  @doc false
  # Eva asks for an instance of this extension for one session. `setup/1` runs here, so an
  # extension can decide what it offers based on the session it is being started for,
  # exactly as it does in-VM.
  @impl true
  def handle_call({:instantiate, %Context{} = context, generation}, _from, state) do
    # Which Eva is asking is not in the request and does not need to be: a session runs on
    # its own Eva, so its pid carries the answer.
    eva_node = node(context.session_pid)

    if Map.get(state.generations, eva_node) == generation do
      {:reply, instantiate(state.module, context), state}
    else
      {:reply, {:error, :stale_generation}, state}
    end
  end

  @impl true
  def handle_info({:nodedown, node}, state) do
    case Map.pop(state.generations, node) do
      {nil, _generations} ->
        {:noreply, state}

      {_generation, generations} ->
        Logger.info("#{state.name}: #{node} went away; no longer serving it")
        {:noreply, %{state | generations: generations}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc """
  The node name this VM takes when it brings up distribution itself.
  """
  @spec node_name(String.t(), String.t()) :: node()
  def node_name(name, host), do: :"#{epmd_name(name)}@#{host}"

  @doc """
  Prefixes name with "eva_ext_"
  """
  @spec epmd_name(String.t()) :: String.t()
  def epmd_name(name), do: @prefix <> name

  @doc """
  Whether a bare node name (no `@host`) looks like an extension node's.

  Lives here so the prefix is written once. Eva scans epmd for these, and if the two
  halves drifted apart extensions would simply stop being found, with nothing to say why.
  """
  @spec node_name?(String.t()) :: boolean()
  def node_name?(name) when is_binary(name), do: String.starts_with?(name, @prefix)

  # -- Private --

  defp serves?(%{serve: :any}, _eva_node), do: true
  defp serves?(%{serve: allowed}, eva_node) when is_list(allowed), do: eva_node in allowed

  # `:port` is the whole of "this node may be dialled from another machine": it decides the
  # interface, the port, and therefore the name, together.
  defp listen_as(%{port: nil}), do: :loopback
  defp listen_as(%{port: port}), do: {:reachable, port}

  defp ensure_distributed(%{name: name} = state) do
    case Listener.start(fn host -> node_name(name, host) end, listen_as(state)) do
      {:ok, _node} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp unreachable_message(%{name: name, port: port}) do
    """
    #{name} was asked to listen on port #{port} for other machines, but this machine has no \
    address to offer.

    Nothing matched: `config :eva_core, :host`, the `EVA_HOST` environment variable, and no \
    interface holds a Tailscale address (100.64.0.0/10). Start Tailscale, or set one of \
    those, or drop `:port` to run this extension for its own machine only.\
    """
  end

  defp instantiate(module, context) do
    with {:ok, %Spec{} = spec} <- call_setup(module, context),
         {:ok, pid} <- maybe_start(module, spec, context) do
      # The tools `setup/1` returned have never been through `update_tools/2`, so their
      # closures would travel to a host that cannot call them. Same treatment, same reason.
      {:ok, pid, %Spec{spec | tools: register_tools(context, spec.tools)}}
    end
  end

  defp register_tools(%Context{session_pid: session_pid, name: name}, tools) do
    if node(session_pid) == node() do
      tools
    else
      ToolRegistry.register(name, session_pid, tools)
    end
  end

  defp call_setup(module, context) do
    case module.setup(context) do
      {:ok, %Spec{} = spec} -> {:ok, spec}
      {:error, reason} -> {:error, inspect(reason)}
      other -> {:error, "setup/1 returned #{inspect(other)}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, Exception.format(kind, reason)}
  end

  # A stateless extension has no process, here or anywhere — the host gets the spec and
  # that is all there is.
  defp maybe_start(module, %Spec{} = spec, context) do
    if Spec.stateful?(spec) do
      case Supervisor.start_extension(module, spec, context) do
        {:ok, pid} -> {:ok, pid}
        {:error, reason} -> {:error, "failed to start: #{inspect(reason)}"}
      end
    else
      {:ok, nil}
    end
  end
end
