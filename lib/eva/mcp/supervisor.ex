defmodule Eva.MCP.Supervisor do
  @moduledoc """
  A dynamic supervisor to spawn MCP clients.
  """
  use DynamicSupervisor
  alias Eva.MCP.{Config, Client}

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 10, max_seconds: 60)
  end

  @spec ensure_started(Config.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(%Config{} = config) do
    # start_child calls Client GenServer with the config
    case DynamicSupervisor.start_child(__MODULE__, {Client, config}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  def stop(%Config{} = config) do
    case Client.whereis(config) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(__MODULE__, pid)
    end
  end
end
