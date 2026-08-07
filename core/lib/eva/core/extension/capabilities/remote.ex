defmodule Eva.Core.Extension.Capabilities.Remote do
  @moduledoc """
  The capability half an extension gets when it runs on its own node.

  `Context.capabilities` names a module, and an extension calls through it rather than
  naming a host module — which is exactly what lets the same extension run in Eva's VM or
  its own without a line changing. This is the version the host installs for extensions
  that are somewhere else: same functions, forwarded across the boundary.

  ## Why `:erpc` and not a named GenServer

  Instead of `GenServer.call({Eva.Extension.Capabilities, node}, ...)`. `:erpc`
  is better here for two reasons: asking the user can block for minutes, and a single
  named server would serialize every extension's questions behind the slowest one unless
  it spawned tasks to avoid exactly that. `:erpc.call/5` already runs each call in its own
  process on the host, and propagates exceptions rather than flattening them.
  """

  require Logger

  @host Eva.Extension.Capabilities

  @doc """
  Asks the user a question, on the host, and waits for the answer.

  Falls back to `default` if the host cannot be reached — the same answer a host with no
  frontend attached would give, and the only sensible one when there is nobody to ask.
  """
  @spec ask(map(), term(), keyword()) :: term()
  def ask(question, default, opts \\ []) do
    session_pid = Keyword.fetch!(opts, :session_pid)

    case call(node(session_pid), :ask, [question, default, opts], :infinity) do
      {:ok, answer} -> answer
      {:error, reason} -> log_and_default(:ask, reason, default)
    end
  end

  @doc """
  Starts a child agent on the host.

  The agent runs there, with the host's provider, and streams its events back to
  `reply_to` — an ordinary pid, which is to say one that works across nodes.
  """
  @spec spawn_agent(struct(), map()) :: {:ok, reference(), pid()} | {:error, term()}
  def spawn_agent(ctx, opts) do
    case call(node(ctx.session_pid), :spawn_agent, [ctx, opts], :infinity) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  @spec stop_agent(struct(), reference()) :: :ok
  def stop_agent(ctx, ref) do
    _ = call(node(ctx.session_pid), :stop_agent, [ref], 5_000)
    :ok
  end

  # -- Private --

  defp call(node, function, args, timeout) do
    {:ok, :erpc.call(node, @host, function, args, timeout)}
  catch
    # The host went away mid-question, or never had the module. Neither is worth crashing
    # an extension over: capabilities are conveniences, and every one of them has a
    # sensible answer for "nobody is listening".
    kind, reason -> {:error, {kind, reason}}
  end

  defp log_and_default(function, reason, default) do
    Logger.warning("capability #{function} could not reach the host: #{inspect(reason)}")
    default
  end
end
