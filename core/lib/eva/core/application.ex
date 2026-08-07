defmodule Eva.Core.Application do
  @moduledoc """
  The runtime an extension needs, wherever it is running.

  The `:pg` scope and the `Processes` registry are runtime, not host: an extension
  process subscribes to the bus and registers itself, and both are silent when missing —
  `Bus.subscribe` delivers nothing, `Server.start_link` fails against a registry that
  isn't there. Owning them here means anything running extensions gets them from
  `Application.ensure_all_started(:eva_core)` rather than from a checklist.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      %{id: :pg, start: {:pg, :start_link, [Eva.PG]}},
      {Registry, keys: :unique, name: Eva.Core.Extension.Processes},
      Eva.Core.Extension.Supervisor,
      # Only used when the session is on another node, but starting it unconditionally
      # costs one idle process and saves every caller a conditional.
      Eva.Core.Extension.ToolRegistry
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__.Supervisor)
  end
end
