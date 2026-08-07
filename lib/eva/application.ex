defmodule Eva.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # Opens a listening socket, so only when asked for. `:disabled` is the common case and
    # not a failure — extension nodes simply have nowhere to announce to.
    distribution = Eva.Cluster.Distribution.ensure_started()

    # The `:pg` scope, the extension registry, and `Extension.Supervisor` belong to
    # `eva_core`'s own application, which starts before this one.
    children = [
      {Finch, name: Eva.Finch},
      {Task.Supervisor, name: Eva.TaskSupervisor},
      # Child agents an extension asked for.
      {Registry, keys: :unique, name: Eva.Extension.AgentRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: Eva.Extension.AgentSupervisor}
    ]

    # Registering an extension is the decision to trust it, so the registry *is* the
    # allowlist — `Eva.Cluster` reads it at each announcement, so an extension added while
    # this VM is running is admitted without it having to be told. Anything reaching the
    # cookie can already do as it likes here; what this stops is a name nobody asked for
    # quietly registering tools the model will call.
    children =
      if match?({:ok, _node}, distribution),
        do: children ++ [Eva.Cluster],
        else: children

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
