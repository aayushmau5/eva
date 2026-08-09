defmodule Eva.Core.Extension.Node do
  @moduledoc """
  Runs this VM as an extension node: find Eva, announce, stay announced.

  Start it from your extension's own application and `mix run --no-halt` is all you need.

      children = [{Eva.Core.Extension.Node, name: "mcp", module: Eva.Extension.MCP}]

  Eva does not start this VM and does not own it. That is the point: an extension node is
  an ordinary Mix project with ordinary dependencies, and in development it is an
  `iex -S mix` you can recompile into while a session is running.

  ## Staying announced

  Eva not being up yet is fine, not an error. This retries with backoff, and keeps
  retrying. If Eva goes away and comes back, it announces again. An extension node
  outliving several Eva restarts is fine.

  ## What a session gets

  Announcing says only "this extension exists here". Each session then asks for its own
  instance, and `setup/1` and `init/1` run *here*, per session, with that session's
  context — the same lifecycle an in-VM extension has, in a different VM.
  """

  use GenServer

  require Logger

  alias Eva.Core.Cluster.{Discovery, Protocol}
  alias Eva.Core.Extension.{Context, Spec, Supervisor, ToolRegistry}

  @initial_backoff 500
  @max_backoff 30_000

  # Attempts before "Eva is not up yet" stops being an explanation and starts being a
  # symptom.
  @loud_after 5

  @typedoc """
  * `:name` — the extension's name, which must match its module's namespace
  * `:module` — the module with `use Eva.Core.Extension`
  * `:eva_node` — skip discovery and announce to this node
  """
  @type option ::
          {:name, String.t()}
          | {:module, module()}
          | {:eva_node, node()}

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  What this node is, whether it is announced, and to whom.
  """
  @spec status() :: %{
          name: String.t(),
          announced?: boolean(),
          eva_node: node() | nil,
          generation: term()
        }
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc """
  Announces now rather than waiting for the next retry.
  """
  @spec announce_now() :: :ok
  def announce_now(server \\ __MODULE__), do: GenServer.cast(server, :announce)

  @impl true
  def init(opts) do
    state = %{
      name: Keyword.fetch!(opts, :name),
      module: Keyword.fetch!(opts, :module),
      eva_node: Keyword.get(opts, :eva_node),
      announced_to: nil,
      generation: nil,
      backoff: @initial_backoff,
      failures: 0,
      last_report: nil
    }

    # `mix run --no-halt` is not a distributed VM, and a VM that is not a node cannot
    # connect to anything. Doing this here means the operational story stays "start it" —
    # no `--name` to remember, and `iex -S mix` works for development unchanged.
    #
    # Best effort: `announce/1` tries again and is where a failure is reported, so a name
    # that is momentarily taken does not have to be fatal here.
    _ = ensure_distributed(state)

    # Tells us when Eva goes away *and* when one appears, so a node started before Eva
    # announces the moment there is something to announce to.
    :ok = :net_kernel.monitor_nodes(true)

    {:ok, state, {:continue, :announce}}
  end

  @impl true
  def handle_continue(:announce, state), do: {:noreply, announce(state)}

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      name: state.name,
      announced?: not is_nil(state.announced_to),
      eva_node: state.announced_to,
      generation: state.generation
    }

    {:reply, status, state}
  end

  @doc false
  # Eva asks for an instance of this extension for one session. `setup/1` runs here, so an
  # extension can decide what it offers based on the session it is being started for —
  # exactly as it does in-VM.
  @impl true
  def handle_call({:instantiate, %Context{} = context, generation}, _from, state) do
    cond do
      generation != state.generation ->
        {:reply, {:error, :stale_generation}, state}

      true ->
        {:reply, instantiate(state.module, context), state}
    end
  end

  @impl true
  def handle_cast(:announce, state), do: {:noreply, announce(state)}

  @impl true
  def handle_info(:retry, state), do: {:noreply, announce(state)}

  def handle_info({:nodeup, _node}, state) do
    # Something joined. If we have nowhere to be, it might be Eva.
    # TODO: tighten it. Extension should not connect to any node other than eva.
    if is_nil(state.announced_to), do: {:noreply, announce(state)}, else: {:noreply, state}
  end

  def handle_info({:nodedown, node}, %{announced_to: node} = state) do
    Logger.info("eva #{node} went away; will announce again when it returns")

    {:noreply, schedule_retry(%{state | announced_to: nil, generation: nil})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # -- Private --

  defp announce(%{announced_to: announced} = state) when not is_nil(announced), do: state

  defp announce(state) do
    # Distribution first, and re-tried rather than assumed: the name may have been taken
    # when this node booted and free a moment later.
    with :ok <- ensure_distributed(state),
         {:ok, eva_node} <- discover(state),
         true <- Node.connect(eva_node),
         {:ok, generation} <- send_announcement(eva_node, state) do
      Logger.info("announced #{state.name} to #{eva_node}")

      %{
        state
        | announced_to: eva_node,
          generation: generation,
          backoff: @initial_backoff,
          failures: 0,
          last_report: nil
      }
    else
      {:error, {:refused, reason}} ->
        # A refusal is a decision, not a hiccup: retrying a version mismatch every half
        # second forever would bury the one message that explains it.
        state
        |> report(:error, "eva refused it: #{Protocol.describe_refusal(reason)}")
        |> Map.put(:backoff, @max_backoff)
        |> schedule_retry()

      {:error, {:distribution, reason}} ->
        state
        |> report(:error, "could not start distribution: #{inspect(reason)}")
        |> schedule_retry()

      other ->
        state |> waiting(other) |> schedule_retry()
    end
  end

  # Eva not being up yet is the ordinary case, and stays quiet
  # until it has been quiet for long enough
  defp waiting(state, reason) do
    state = %{state | failures: state.failures + 1}
    message = "not announced yet: #{inspect(reason)}"

    if state.failures >= @loud_after do
      report(state, :warning, message)
    else
      Logger.debug("#{state.name}: #{message}")
      state
    end
  end

  defp report(state, level, message) do
    if state.last_report == message do
      Logger.debug("#{state.name}: #{message}")
      state
    else
      Logger.log(level, "#{state.name}: #{message}")
      %{state | last_report: message}
    end
  end

  defp send_announcement(eva_node, state) do
    announcement = Protocol.announcement(:extension, state.name, self())

    case GenServer.call({Protocol.directory(), eva_node}, {:announce, announcement}, 10_000) do
      {:ok, generation} -> {:ok, generation}
      {:error, reason} -> {:error, {:refused, reason}}
    end
  catch
    # Eva is up but its directory is not, or the call raced a shutdown. Ordinary; retry.
    :exit, reason -> {:error, {:unreachable, reason}}
  end

  @doc """
  The node name this VM takes when it brings up distribution itself.
  """
  @spec node_name(String.t()) :: node()
  def node_name(name), do: :"eva_ext_#{name}_#{System.pid()}@127.0.0.1"

  defp ensure_distributed(%{name: name}) do
    if Node.alive?() do
      :ok
    else
      # Long names, because a long-named VM and a short-named one cannot connect and the
      # failure says only `:noconnection`.
      # Long names enables cross machine node connection.
      case :net_kernel.start(node_name(name), %{name_domain: :longnames}) do
        {:ok, _pid} ->
          Logger.info("started distribution as #{node()}")
          :ok

        {:error, {:already_started, _pid}} ->
          :ok

        {:error, reason} ->
          {:error, {:distribution, reason}}
      end
    end
  end

  defp schedule_retry(state) do
    Process.send_after(self(), :retry, state.backoff)
    %{state | backoff: min(state.backoff * 2, @max_backoff)}
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

  defp discover(%{eva_node: eva_node}) when not is_nil(eva_node), do: {:ok, eva_node}

  defp discover(_state) do
    # `EVA_NODE` is for a launcher that already knows, and for pinning this node to one Eva
    # when several are up. Without it, epmd is asked.
    case System.get_env("EVA_NODE") do
      name when is_binary(name) and name != "" ->
        {:ok, String.to_atom(name)}

      _unset ->
        # First of however many are running. Arbitrary when there are several, and this
        # node serves one at a time — set `EVA_NODE` when the choice matters. The retry
        # loop calls this again after a `nodedown`, so the Eva that is left is found
        # without anything else having to notice.
        case Discovery.evas() do
          [eva | _rest] -> {:ok, eva}
          [] -> {:error, :no_eva_found}
        end
    end
  end
end
