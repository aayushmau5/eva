defmodule Eva.Agent.Session.TreeTest do
  use ExUnit.Case, async: true

  alias Eva.Agent.Messages
  alias Eva.Agent.Session.{Entries, State, Tree}

  defp user(text), do: %Messages.UserMessage{content: text}

  defp assistant(text),
    do: %Messages.AssistantMessage{content: [%Messages.TextContent{text: text}]}

  describe "path_to_entry/2" do
    test "returns the branch oldest-first" do
      root = Entries.SessionInfo.new(%{cwd: "/tmp"})
      a = Entries.Message.new(%{parent_id: root.id, message: user("one")})
      b = Entries.Message.new(%{parent_id: a.id, message: assistant("two")})

      assert Tree.path_to_entry([root, a, b], b.id) |> Enum.map(& &1.id) == [root.id, a.id, b.id]
    end

    test "follows only the branch the leaf is on" do
      root = Entries.SessionInfo.new(%{cwd: "/tmp"})
      kept = Entries.Message.new(%{parent_id: root.id, message: user("kept")})
      forked = Entries.Message.new(%{parent_id: root.id, message: user("other branch")})

      ids = Tree.path_to_entry([root, kept, forked], kept.id) |> Enum.map(& &1.id)

      assert ids == [root.id, kept.id]
      refute forked.id in ids
    end
  end

  describe "from_entries/2" do
    # Replaying a stored session has to hand back the conversation in the order it happened,
    # otherwise every reopened session renders back to front.
    test "replays messages in the order they were written" do
      info = Entries.SessionInfo.new(%{cwd: "/tmp"})
      first = Entries.Message.new(%{parent_id: info.id, message: user("hello")})
      first_leaf = Entries.Leaf.new(%{parent_id: first.id, entry_id: first.id})
      second = Entries.Message.new(%{parent_id: first.id, message: assistant("hi back")})
      second_leaf = Entries.Leaf.new(%{parent_id: second.id, entry_id: second.id})

      entries = [info, first, first_leaf, second, second_leaf]
      state = State.from_entries(entries, State.latest_leaf_entry(entries).entry_id)

      assert Enum.map(state.messages, & &1.role) == ["user", "assistant"]
      assert Enum.map(state.messages, &Messages.content_text(&1.content)) == ["hello", "hi back"]
    end
  end
end
