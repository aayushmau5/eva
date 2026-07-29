defmodule Eva.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Finch, name: Eva.Finch},
      {Task.Supervisor, name: Eva.TaskSupervisor},
      {Registry, keys: :unique, name: Eva.MCP.Registry},
      %{id: :pg, start: {:pg, :start_link, [Eva.PG]}},
      Eva.MCP.Supervisor
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
