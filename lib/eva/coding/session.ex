defmodule Eva.Coding.Session do
  @moduledoc """
  The beast.
  """
  use GenServer
  use TypedStruct

  alias Eva.AI.OpenAICompatibleProvider
  alias Eva.AI.Config, as: ProviderConfig

  alias Eva.Agent.Session.{Storage, Entries}
  alias Eva.Agent.Session.State, as: SessionState
  alias Eva.Agent.Harness
  alias Eva.Agent.Events, as: AgentEvents
  alias Eva.Agent.Tools, as: AgentTools
  alias Eva.Agent.Messages

  alias Eva.Coding.Skills
  alias Eva.Coding.Tools, as: CodingTools
  alias Eva.Coding.SessionIndexManager
  alias Eva.Coding.SessionName
  alias Eva.Coding.ProjectContext

  alias Eva.MCP

  @harness_events [
    AgentEvents.AgentStart,
    AgentEvents.AgentEnd,
    AgentEvents.TurnStart,
    AgentEvents.TurnEnd,
    AgentEvents.MessageStart,
    AgentEvents.MessageUpdate,
    AgentEvents.MessageEnd,
    AgentEvents.ToolExecutionStart,
    AgentEvents.ToolExecutionUpdate,
    AgentEvents.ToolExecutionEnd
  ]

  @mcp_namespace "mcp"
  @mcp_events MCP.Events.modules()

  # Config passed during init
  typedstruct module: SessionConfig do
    field :cwd, String.t(), enforce: true
    field :storage, Storage.t(), enforce: true
    field :system_prompt, String.t()
    field :custom_system_prompt, String.t()
    field :append_system_prompt, String.t()
    field :context_files, [ProjectContext.ContextFile.t()], default: []
    field :tools, [AgentTools.AgentTool.t()] | [], default: []
    field :resource_paths, Eva.Coding.Resources.t()
    field :session_id, String.t()
    field :session_index_manager, SessionIndexManager.t()
    field :model, String.t()
    field :provider_config, ProviderConfig.OpenAICompatible.t()
    field :auto_compact_token_threshold, non_neg_integer(), default: 200_000
    field :auto_compact_enabled, boolean(), default: true
    field :defer_index?, boolean(), default: false
    field :listener_pid, pid() | nil, default: nil
  end

  # Internal state representation
  typedstruct do
    field :provider_pid, pid()
    field :harness_pid, pid()
    field :session_state, SessionState.t()
    field :last_parent_id, String.t()
    field :skills, [Skills.t()]
    field :prompt_templates, list()
    field :context_files, [ProjectContext.ContextFile.t()]
    field :resource_diagnostics, list()
    field :command_registry, list()
    field :pending_initial_entries, [Entries.t()]
    field :persisted_count, non_neg_integer(), default: 0
    # Config passed by caller
    field :config, SessionConfig.t()
    field :provider_config, ProviderConfig.t()
    field :auto_name_attempted, boolean(), default: false
    field :base_tools, [AgentTools.AgentTool.t()], default: []
    field :mcp, MCP.SessionServers.t()
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

  @spec title(pid()) :: String.t() | nil
  def title(pid) do
    GenServer.call(pid, :title)
  end

  @spec prompt(pid(), prompt :: String.t(), streaming_behaviour :: atom() | nil) ::
          :ok | {:error, String.t()}
  def prompt(pid, prompt, streaming_behaviour \\ nil) do
    GenServer.call(pid, {:prompt, prompt, streaming_behaviour})
  end

  @spec available_models(pid()) :: {:ok, [String.t()]} | {:error, term()}
  def available_models(pid) do
    GenServer.call(pid, :available_models)
  end

  @spec list_mcp_servers(pid()) :: [MCP.SessionServers.server_info()]
  def list_mcp_servers(pid) do
    GenServer.call(pid, :list_mcp_servers)
  end

  @spec rename_session(pid(), String.t()) :: String.t()
  def rename_session(pid, name) do
    GenServer.call(pid, {:rename_session, name})
  end

  @doc """
  Forks the current session at the given entry(typically a user message).

  All entries on the path from root up to *but not including* the fork
  point are copied into a new standalone session JSONL file.

  The fork point entry's text content is returned as `prefill_text`.
  """
  @spec fork(pid(), String.t()) ::
          {:ok, session_id :: String.t(), title :: String.t(), prefill_text :: String.t()}
          | {:error, term()}
  def fork(pid, entry_id) do
    GenServer.call(pid, {:fork, entry_id})
  end

  @spec run_bash(pid(), String.t(), keyword()) ::
          {:ok, Messages.BashExecutionMessage.t()} | {:error, term()}
  def run_bash(pid, command, opts \\ []) do
    GenServer.call(pid, {:run_bash, command, opts}, :infinity)
  end

  @doc """
  Enables or disables an MCP server.

  `:session` records the choice in this session's transcript, so it survives a resume
  and leaves other sessions alone. `:persist` writes `enabled` back to the `mcp.json`
  the server came from and clears any session override, so every *new* session picks
  it up — sessions already running keep what they have.
  """
  @spec set_mcp_enabled(pid(), String.t(), boolean(), :session | :persist) ::
          {:ok, [MCP.SessionServers.server_info()]} | {:error, term()}
  def set_mcp_enabled(pid, server_name, enabled?, scope \\ :session)
      when is_boolean(enabled?) and scope in [:session, :persist] do
    GenServer.call(pid, {:set_mcp_enabled, server_name, enabled?, scope})
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

    pending_initial_entries = if entries != [], do: [], else: make_initial_entries(config)

    entries =
      if entries != [], do: detach_missing_parents(entries), else: pending_initial_entries

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

    mcp =
      MCP.SessionServers.new(session_resources(config), SessionState.mcp_overrides(session_state))

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

    provider_pid = spawn_provider(config: config.provider_config)

    harness_pid =
      spawn_harness(
        provider_pid: provider_pid,
        coding_session_pid: self(),
        model: config.model,
        system_prompt: system_prompt,
        tools: tools,
        messages: session_state.messages,
        # TODO: think about this
        before_tool_call: fn _tool_call -> :proceed end,
        after_tool_call: fn _tool_call, result, error -> {result, error} end
      )

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
         pending_initial_entries: pending_initial_entries,
         config: %SessionConfig{config | system_prompt: system_prompt},
         base_tools: tools,
         mcp: mcp
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

  def handle_call(:title, _from, %__MODULE__{} = state) do
    index =
      SessionIndexManager.get_session(state.config.session_index_manager, state.config.session_id)

    {:reply, index.title, state}
  end

  def handle_call({:prompt, prompt, streaming_behaviour}, _from, %__MODULE__{} = state) do
    harness_running? = Harness.running?(state.harness_pid)
    prompt = expand_prompt_text(state, prompt)

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
      prompt = %Messages.UserMessage{content: prompt}
      :ok = refresh_tools(state)
      {:ok, _harness_state} = Harness.prompt(state.harness_pid, prompt)
      state = persist_new_messages(state)
      {:reply, :ok, state}
    end
  end

  def handle_call(:available_models, _from, %__MODULE__{} = state) do
    {:reply, OpenAICompatibleProvider.list_models(state.config.provider_config), state}
  end

  def handle_call(:list_mcp_servers, _from, %__MODULE__{} = state) do
    {:reply, MCP.SessionServers.list(state.mcp), state}
  end

  def handle_call({:set_mcp_enabled, server_name, enabled?, scope}, _from, %__MODULE__{} = state) do
    case MCP.SessionServers.set_enabled(state.mcp, server_name, enabled?, scope) do
      {:ok, mcp} ->
        state = %__MODULE__{state | mcp: mcp}
        # The transcript is the session's to write; `MCP.SessionServers` owns the config
        # and the clients, not our storage.
        state =
          if scope == :session, do: append_mcp_toggle(state, server_name, enabled?), else: state

        {:reply, {:ok, MCP.SessionServers.list(mcp)}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:rename_session, name}, _from, state) do
    if not is_nil(name) and not is_nil(state.config.session_id) do
      SessionIndexManager.touch_session(
        state.config.session_index_manager,
        state.config.session_id,
        nil,
        nil,
        name
      )
    end

    {:reply, name, state}
  end

  def handle_call({:fork, entry_id}, _from, %__MODULE__{} = state) do
    entries = Storage.read_all(state.config.storage)
    by_id = Eva.Agent.Session.Tree.entries_by_id(entries)

    case Map.get(by_id, entry_id) do
      nil ->
        {:reply, {:error, {:entry_not_found, entry_id}}, state}

      %Entries.Message{message: %Messages.UserMessage{}} = fork_point ->
        prefill_text = get_user_message_text(fork_point)

        copy_entries =
          if fork_point.parent_id do
            Eva.Agent.Session.Tree.path_to_entry(entries, fork_point.parent_id)
          else
            []
          end

        case get_original_index(state) do
          {:ok, index} ->
            fork_title = "fork: #{index.title || "unnamed"}"

            fork_index =
              SessionIndexManager.prepare_fork_index(
                state.config.session_index_manager,
                index,
                fork_title
              )

            SessionIndexManager.index_session!(state.config.session_index_manager, fork_index)

            fork_storage = Storage.Jsonl.new(fork_index.session_path)

            # Copy over each entry to new forked session file
            Enum.each(copy_entries, fn entry ->
              :ok = Storage.append(fork_storage, entry)
            end)

            fork_entry =
              Entries.Custom.new(%{
                parent_id: state.last_parent_id,
                namespace: "fork",
                data: %{
                  title: fork_title,
                  forked_session_id: fork_index.id,
                  forked_from_entry_id: entry_id
                }
              })

            # For a client to build a list of forked message, they'll have to scan through the entries.
            # We can optimise this for the client later.
            :ok = Storage.append(state.config.storage, fork_entry)

            {:reply, {:ok, fork_index.id, fork_title, prefill_text},
             %__MODULE__{state | last_parent_id: fork_entry.id}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:run_bash, command, opts}, _from, %__MODULE__{} = state) do
    if Harness.running?(state.harness_pid) do
      {:reply, {:error, :agent_running}, state}
    else
      timeout = Keyword.get(opts, :timeout, 120_000)
      result = Eva.Coding.ShellExec.run(command, cwd: state.config.cwd, timeout: timeout)
      truncation = CodingTools.truncate_tail(result.output)

      {output, full_output_path} =
        if truncation.truncated do
          path = CodingTools.write_temp_output(result.output)
          {truncation.content <> CodingTools.build_truncation_suffix(truncation, path), path}
        else
          {truncation.content, nil}
        end

      message = %Messages.BashExecutionMessage{
        command: command,
        output: output,
        exit_code: result.exit_status,
        cancelled: result.cancelled,
        truncated: truncation.truncated,
        full_output_path: full_output_path,
        timestamp: Eva.Agent.Utils.current_timestamp_ms(),
        exclude_from_context: Keyword.get(opts, :exclude_from_context, false)
      }

      {:ok, _} =
        Harness.update_messages(
          state.harness_pid,
          Harness.messages(state.harness_pid) ++ [message]
        )

      state = persist_new_messages(state)

      forward_event(state, %AgentEvents.MessageEnd{message: message})

      {:reply, {:ok, message}, state}
    end
  end

  # -- handle_info --
  @impl true
  def handle_info(%AgentEvents.MessageEnd{} = event, state) do
    state = persist_new_messages(state)

    state =
      if match?(%Messages.UserMessage{}, event.message) do
        try_auto_name_session(event.message.content, state)
      else
        state
      end

    forward_event(state, event)
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

  def handle_info(%{__struct__: mod} = event, %__MODULE__{} = state) when mod in @mcp_events do
    state = %__MODULE__{state | mcp: MCP.SessionServers.apply_event(state.mcp, event)}
    forward_event(state, event)
    {:noreply, state}
  end

  def handle_info({:session_name, name}, state) do
    if not is_nil(name) and not is_nil(state.config.session_id) do
      SessionIndexManager.touch_session(
        state.config.session_index_manager,
        state.config.session_id,
        nil,
        nil,
        name
      )
    end

    {:noreply, state}
  end

  @doc """
  Records a session-scoped MCP enable/disable in the transcript.

  Written as a `Custom` entry. `data` keys are strings so an entry built here and one
  replayed from jsonl are indistinguishable.
  """
  @spec append_mcp_toggle(t(), String.t(), boolean()) :: t()
  def append_mcp_toggle(%__MODULE__{} = state, server_name, enabled) do
    state = write_pending_initial_entries(state)

    entry =
      Entries.Custom.new(%{
        parent_id: state.last_parent_id,
        namespace: @mcp_namespace,
        data: %{"server_name" => server_name, "enabled" => enabled}
      })

    :ok = Storage.append(state.config.storage, entry)
    leaf = Entries.Leaf.new(%{parent_id: entry.id, entry_id: entry.id})
    :ok = Storage.append(state.config.storage, leaf)

    %__MODULE__{state | last_parent_id: entry.id}
  end

  # -- Private --

  @spec make_initial_entries(config :: SessionConfig.t()) :: [Entries.t()]
  defp make_initial_entries(%SessionConfig{} = config) do
    info = Entries.SessionInfo.new(%{cwd: config.cwd})
    model = Entries.ModelChange.new(%{parent_id: info.id, model: config.model})

    thinking_level =
      Entries.ThinkingLevelChange.new(%{
        parent_id: model.id,
        thinking_level: "medium"
      })

    [info, model, thinking_level]
  end

  @spec detach_missing_parents(entries :: [Entries.t()]) :: [Entries.t()]
  defp detach_missing_parents(entries) do
    entry_ids = MapSet.new(entries, & &1.id)

    Enum.map(entries, fn entry ->
      if entry.parent_id != nil && entry.parent_id not in entry_ids do
        %{entry | parent_id: nil}
      else
        entry
      end
    end)
  end

  defp spawn_provider(opts) do
    case OpenAICompatibleProvider.start_link(opts) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
      {:error, reason} -> raise reason
    end
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

  defp session_resources(%SessionConfig{} = config) do
    config.resource_paths || %Eva.Coding.Resources{cwd: config.cwd}
  end

  defp load_resources(resource_paths, explicit_context_files) do
    # load skills with diagnostics
    # load prompt templates
    discovered_context_files = ProjectContext.discover(resource_paths)
    context_files = Enum.uniq_by(explicit_context_files ++ discovered_context_files, & &1.path)

    %{
      skills: Skills.load(resource_paths),
      prompt_templates: [],
      context_files: context_files,
      diagnostics: []
    }
  end

  # Expand prompt text with markdown resources like skills or prompt templates.
  defp expand_prompt_text(state, content) do
    case Skills.expand_skill_command(content, state.skills) do
      {:ok, nil} ->
        content

      {:ok, expanded} ->
        expanded

      {:error, _reason} ->
        # TODO: Use logger to log the issue
        content
    end
  end

  # defp try_auto_compact(%__MODULE__{} = state) do
  #   nil
  # end

  defp persist_new_messages(state) do
    # Create index file initially
    if ok_to_index?(state) do
      index_manager = state.config.session_index_manager

      existing =
        Eva.Coding.SessionIndexManager.get_session(
          index_manager,
          state.config.session_id
        )

      if is_nil(existing) do
        Eva.Coding.SessionIndexManager.create_index(index_manager, %{
          session_id: state.config.session_id,
          cwd: state.config.cwd,
          model: state.config.model,
          provider_name: provider_name(nil)
        })
      end
    end

    state = write_pending_initial_entries(state)

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

  # Rebuilt at every prompt rather than kept in sync from events, because
  # `Harness.update_tools/2` is inert mid-run — `Loop` takes `tools:` by value
  # at spawn and freezes `tool_by_name`. A prompt is therefore the only moment
  # a tool list change can take effect, and doing it here is also what gets
  # MCP tools into the *first* prompt of a session.
  defp refresh_tools(%__MODULE__{} = state) do
    {:ok, _harness_state} =
      Harness.update_tools(
        state.harness_pid,
        state.base_tools ++ MCP.SessionServers.tools(state.mcp)
      )

    :ok
  end

  # A session-scoped toggle wins over the config file; with no toggle recorded,
  # the file decides.

  # Send events to listener_pid
  # `send` based. To be refactored into PubSub
  defp forward_event(state, event) do
    if state.config.listener_pid do
      send(state.config.listener_pid, event)
    end
  end

  defp write_pending_initial_entries(%__MODULE__{} = state) do
    pending_entries = state.pending_initial_entries

    if length(pending_entries) != 0 do
      Enum.each(pending_entries, fn entry -> :ok = Storage.append(state.config.storage, entry) end)

      %__MODULE__{state | pending_initial_entries: []}
    else
      state
    end
  end

  defp try_auto_name_session(content, state) do
    if not state.auto_name_attempted and fresh_session?(state) do
      session_pid = self()
      model = state.config.model

      Task.start(fn ->
        title =
          SessionName.name_session(content, %{model: model, config: state.config.provider_config}) ||
            SessionName.sanitize_session_name(content)

        send(session_pid, {:session_name, title})
      end)

      %{state | auto_name_attempted: true}
    else
      state
    end
  end

  defp fresh_session?(%__MODULE__{} = state) do
    if not is_nil(state.config.session_id) do
      session =
        SessionIndexManager.get_session(
          state.config.session_index_manager,
          state.config.session_id
        )

      if not is_nil(session) && not is_nil(session.title) do
        false
      else
        Harness.messages(state.harness_pid)
        |> Enum.count(&match?(%Messages.UserMessage{}, &1)) == 1
      end
    else
      false
    end
  end

  defp ok_to_index?(state) do
    length(state.pending_initial_entries) > 0 and
      not state.config.defer_index? and
      not is_nil(state.config.session_id) and
      state.config.session_id != ""
  end

  defp get_user_message_text(%Entries.Message{message: %Messages.UserMessage{} = message}) do
    Messages.UserMessage.text(message)
  end

  defp get_original_index(state) do
    case SessionIndexManager.get_session(
           state.config.session_index_manager,
           state.config.session_id
         ) do
      %Entries.SessionIndexEntry{} = entry -> {:ok, entry}
      nil -> {:error, :original_not_indexed}
    end
  end
end
