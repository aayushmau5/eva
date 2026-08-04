defmodule Eva.Agent.Session.StateTest do
  use ExUnit.Case, async: true

  alias Eva.Agent.Session.Entries
  alias Eva.Agent.Session.State

  describe "entries_by_extension/1" do
    test "groups by name, strips the prefix, and keeps write order" do
      state = %State{
        custom_entries: [
          custom("ext:notes", %{"text" => "first"}),
          custom("ext:mcp", %{"server" => "github"}),
          custom("ext:notes", %{"text" => "second"})
        ]
      }

      assert %{
               "notes" => [%{"text" => "first"}, %{"text" => "second"}],
               "mcp" => [%{"server" => "github"}]
             } = State.entries_by_extension(state)
    end

    test "core's own namespaces are invisible, even to a same-named extension" do
      state = %State{
        custom_entries: [
          custom("mcp", %{"server_name" => "github", "enabled" => false}),
          custom("extension", %{"name" => "notes", "enabled" => false})
        ]
      }

      assert %{} == State.entries_by_extension(state)
    end
  end

  describe "custom entries and branch summaries" do
    test "settings written before a branch summary survive the replay" do
      # A branch summary truncates the *conversation* so the model does not re-read
      # what was summarised. Custom entries are settings, not conversation — losing
      # them here means a disabled MCP server or an "always allow" silently comes back.
      entries = [
        message("m1"),
        custom("ext:gate", %{"allow" => "rm -rf ./build"}),
        custom("mcp", %{"server_name" => "github", "enabled" => false}),
        branch_summary("summarised"),
        message("m2")
      ]

      state = State.from_entries(entries)

      assert %{"gate" => [%{"allow" => "rm -rf ./build"}]} = State.entries_by_extension(state)
      assert %{"github" => false} = State.mcp_overrides(state)
    end

    test "the conversation is still truncated" do
      entries = [message("m1"), branch_summary("summarised"), message("m2")]

      state = State.from_entries(entries)

      # Two messages: the summary rendered as one, plus m2. m1 is gone.
      assert length(state.messages) == 2
    end
  end

  defp custom(namespace, data) do
    Entries.Custom.new(%{parent_id: nil, namespace: namespace, data: data})
  end

  defp message(text) do
    Entries.Message.new(%{
      parent_id: nil,
      message: %Eva.Agent.Messages.UserMessage{content: text}
    })
  end

  defp branch_summary(summary) do
    Entries.BranchSummary.new(%{parent_id: nil, summary: summary, branch_root_id: nil})
  end
end
