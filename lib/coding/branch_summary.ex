defmodule Eva.Coding.BranchSummary do
  @moduledoc """
  Model-assisted summaries for abandoned session-tree branches.

  Spawns an LmStudio provider process and produces structured summaries
  from a list of conversation messages.
  """

  use GenServer

  alias Eva.AI.Config, as: ProviderConfig
  alias Eva.AI.Events
  alias Eva.AI.LmStudio
  alias Eva.Agent.Messages

  @max_summary_source_message_chars 4_000
  @max_summary_source_total_chars 60_000
  @tool_result_max_chars 2_000

  @type opts :: %{
          provider_config: ProviderConfig.t(),
          messages: Messages.t(),
          custom_instruction: String.t() | nil,
          replace_instruction: boolean()
        }

  @spec start_link(opts :: opts) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec summarize_branch_messages(pid(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def summarize_branch_messages(pid, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    GenServer.call(pid, :summarize, timeout)
  end

  @impl true
  def init(opts) do
    provider_config = Keyword.fetch!(opts, :provider_config)
    messages = Keyword.fetch!(opts, :messages)
    custom_instructions = Keyword.get(opts, :custom_instructions)
    replace_instructions = Keyword.get(opts, :replace_instructions, false)

    state = %{
      provider_config: provider_config,
      messages: messages,
      custom_instructions: custom_instructions,
      replace_instructions: replace_instructions
    }

    {:ok, state, {:continue, :provider}}
  end

  @impl true
  def handle_continue(:provider, state) do
    {:ok, pid} =
      LmStudio.start_link(name: :branch_summary_provider, system_prompt: system_prompt())

    {:noreply, %{state | provider_pid: pid}}
  end

  @impl true
  def handle_call(:summarize, _from, state) do
    if state.messages == [] do
      {:reply, {:error, "no messages to summarize"}, state}
    else
      prompt =
        branch_summary_prompt(
          state.messages,
          state.custom_instructions,
          state.replace_instructions
        )

      :ok =
        LmStudio.run(state.provider_pid,
          listener_pid: self(),
          messages: [%Messages.UserMessage{content: prompt}]
        )

      result = receive_summary(state.messages)
      {:reply, result, state}
    end
  end

  # -- prompt construction ---------------------------------------------------

  # Builds the full LLM prompt: serialized conversation wrapped in <conversation> tags
  # followed by the summary format instructions, optionally customized.
  defp branch_summary_prompt(messages, custom_instructions, replace_instructions) do
    conversation = serialize_branch_conversation(messages)

    instructions =
      cond do
        replace_instructions && custom_instructions ->
          custom_instructions

        custom_instructions ->
          "#{branch_summary_prompt_text()}\n\nAdditional focus: #{custom_instructions}"

        true ->
          branch_summary_prompt_text()
      end

    "<conversation>\n#{conversation}\n</conversation>\n\n#{instructions}"
  end

  # System prompt instructing the LLM to act as a summarization assistant only.
  defp system_prompt do
    """
    You are a context summarization assistant. Your task is to read a conversation between a user and an AI coding assistant,
    then produce a structured summary following the exact format specified.

    Do NOT continue the conversation. Do NOT respond to any questions in the conversation. ONLY output the structured summary.
    """
  end

  # Preamble that introduces the summary as context from a prior conversation branch.
  defp branch_summary_preamble() do
    """
    The user explored a different conversation branch before returning here.
    Summary of that exploration:

    """
  end

  # The structured summary format template sent as the user instruction to the LLM.
  defp branch_summary_prompt_text() do
    """
    Create a structured summary of this conversation branch for context
    when returning later.

    Use this EXACT format:

    ## Goal
    [What was the user trying to accomplish in this branch?]

    ## Constraints & Preferences
    - [Any constraints, preferences, or requirements mentioned]
    - [Or "(none)" if none were mentioned]

    ## Progress
    ### Done
    - [x] [Completed tasks/changes]

    ### In Progress
    - [ ] [Work that was started but not finished]

    ### Blocked
    - [Issues preventing progress, if any]

    ## Key Decisions
    - **[Decision]**: [Brief rationale]

    ## Next Steps
    1. [What should happen next to continue this work]

    Keep each section concise. Preserve exact file paths, function names, and error messages.\
    """
  end

  # -- serialization ---------------------------------------------------------

  # Serializes a list of messages into a single string, respecting per-message and
  # total character limits. Messages that would exceed the budget are omitted.
  defp serialize_branch_conversation(messages) do
    {parts, _remaining, omitted} =
      Enum.reduce(
        messages,
        {[], @max_summary_source_total_chars, 0},
        fn message, {acc, remaining, omitted} ->
          rendered = format_summary_source_message(message)

          if byte_size(rendered) > remaining do
            {acc, 0, omitted + 1}
          else
            {[rendered | acc], remaining - byte_size(rendered), omitted}
          end
        end
      )

    parts = Enum.reverse(parts)

    parts =
      if omitted > 0 do
        parts ++ ["[... #{omitted} message(s) omitted because the branch was too long]"]
      else
        parts
      end

    Enum.join(parts, "\n\n")
  end

  # Dispatches on message type to produce a human-readable, role-prefixed line.
  defp format_summary_source_message(message) do
    case message do
      %Messages.UserMessage{content: content} ->
        "[User]: #{trim_summary_source_text(content)}"

      %Messages.AssistantMessage{} ->
        format_assistant_summary_source(message)

      %Messages.ToolResultMessage{name: name, ok: ok, content: content} ->
        status = if ok, do: "ok", else: "failed"
        trimmed = trim_summary_source_text(content, max_chars: @tool_result_max_chars)
        "[Tool result: #{name} (#{status})]: #{trimmed}"
    end
  end

  # Formats an assistant message: its text content (if any) followed by tool calls.
  defp format_assistant_summary_source(message) do
    %Messages.AssistantMessage{content: content, tool_calls: tool_calls} = message
    parts = []

    parts =
      case trim_summary_source_text(content) do
        empty when empty in ["(empty)", ""] -> parts
        trimmed -> [trimmed | parts]
      end

    parts =
      if tool_calls != [] do
        calls =
          Enum.map(tool_calls, fn call ->
            "#{call.name}(#{format_tool_call_arguments(call.arguments)})"
          end)
          |> Enum.join("; ")

        [calls | parts]
      else
        parts
      end

    rendered = parts |> Enum.reverse() |> Enum.join("\n")

    if rendered == "" do
      "[Assistant]: (empty)"
    else
      "[Assistant]: #{rendered}"
    end
  end

  # Renders tool call arguments as sorted "key=JSON(value)" pairs, or passes through raw strings.
  defp format_tool_call_arguments(arguments) when is_map(arguments) do
    arguments
    |> Enum.sort()
    |> Enum.map_join(", ", fn {key, value} -> "#{key}=#{JSON.encode!(value)}" end)
  end

  defp format_tool_call_arguments(arguments) when is_binary(arguments) do
    arguments
  end

  # Trims text to max_chars, appending an omission note if truncated. Empty text becomes "(empty)".
  defp trim_summary_source_text(text, opts \\ []) do
    max_chars = Keyword.get(opts, :max_chars, @max_summary_source_message_chars)
    normalized = String.trim(text)

    normalized =
      if normalized == "" do
        "(empty)"
      else
        normalized
      end

    if String.length(normalized) <= max_chars do
      normalized
    else
      truncated_chars = String.length(normalized) - max_chars

      "#{String.slice(normalized, 0, max_chars) |> String.trim()}\n\n[... #{truncated_chars} more characters truncated]"
    end
  end

  # -- event collection ------------------------------------------------------

  # Collects streaming provider events, extracts the final response, and augments
  # it with file-operation context before returning.
  defp receive_summary(messages) do
    case receive_summary_loop(nil) do
      {:ok, content} ->
        summary = String.trim(content)

        if summary == "" do
          {:error, "empty summary from model"}
        else
          {:ok, add_branch_summary_context(summary, messages)}
        end

      {:error, _reason} = error ->
        error
    end
  end

  # Receive loop that discards intermediate deltas and returns the content from
  # ProviderResponseEnd, or an error on ProviderError / timeout.
  defp receive_summary_loop(_acc) do
    receive do
      %Events.ProviderResponseStart{} ->
        receive_summary_loop(nil)

      %Events.ProviderTextDelta{} ->
        receive_summary_loop(nil)

      %Events.ProviderThinkingDelta{} ->
        receive_summary_loop(nil)

      %Events.ProviderResponseEnd{message: %Messages.AssistantMessage{content: content}} ->
        {:ok, content}

      %Events.ProviderError{message: reason} ->
        {:error, reason}
    after
      60_000 ->
        {:error, "timed out waiting for branch summary"}
    end
  end

  # -- context augmentation --------------------------------------------------

  # Prepends the branch preamble and appends <read-files> / <modified-files> tags
  # derived from tool calls in the original messages.
  defp add_branch_summary_context(summary, messages) do
    {read_files, modified_files} = branch_file_operations(messages)

    sections = [branch_summary_preamble() <> summary]

    sections =
      if read_files != [] do
        sections ++ ["<read-files>\n#{Enum.join(read_files, "\n")}\n</read-files>"]
      else
        sections
      end

    sections =
      if modified_files != [] do
        sections ++ ["<modified-files>\n#{Enum.join(modified_files, "\n")}\n</modified-files>"]
      else
        sections
      end

    Enum.join(sections, "\n\n")
  end

  # Scans assistant tool calls for read/edit/write operations on file paths.
  # Returns {read_only_paths, modified_paths}, deduplicated and sorted.
  defp branch_file_operations(messages) do
    {read, modified} =
      Enum.reduce(messages, {%{}, %{}}, fn message, {read_acc, mod_acc} ->
        case message do
          %Messages.AssistantMessage{tool_calls: tool_calls} ->
            Enum.reduce(tool_calls, {read_acc, mod_acc}, fn call, {r_acc, m_acc} ->
              path = call.arguments["path"]

              if is_binary(path) and path != "" do
                case call.name do
                  "read" -> {Map.put(r_acc, path, true), m_acc}
                  name when name in ["edit", "write"] -> {r_acc, Map.put(m_acc, path, true)}
                  _ -> {r_acc, m_acc}
                end
              else
                {r_acc, m_acc}
              end
            end)

          _ ->
            {read_acc, mod_acc}
        end
      end)

    read_only = Map.keys(read) |> Enum.reject(&Map.has_key?(modified, &1)) |> Enum.sort()

    {read_only, Map.keys(modified) |> Enum.sort()}
  end
end
