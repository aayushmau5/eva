defmodule Eva.Extension.Capabilities do
  @moduledoc """
  The host half of the capability API.

  Extensions never call into Eva directly. They hold a `Context`, and `Context`
  carries this module — so `Eva.Extension.UI` and anything like it dispatches
  through a module reference rather than naming a host module. That indirection is
  what lets the same extension run somewhere other than Eva's own VM later without
  a line changing.
  """

  @doc """
  Asks the user a question and returns their answer.

  Until the UI capability is built this always returns `default` immediately, which
  is also the correct behaviour whenever no frontend is attached: print mode,
  scripts, and tests must never block on a dialog nobody can see.
  """
  @spec ask(map(), term(), keyword()) :: term()
  def ask(_question, default, _opts \\ []), do: default

  @doc """
  Starts a child agent for an extension.

  Supervised rather than linked to the caller: a tool executor is gone long before a
  background agent finishes. The runner monitors `reply_to` instead, so the agent
  still dies with whatever is waiting on it.

  `provider_config` comes from the `Context` — a child inherits the parent's provider
  and, unless told otherwise, its model.
  """
  @spec spawn_agent(Eva.Core.Extension.Context.t(), map()) ::
          {:ok, reference(), pid()} | {:error, term()}
  def spawn_agent(%Eva.Core.Extension.Context{} = ctx, opts) do
    ref = make_ref()

    opts =
      opts
      |> Map.put(:provider_config, ctx.provider_config)
      |> Map.put_new(:model, ctx.model)

    case DynamicSupervisor.start_child(
           Eva.Extension.AgentSupervisor,
           {Eva.Extension.AgentRunner, {ref, opts}}
         ) do
      {:ok, pid} -> {:ok, ref, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Stops a child agent.
  """
  @spec stop_agent(Eva.Core.Extension.Context.t(), reference()) :: :ok
  def stop_agent(%Eva.Core.Extension.Context{}, ref), do: Eva.Extension.AgentRunner.stop(ref)
end
