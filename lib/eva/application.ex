defmodule Eva.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Finch, name: Eva.Finch},
      {Task.Supervisor, name: Eva.TaskSupervisor},
      {Registry, keys: :unique, name: Eva.MCP.Registry},
      {Registry, keys: :unique, name: Eva.Extension.Processes},
      %{id: :pg, start: {:pg, :start_link, [Eva.PG]}},
      Eva.MCP.Supervisor,
      Eva.Extension.Supervisor
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
