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

    children =
      if match?({:ok, _node}, distribution),
        do: children ++ [{Eva.Cluster, allow: allowed_extensions()}],
        else: children

    Supervisor.start_link(children, strategy: :one_for_one)
  end

  # Registering an extension is the decision to trust it, so the registry *is* the
  # allowlist. Anything reaching the cookie can already do as it likes with this VM; what
  # this stops is a name nobody asked for quietly registering tools the model will call.
  defp allowed_extensions do
    Eva.Extension.Package.allowed_names(%Eva.Coding.Resources{})
  end

  @impl true
  def stop(_state) do
    Eva.Cluster.Distribution.stop()
  end
end
