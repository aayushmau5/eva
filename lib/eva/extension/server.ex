defmodule Eva.Extension.Server do
  use GenServer, restart: :temporary

  require Logger

  def start_link(opts) do
    context = Keyword.fetch!(opts, :context)

    GenServer.start_link(__MODULE__, opts,
      name: via(context.session_pid, context.name),
      timeout: 5_000
    )
  end

  @impl true
  def init(opts) do
    context = Keyword.fetch!(opts, :context)
    module = Keyword.fetch!(opts, :module)
    event_classes = Keyword.get(opts, :event_classes, [])

    # Monitor Session process so we get notified if it goes down
    Process.monitor(context.session_pid)

    :ok = Eva.Bus.subscribe(context.session_pid, event_classes)

    case module.init(context) do
      {:ok, extension_state} ->
        state = %{module: module, context: context, extension_state: extension_state}
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:hook, hook, payload}, _from, state) do
    {result, extension_state} =
      case safe_apply(state, :handle_hook, [hook, payload, state.extension_state]) do
        {:ok, {result, extension_state}} ->
          {result, extension_state}

        {:ok, _malformed} ->
          {hook_failure(hook, payload, "bad return"), state.extension_state}

        {:error, reason} ->
          {hook_failure(hook, payload, reason), state.extension_state}
      end

    {:reply, result, %{state | extension_state: extension_state}}
  end

  def handle_call({:command, name, args}, _from, state) do
    case safe_apply(state, :handle_command, [name, args, state.extension_state]) do
      {:ok, {reply, extension_state}} ->
        {:reply, reply, %{state | extension_state: extension_state}}

      {:ok, _malformed} ->
        {:reply, {:error, :bad_return}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:extension_request, request}, _from, state) do
    case safe_apply(state, :handle_request, [request, state.extension_state]) do
      {:ok, {reply, extension_state}} ->
        {:reply, reply, %{state | extension_state: extension_state}}

      {:ok, _malformed} ->
        {:reply, {:error, :bad_return}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:extension_cast, request}, state) do
    case safe_apply(state, :handle_request, [request, state.extension_state]) do
      {:ok, {_reply, extension_state}} -> {:noreply, %{state | extension_state: extension_state}}
      _ -> {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{context: %{session_pid: pid}} = state) do
    # When Session itself dies
    {:stop, :normal, state}
  end

  def handle_info(event, state) when is_struct(event) do
    case safe_apply(state, :handle_event, [event, state.extension_state]) do
      {:ok, {:ok, extension_state}} -> {:noreply, %{state | extension_state: extension_state}}
      _ -> {:noreply, state}
    end
  end

  def handle_info(_event, state), do: {:noreply, state}

  # -- Private --

  defp safe_apply(state, fun, args) do
    {:ok, apply(state.module, fun, args)}
  rescue
    e -> log_failure(state, fun, Exception.message(e))
  catch
    kind, reason -> log_failure(state, fun, Exception.format(kind, reason))
  end

  defp log_failure(state, fun, reason) do
    Logger.warning("Extension #{state.context.name}: #{fun} failed #{reason}")
    {:error, reason}
  end

  defp hook_failure(:tool_call, _payload, reason), do: {:block, "hook failed: #{reason}"}
  defp hook_failure(:tool_result, {_call, result, is_error}, _reason), do: {result, is_error}
  defp hook_failure(:input, _payload, _reason), do: :continue
  defp hook_failure(_, _payload, _reason), do: :continue

  defp via(session_pid, name) do
    {:via, Registry, {Eva.Extension.Processes, {session_pid, name}}}
  end
end
