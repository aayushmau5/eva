defmodule Eva.Test.RemoteTools do
  @moduledoc """
  Executors for the tool-proxy tests, defined where the *extension node* can reach them.

  This has to be a compiled module rather than a closure written in the test file, for the
  same reason the proxy exists at all: a `.exs` test module is loaded into the test VM's
  memory and exists on no code path, so a closure defined there cannot be called on another
  node. `test/support` is compiled into the app's `ebin`, which the node gets via `-pa`.
  """

  alias Eva.Core.Agent.Tools
  alias Eva.Core.Extension.ToolRegistry

  @doc """
  Registers the named tools for a session, on whichever node this runs on.
  """
  @spec register(String.t(), pid(), [atom()]) :: :ok
  def register(extension, session_pid, kinds) do
    ToolRegistry.register(extension, session_pid, Enum.map(kinds, &tool/1))
    :ok
  end

  @doc """
  A description with no executor — what the host receives, and what it binds a proxy to.
  """
  @spec description(String.t()) :: Tools.AgentTool.t()
  def description(name) do
    %Tools.AgentTool{name: name, description: "test tool", input_schema: %{}, executor: nil}
  end

  defp tool(:exploding) do
    %Tools.AgentTool{name: "fixture_echo", executor: fn _args, _ctx -> raise "tool exploded" end}
  end

  defp tool(:slow) do
    %Tools.AgentTool{
      name: "slow",
      executor: fn _args, _ctx ->
        Process.sleep(400)
        :slow_done
      end
    }
  end

  defp tool(:quick) do
    %Tools.AgentTool{name: "quick", executor: fn _args, _ctx -> :quick_done end}
  end
end
