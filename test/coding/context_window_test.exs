defmodule Eva.Coding.ContextWindowTest do
  use ExUnit.Case, async: true

  alias Eva.Coding.ContextWindow
  alias Eva.Agent.{Messages, Tools}

  describe "estimate_text_tokens/1" do
    test "returns 0 for empty string" do
      assert ContextWindow.estimate_text_tokens("") == 0
    end

    test "returns at least 1 for non-empty string" do
      assert ContextWindow.estimate_text_tokens("a") == 1
      assert ContextWindow.estimate_text_tokens("ab") == 1
      assert ContextWindow.estimate_text_tokens("abc") == 1
      assert ContextWindow.estimate_text_tokens("abcd") == 1
    end

    test "scales with character length" do
      assert ContextWindow.estimate_text_tokens("abcdefgh") == 2
      assert ContextWindow.estimate_text_tokens(String.duplicate("x", 100)) == 25
    end
  end

  describe "estimate_message_tokens/1" do
    test "estimates user message tokens" do
      msg = %Messages.UserMessage{content: "hello"}
      tokens = ContextWindow.estimate_message_tokens(msg)
      assert tokens > 0
      # 4 overhead + ceil(5/4) = 4 + 2 = 6
      assert tokens == 6
    end

    test "estimates assistant message without tool calls" do
      msg = %Messages.AssistantMessage{content: "hi", tool_calls: []}
      tokens = ContextWindow.estimate_message_tokens(msg)
      # 4 overhead + ceil(2/4) = 4 + 1 = 5
      assert tokens == 5
    end

    test "estimates assistant message with tool calls" do
      tc = %Tools.ToolCall{
        id: "call_1",
        name: "bash",
        arguments: %{"command" => "ls"}
      }

      msg = %Messages.AssistantMessage{content: "running", tool_calls: [tc]}
      tokens = ContextWindow.estimate_message_tokens(msg)
      # overhead(4) + content "running"(2) + tc_name "bash"(1) + tc_args_json(ceil(json_len/4))
      assert tokens > 0
    end

    test "estimates assistant message with multiple tool calls" do
      tc1 = %Tools.ToolCall{id: "1", name: "read", arguments: %{}}
      tc2 = %Tools.ToolCall{id: "2", name: "bash", arguments: %{"cmd" => "ls"}}

      msg = %Messages.AssistantMessage{content: "", tool_calls: [tc1, tc2]}
      tokens = ContextWindow.estimate_message_tokens(msg)
      assert tokens > 0
    end

    test "estimates tool result message (success)" do
      msg = %Messages.ToolResultMessage{
        tool_call_id: "call_1",
        name: "read_file",
        content: "file contents here",
        ok: true
      }

      tokens = ContextWindow.estimate_message_tokens(msg)
      assert tokens > 0
    end

    test "estimates tool result message (failure)" do
      msg = %Messages.ToolResultMessage{
        tool_call_id: "call_1",
        name: "read_file",
        content: "not found",
        ok: false
      }

      tokens = ContextWindow.estimate_message_tokens(msg)
      assert tokens > 0
    end
  end

  describe "estimate_tool_tokens/1" do
    test "estimates tokens for a tool definition" do
      tool = %Tools.AgentTool{
        name: "read_file",
        description: "Reads a file from disk",
        input_schema: %{type: "object", properties: %{}},
        executor: fn _ -> nil end
      }

      tokens = ContextWindow.estimate_tool_tokens(tool)
      # 16 overhead + name(1) + desc(2) + json-encoded schema
      assert tokens > 16
    end
  end

  describe "estimate_context_usage/3" do
    test "returns a ContextUsageEstimate struct" do
      msg = %Messages.UserMessage{content: "hello"}

      tool = %Tools.AgentTool{
        name: "t",
        description: "d",
        input_schema: %{},
        executor: fn _ -> nil end
      }

      estimate =
        ContextWindow.estimate_context_usage("You are helpful.", [msg], [tool])

      assert %ContextWindow.ContextUsageEstimate{} = estimate
      assert estimate.total_tokens > 0
      assert estimate.system_prompt_tokens > 0
      assert estimate.message_tokens > 0
      assert estimate.tool_tokens > 0
      assert estimate.message_count == 1
      assert estimate.tool_count == 1
    end

    test "handles empty messages and tools" do
      estimate =
        ContextWindow.estimate_context_usage("prompt", [], [])

      assert estimate.message_count == 0
      assert estimate.tool_count == 0
      assert estimate.message_tokens == 0
      assert estimate.tool_tokens == 0
      assert estimate.total_tokens == estimate.system_prompt_tokens
    end
  end

  describe "estimate_context_tokens/3" do
    test "returns total token count" do
      result = ContextWindow.estimate_context_tokens("prompt", [], [])
      assert is_integer(result)
      assert result > 0
    end
  end

  describe "auto_compaction_threshold_for_context_window/1" do
    test "subtracts reserve from context window" do
      assert ContextWindow.auto_compaction_threshold_for_context_window(128_000) ==
               128_000 - 16_384
    end

    test "returns at least 1" do
      assert ContextWindow.auto_compaction_threshold_for_context_window(1) == 1
    end
  end

  describe "summarize_messages_for_compaction/1" do
    test "returns fallback message for empty list" do
      assert ContextWindow.summarize_messages_for_compaction([]) == "No prior messages."
    end

    test "summarizes a single user message" do
      msg = %Messages.UserMessage{content: "hello world"}
      result = ContextWindow.summarize_messages_for_compaction([msg])
      assert result =~ "Automatically compacted 1 prior message"
      assert result =~ "user: hello world"
    end

    test "summarizes multiple messages of different roles" do
      msgs = [
        %Messages.UserMessage{content: "hi"},
        %Messages.AssistantMessage{content: "hey", tool_calls: []},
        %Messages.ToolResultMessage{
          tool_call_id: "1",
          name: "read",
          content: "done",
          ok: true
        }
      ]

      result = ContextWindow.summarize_messages_for_compaction(msgs)
      assert result =~ "Automatically compacted 3 prior message"
      assert result =~ "1. user: hi"
      assert result =~ "2. assistant: hey"
      assert result =~ "3. tool: read ok: done"
    end

    test "includes tool call names in assistant message summary" do
      msg = %Messages.AssistantMessage{
        content: "running",
        tool_calls: [
          %Tools.ToolCall{id: "1", name: "bash", arguments: %{}},
          %Tools.ToolCall{id: "2", name: "read", arguments: %{}}
        ]
      }

      result = ContextWindow.summarize_messages_for_compaction([msg])
      assert result =~ "[tool calls: bash, read]"
    end

    test "shows ok status in tool messages" do
      ok_msg = %Messages.ToolResultMessage{
        tool_call_id: "1",
        name: "cmd",
        content: "output",
        ok: true
      }

      result = ContextWindow.summarize_messages_for_compaction([ok_msg])
      assert result =~ "cmd ok: output"

      fail_msg = %Messages.ToolResultMessage{
        tool_call_id: "1",
        name: "cmd",
        content: "error",
        ok: false
      }

      result = ContextWindow.summarize_messages_for_compaction([fail_msg])
      assert result =~ "cmd failed: error"
    end
  end

  describe "build_compaction_prompt/2" do
    test "returns fresh summarization prompt when no previous summary" do
      msgs = [%Messages.UserMessage{content: "Add a login feature"}]
      prompt = ContextWindow.build_compaction_prompt(msgs)

      assert prompt =~ "<conversation>"
      assert prompt =~ "</conversation>"
      assert prompt =~ "Add a login feature"
      assert prompt =~ "Create a structured context checkpoint summary"
      refute prompt =~ "<previous-summary>"
      refute prompt =~ "incorporate into the existing summary"
    end

    test "returns update summarization prompt when previous summary exists" do
      summary_prefix = "Previous conversation summary:\n"

      msgs = [
        %Messages.UserMessage{content: summary_prefix <> "We built the login page."},
        %Messages.UserMessage{content: "Now add the dashboard."}
      ]

      prompt = ContextWindow.build_compaction_prompt(msgs)

      assert prompt =~ "<conversation>"
      assert prompt =~ "</conversation>"
      assert prompt =~ "Now add the dashboard."
      assert prompt =~ "<previous-summary>"
      assert prompt =~ "We built the login page."
      assert prompt =~ "</previous-summary>"
      assert prompt =~ "incorporate into the existing summary"
    end

    test "first message without compaction prefix does not trigger update path" do
      msgs = [
        %Messages.UserMessage{content: "Some unrelated message"},
        %Messages.UserMessage{content: "Help me with code."}
      ]

      prompt = ContextWindow.build_compaction_prompt(msgs)
      assert prompt =~ "Some unrelated message"
      refute prompt =~ "<previous-summary>"
    end

    test "first message is not user role does not trigger update path" do
      msgs = [
        %Messages.AssistantMessage{content: "I can help", tool_calls: []},
        %Messages.UserMessage{content: "Previous conversation summary:\nold stuff"}
      ]

      prompt = ContextWindow.build_compaction_prompt(msgs)
      refute prompt =~ "<previous-summary>"
    end

    test "returns empty conversation marker when no messages" do
      prompt = ContextWindow.build_compaction_prompt([])
      assert prompt =~ "(no new messages)"
    end

    test "includes custom instructions when provided" do
      msgs = [%Messages.UserMessage{content: "hello"}]
      instructions = "Focus on the database schema changes."

      prompt = ContextWindow.build_compaction_prompt(msgs, instructions)
      assert prompt =~ "Additional instructions: Focus on the database schema changes."
    end

    test "does not include additional instructions when nil or empty" do
      msgs = [%Messages.UserMessage{content: "hello"}]

      prompt = ContextWindow.build_compaction_prompt(msgs, nil)
      refute prompt =~ "Additional instructions"

      prompt = ContextWindow.build_compaction_prompt(msgs, "")
      refute prompt =~ "Additional instructions"
    end

    test "serializes assistant messages with tool calls" do
      tc = %Tools.ToolCall{
        id: "call_1",
        name: "bash",
        arguments: %{"command" => "mix test"}
      }

      msgs = [%Messages.AssistantMessage{content: "Running tests", tool_calls: [tc]}]
      prompt = ContextWindow.build_compaction_prompt(msgs)

      assert prompt =~ ~s(<message index=1 role=assistant>)
      assert prompt =~ "Running tests"
      assert prompt =~ "<tool-calls>"
      assert prompt =~ "- bash:"
      assert prompt =~ "</tool-calls>"
    end

    test "serializes tool result messages" do
      msgs = [
        %Messages.ToolResultMessage{
          tool_call_id: "1",
          name: "read_file",
          content: "file content",
          ok: true
        }
      ]

      prompt = ContextWindow.build_compaction_prompt(msgs)

      assert prompt =~ ~s(<message index=1 role=tool name=read_file ok=true>)
      assert prompt =~ "file content"
      assert prompt =~ "</message>"
    end
  end
end
