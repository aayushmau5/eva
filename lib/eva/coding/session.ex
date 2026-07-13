defmodule Eva.Coding.Session do
  @moduledoc """
  The beast.
  """
  use GenServer

  alias Eva.AI.LmStudio
  alias Eva.AI.Config, as: ProviderConfig

  alias Eva.Agent.Session.{Storage, Entries}
  alias Eva.Agent.Session.State, as: SessionState
  alias Eva.Agent.Harness
  alias Eva.Agent.Events, as: AgentEvents

  alias Eva.Coding.SessionConfig
  alias Eva.Coding.Tools, as: CodingTools

  @harness_events Eva.Agent.Events.event_modules()

  use TypedStruct

  typedstruct do
    field :provider_pid, pid()
    field :harness_pid, pid()
    field :session_state, SessionState.t()
    field :last_parent_id, String.t()
    field :skills, list()
    field :prompt_templates, list()
    field :context_files, list()
    field :resource_diagnostics, list()
    field :command_registry, list()
    field :pending_initial_entries, [Entries.t()]
    field :persisted_count, non_neg_integer(), default: 0
    field :config, SessionConfig.t()
    field :provider_config, ProviderConfig.t()
  end

  # -- Public API --

  @spec start_link(opts :: %{config: SessionConfig.t()}) :: GenServer.on_start()
  def start_link(opts) do
    # TODO: think about how do we start this process?
    # Tied to a UI? Standalone? or separate startup: which spinds up UI as well as the Session?
    # One entry point: can branch into UI(TUI/Web) -> FOR V1 (haven't though about distributed connection aspect yet)
    GenServer.start_link(__MODULE__, opts)
  end

  @spec cwd(pid()) :: String.t()
  def cwd(pid) do
    GenServer.call(pid, :cwd)
  end

  def model(_pid) do
    # TODO: return the active model for this session
    ""
  end

  @spec provider_name(pid()) :: String.t()
  def provider_name(_pid) do
    # TODO: return the active provider name
    "lm_studio"
  end

  @spec tools(pid()) :: [Eva.Agent.Tools.tool()]
  def tools(pid) do
    GenServer.call(pid, :tools)
  end

  @spec messages(pid()) :: [Eva.Agent.Messages.t()]
  def messages(pid) do
    GenServer.call(pid, :messages)
  end

  @spec state(pid()) :: SessionState.t()
  def state(pid) do
    GenServer.call(pid, :session_state)
  end

  @spec cancel(pid()) :: :ok
  def cancel(pid) do
    GenServer.call(pid, :cancel)
  end

  @spec prompt(pid(), prompt :: String.t(), streaming_behaviour :: atom() | nil) ::
          :ok | {:error, String.t()}
  def prompt(pid, prompt, streaming_behaviour \\ nil) do
    GenServer.call(pid, {:prompt, prompt, streaming_behaviour})
  end

  # -- GenServer --

  @impl true
  def init(opts) do
    config = Map.fetch!(opts, :config)

    {:ok, %__MODULE__{config: config}, {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, %__MODULE__{config: %SessionConfig{} = config} = state) do
    entries = Storage.read_all(config.storage)

    pending_initial_entries = if length(entries) != 0, do: [], else: make_initial_entries(config)

    if pending_initial_entries != [] do
      Enum.each(pending_initial_entries, &Storage.append(config.storage, &1))
    end

    entries =
      if length(entries) != 0, do: detach_missing_parents(entries), else: pending_initial_entries

    latest_leaf = SessionState.latest_leaf_entry(entries)

    session_state =
      if latest_leaf != nil,
        do: SessionState.from_entries(entries, latest_leaf.entry_id),
        else: SessionState.from_entries(entries)

    tools =
      if length(config.tools) != 0, do: config.tools, else: CodingTools.coding_tools(config.cwd)

    resources =
      if is_nil(config.resource_paths),
        do: load_resources(%Eva.Coding.Resources{cwd: config.cwd}, config.context_files),
        else: config.resource_paths

    system_prompt =
      if is_nil(config.system_prompt) or config.system_prompt != "",
        do:
          %Eva.Coding.SystemPrompt.Options{
            cwd: config.cwd,
            tools: tools,
            skills: resources.skills,
            custom_prompt: config.custom_system_prompt,
            append_system_prompt: config.append_system_prompt,
            context_files: resources.context_files
          }
          |> Eva.Coding.SystemPrompt.build(),
        else: config.system_prompt

    %Eva.AI.Config{} = provider_config = config.provider_config
    provider_config = %Eva.AI.Config{provider_config | system_prompt: system_prompt}

    # TODO: since we only have one provider right now, we are not "refreshing" it against the entries
    # We only know the user selected model after we read the messages(ModelChange). In that case, we need
    # to read the user's selected model and thinking level and spawn up the correct provider process.
    provider_pid =
      spawn_provider(
        reasoning_effort: provider_config.reasoning_effort,
        system_prompt: provider_config.system_prompt,
        model: "nvidia/nemotron-3-nano-4b"
      )

    harness_pid =
      spawn_harness(
        provider_pid: provider_pid,
        coding_session_pid: self(),
        tools: tools,
        messages: session_state.messages
      )

    persisted_count = length(session_state.messages)

    {:noreply,
     %__MODULE__{
       state
       | provider_pid: provider_pid,
         harness_pid: harness_pid,
         session_state: session_state,
         last_parent_id: last_parent_id(session_state),
         skills: resources.skills,
         prompt_templates: resources.prompt_templates,
         context_files: resources.context_files,
         resource_diagnostics: resources.diagnostics,
         command_registry: [],
         persisted_count: persisted_count,
         pending_initial_entries: pending_initial_entries,
         provider_config: provider_config
     }}
  end

  @impl true
  def handle_call(:cwd, _from, %__MODULE__{config: %SessionConfig{} = config} = state) do
    {:reply, config.cwd, state}
  end

  def handle_call(:tools, _from, %__MODULE__{} = state) do
    tools = Harness.tools(state.harness_pid)
    {:reply, tools, state}
  end

  def handle_call(:messages, _from, %__MODULE__{} = state) do
    messages = Harness.messages(state.harness_pid)
    {:reply, messages, state}
  end

  def handle_call(:session_state, _from, %__MODULE__{} = state) do
    {:reply, state.session_state, state}
  end

  def handle_call(:cancel, _from, %__MODULE__{} = state) do
    :ok = Harness.cancel(state.harness_pid)
    {:reply, :ok, state}
  end

  def handle_call({:prompt, prompt, streaming_behaviour}, _from, %__MODULE__{} = state) do
    harness_running? = Harness.running?(state.harness_pid)

    if harness_running? do
      case streaming_behaviour do
        :steer ->
          :ok = Harness.steer(state.harness_pid, prompt)
          {:reply, :ok, state}

        :follow_up ->
          :ok = Harness.follow_up(state.harness_pid, prompt)
          {:reply, :ok, state}

        _ ->
          {:reply, {:error, "Harness already running. No streaming_behaviour is set."}, state}
      end
    else
      {:ok, _harness_state} = Harness.prompt(state.harness_pid, prompt)
      state = persist_new_messages(state)
      {:reply, :ok, state}
    end
  end

  # -- handle_info --
  @impl true
  def handle_info(%AgentEvents.MessageEnd{} = event, state) do
    forward_event(state, event)
    state = persist_new_messages(state)
    {:noreply, state}
  end

  def handle_info(%AgentEvents.ToolExecutionEnd{} = event, state) do
    forward_event(state, event)
    state = persist_new_messages(state)
    {:noreply, state}
  end

  def handle_info(%AgentEvents.AgentEnd{} = event, state) do
    forward_event(state, event)
    state = persist_new_messages(state)
    {:noreply, state}
  end

  def handle_info(%{__struct__: mod} = event, state) when mod in @harness_events do
    forward_event(state, event)
    {:noreply, state}
  end

  # -- Private --

  @spec make_initial_entries(config :: SessionConfig.t()) :: [Entries.t()]
  defp make_initial_entries(%SessionConfig{} = config) do
    info = Entries.SessionInfo.new(%{cwd: config.cwd})
    initial_model = "liquid/lfm2.5-1.2b"
    model = Entries.ModelChange.new(%{parent_id: info.id, model: initial_model})

    thinking_level =
      Entries.ThinkingLevelChange.new(%{
        parent_id: model.id,
        thinking_level: "medium"
      })

    [info, model, thinking_level]
  end

  @spec detach_missing_parents(entries :: [Entries.t()]) :: [Entries.t()]
  defp detach_missing_parents(entries) do
    entry_ids = Enum.map(entries, fn entry -> entry.id end)

    Enum.filter(entries, fn entry ->
      entry.parent_id && entry.parent_id in entry_ids
    end)
  end

  defp spawn_provider(opts) do
    {:ok, pid} =
      LmStudio.start_link(opts)

    pid
  end

  defp spawn_harness(opts) do
    {:ok, pid} = Harness.start_link(opts)
    pid
  end

  defp last_parent_id(%SessionState{} = state) do
    cond do
      state.active_leaf_id != nil -> state.active_leaf_id
      not is_nil(state.entries) and length(state.entries) > 0 -> List.last(state.entries).id
      true -> nil
    end
  end

  defp load_resources(_resource_paths, _explicit_context_files) do
    # load skills with diagnostics
    # load prompt templates
    # discover project context + explicit context files

    %{
      skills: [],
      prompt_templates: [],
      context_files: [],
      diagnostics: []
    }
  end

  # defp try_auto_compact(%__MODULE__{} = state) do
  #   nil
  # end

  defp persist_new_messages(state) do
    messages = Harness.messages(state.harness_pid)
    new_messages = Enum.drop(messages, state.persisted_count)

    state =
      Enum.reduce(new_messages, state, fn message, acc ->
        entry = Entries.Message.new(%{parent_id: acc.last_parent_id, message: message})
        Storage.append(acc.config.storage, entry)
        leaf = Entries.Leaf.new(%{parent_id: entry.id, entry_id: entry.id})
        Storage.append(acc.config.storage, leaf)
        %{acc | last_parent_id: entry.id}
      end)

    %{state | persisted_count: length(messages)}
  end

  # Send events to listener_pid
  # `send` based. To be refactored into PubSub
  defp forward_event(state, event) do
    if state.config.listener_pid do
      send(state.config.listener_pid, event)
    end
  end
end
