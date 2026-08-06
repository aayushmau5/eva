defmodule Eva.Extension.Supervisor do
  use DynamicSupervisor

  alias Eva.Extension.Server
  alias Eva.Extension.Spec
  alias Eva.Extension.Context

  def start_link(_) do
    DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec start_extension(module(), Spec.t(), Context.t()) :: {:ok, pid()} | {:error, term()}
  def start_extension(module, %Spec{} = spec, %Context{} = context) do
    DynamicSupervisor.start_child(
      __MODULE__,
      {Server, module: module, context: context, event_classes: spec.event_classes}
    )
  end

  @doc """
  Stops an extension.
  """
  @spec stop_extension(pid(), Eva.Extension.terminate_reason()) :: :ok | {:error, :not_found}
  def stop_extension(pid, reason \\ :shutdown) when is_pid(pid) do
    GenServer.call(pid, {:stop, reason}, 5_000)
  catch
    :exit, _ ->
      DynamicSupervisor.terminate_child(__MODULE__, pid)
      :ok
  end
end
