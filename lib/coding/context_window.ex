defmodule Eva.Coding.ContextWindow do
  @moduledoc """
  Things related to context window.

  Approximate context-size estimation for coding sessions + Compaction prompt building.
  """

  use TypedStruct

  alias Eva.Agent.{Messages, Tools}

  # rough rule-of-thumb
  @chars_per_token 4

  # fixed cost per message in the transcript array
  @message_overhead_tokens 4

  # fixed cost for each tool definition sent in the system promp
  @tool_overhead_tokens 16

  # max chars per message in the compaction summary prompt
  @summary_message_char_limit 500

  #  When the model has a 128k window, it aims to compact at 128k - 16k = ~111k tokens
  @default_compaction_reserve_tokens 16_384

  # Each compaction entry starts with this prefix(lib/agent/session/state.ex -> format_compaction_summary/1)
  @compaction_summary_prefix "Previous conversation summary:\n"

  @summarization_prompt """
  The messages above are a conversation to summarize. Create a structured context \
  checkpoint summary that another LLM will use to continue the work.

  Use this EXACT format:

  ## Goal
  [What is the user trying to accomplish? Can be multiple items if the session \
  covers different tasks.]

  ## Constraints & Preferences
  - [Any constraints, preferences, or requirements mentioned by user]
  - [Or "(none)" if none were mentioned]

  ## Progress
  ### Done
  - [x] [Completed tasks/changes]

  ### In Progress
  - [ ] [Current work]

  ### Blocked
  - [Issues preventing progress, if any]

  ## Key Decisions
  - **[Decision]**: [Brief rationale]

  ## Next Steps
  1. [Ordered list of what should happen next]

  ## Critical Context
  - [Any data, examples, or references needed to continue]
  - [Or "(none)" if not applicable]

  Keep each section concise. Preserve exact file paths, function names, and error \
  messages.
  """

  @update_summarization_prompt """
  The messages above are NEW conversation messages to incorporate into the existing \
  summary provided in <previous-summary> tags.

  Update the existing structured summary with new information. RULES:
  - PRESERVE all existing information from the previous summary
  - ADD new progress, decisions, and context from the new messages
  - UPDATE the Progress section: move items from "In Progress" to "Done" when \
  completed
  - UPDATE "Next Steps" based on what was accomplished
  - PRESERVE exact file paths, function names, and error messages
  - If something is no longer relevant, you may remove it

  Use this EXACT format:

  ## Goal
  [Preserve existing goals, add new ones if the task expanded]

  ## Constraints & Preferences
  - [Preserve existing, add new ones discovered]

  ## Progress
  ### Done
  - [x] [Include previously done items AND newly completed items]

  ### In Progress
  - [ ] [Current work - update based on progress]

  ### Blocked
  - [Current blockers - remove if resolved]

  ## Key Decisions
  - **[Decision]**: [Brief rationale] (preserve all previous, add new)

  ## Next Steps
  1. [Update based on current state]

  ## Critical Context
  - [Preserve important context, add new if needed]

  Keep each section concise. Preserve exact file paths, function names, and error \
  messages.
  """

  typedstruct module: ContextUsageEstimate do
    field :total_tokens, integer(), enforce: true
    field :system_prompt_tokens, integer(), enforce: true
    field :message_tokens, integer(), enforce: true
    field :tool_tokens, integer(), enforce: true
    field :message_count, integer(), enforce: true
    field :tool_count, integer(), enforce: true
  end

  @doc """
  A deterministic rough token estimate for text.
  """
  @spec estimate_text_tokens(String.t()) :: non_neg_integer()
  def estimate_text_tokens(text) do
    if text == "" do
      0
    else
      max(1, Integer.floor_div(String.length(text) + @chars_per_token - 1, @chars_per_token))
    end
  end

  @doc """
  A rough token estimate for one provider-neutral message.
  """
  @spec estimate_message_tokens(Messages.t()) :: non_neg_integer()
  def estimate_message_tokens(message) do
    case message.role do
      "user" ->
        @message_overhead_tokens + estimate_text_tokens(message.content)

      "assistant" ->
        tool_call_tokens =
          Enum.map(message.tool_calls, fn tc ->
            estimate_text_tokens(tc.name) + estimate_text_tokens(JSON.encode!(tc.arguments))
          end)
          |> Enum.sum()

        @message_overhead_tokens + estimate_text_tokens(message.content) + tool_call_tokens

      "tool" ->
        @message_overhead_tokens +
          estimate_text_tokens(message.name) +
          estimate_text_tokens(message.content)
    end
  end

  @doc """
  A rough token estimate for one tool definition.
  """
  @spec estimate_tool_tokens(Tools.tool()) :: non_neg_integer()
  def estimate_tool_tokens(tool) do
    @tool_overhead_tokens +
      estimate_text_tokens(tool.name) +
      estimate_text_tokens(tool.description) +
      estimate_text_tokens(JSON.encode!(tool.input_schema))
  end

  @spec estimate_context_tokens(String.t(), [Messages.t()], [Tools.tool()]) :: non_neg_integer()
  def estimate_context_tokens(system_prompt, messages, tools) do
    estimate_context_usage(system_prompt, messages, tools).total_tokens
  end

  @spec estimate_context_usage(String.t(), [Messages.t()], [Tools.tool()]) ::
          ContextUsageEstimate.t()
  def estimate_context_usage(system_prompt, messages, tools) do
    system_prompt_tokens = estimate_text_tokens(system_prompt)
    message_tokens = Enum.map(messages, &estimate_message_tokens/1) |> Enum.sum()
    tool_tokens = Enum.map(tools, &estimate_tool_tokens/1) |> Enum.sum()

    %__MODULE__.ContextUsageEstimate{
      total_tokens: system_prompt_tokens + message_tokens + tool_tokens,
      system_prompt_tokens: system_prompt_tokens,
      message_tokens: message_tokens,
      tool_tokens: tool_tokens,
      message_count: length(messages),
      tool_count: length(tools)
    }
  end

  @doc """
  Automatic compaction threshold for a model context window.
  """
  @spec auto_compaction_threshold_for_context_window(integer) :: non_neg_integer()
  def auto_compaction_threshold_for_context_window(context_window_tokens) do
    max(1, context_window_tokens - @default_compaction_reserve_tokens)
  end

  @doc """
  Manual summarise if model-based summarisation fails.
  """
  @spec summarize_messages_for_compaction([Messages.t()]) :: String.t()
  def summarize_messages_for_compaction(messages) do
    if length(messages) > 0 do
      message_texts =
        Enum.with_index(messages, 1)
        |> Enum.map(fn {message, i} ->
          "#{i}. #{message.role}: #{message_text(message)}"
        end)
        |> Enum.join("\n")

      "Automatically compacted #{length(messages)} prior message(s).\n" <> message_texts
    else
      "No prior messages."
    end
  end

  @doc """
  The prompt to compact a history.
  """
  @spec build_compaction_prompt([Messages.t()], String.t() | nil) :: String.t()
  def build_compaction_prompt(messages, custom_instructions \\ nil) do
    # We might already have a compaction in the messages
    {previous_summary, new_messages} = split_previous_compaction_summary(messages)
    conversation = serialize_messages_for_compaction(new_messages)

    prompt = "<conversation>\n#{conversation}\n</conversation>\n\n"

    prompt =
      if not is_nil(previous_summary) do
        prompt <>
          "<previous-summary>\n#{previous_summary}\n</previous-summary>\n\n" <>
          @update_summarization_prompt
      else
        prompt <> @summarization_prompt
      end

    prompt =
      if not is_nil(custom_instructions) and custom_instructions != "" do
        prompt <> "\n\nAdditional instructions: #{custom_instructions}"
      else
        prompt
      end

    prompt
  end

  # - Private helpers -

  defp message_text(message) do
    case message.role do
      "user" ->
        truncate_summary_text(message.content)

      "assistant" ->
        suffix =
          if length(message.tool_calls) > 0,
            do:
              Enum.map(message.tool_calls, & &1.name)
              |> Enum.join(", ")
              |> then(&" [tool calls: #{&1}]"),
            else: ""

        truncate_summary_text(message.content <> suffix)

      "tool" ->
        prefix = "#{message.name} " <> if message.ok, do: "ok: ", else: "failed: "
        truncate_summary_text(prefix <> message.content)
    end
  end

  defp truncate_summary_text(text) do
    collapsed = String.replace(text, ~r/\s+/, " ") |> String.trim()

    if String.length(collapsed) <= @summary_message_char_limit do
      collapsed
    else
      collapsed
      |> String.slice(0, @summary_message_char_limit - 3)
      |> String.trim_trailing()
      |> then(&(&1 <> "..."))
    end
  end

  defp split_previous_compaction_summary(messages) do
    if length(messages) > 0 do
      [first | rest] = messages

      if first.role != "user" or
           not String.starts_with?(first.content, @compaction_summary_prefix) do
        {nil, messages}
      else
        {String.replace_prefix(first.content, @compaction_summary_prefix, ""), rest}
      end
    else
      {nil, messages}
    end
  end

  defp serialize_messages_for_compaction([]), do: "(no new messages)"

  defp serialize_messages_for_compaction(messages) do
    messages
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {message, index} ->
      case message.role do
        "user" ->
          [
            ~s(<message index=#{index} role=user>),
            message.content,
            "</message>"
          ]

        "assistant" ->
          content_line = if message.content != "", do: [message.content], else: []

          tool_call_lines =
            if length(message.tool_calls) > 0 do
              calls =
                Enum.map(message.tool_calls, fn tc ->
                  "- #{tc.name}: #{JSON.encode!(tc.arguments)}"
                end)

              ["<tool-calls>" | calls] ++ ["</tool-calls>"]
            else
              []
            end

          [~s(<message index=#{index} role=assistant>)] ++
            content_line ++ tool_call_lines ++ ["</message>"]

        "tool" ->
          [
            ~s(<message index=#{index} role=tool name=#{message.name} ok=#{message.ok}>),
            message.content,
            "</message>"
          ]
      end
    end)
    |> Enum.join("\n")
  end
end
