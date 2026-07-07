defmodule Eva.Agent.Session.JsonlTest do
  use ExUnit.Case

  alias Eva.Agent.Messages
  alias Eva.Agent.Tools.ToolCall
  alias Eva.Agent.Session.Entries
  alias Eva.Agent.Session.Jsonl

  describe "entry_to_json_line/1" do
    test "serializes a ModelChange entry" do
      entry = %Entries.ModelChange{
        id: "abc",
        parent_id: nil,
        timestamp: 1.0,
        type: "model_change",
        model: "gpt-4"
      }

      line = Jsonl.entry_to_json_line(entry)
      assert String.ends_with?(line, "\n")
      decoded = JSON.decode!(String.trim(line))
      assert decoded["type"] == "model_change"
      assert decoded["model"] == "gpt-4"
    end

    test "serializes a Message entry with tool calls" do
      tc = %ToolCall{id: "t1", name: "read", arguments: %{"path" => "foo.ex"}}
      msg = %Messages.AssistantMessage{role: "assistant", content: "ok", tool_calls: [tc]}

      entry = %Entries.Message{
        id: "m1",
        parent_id: "p1",
        timestamp: 2.0,
        type: "message",
        message: msg
      }

      line = Jsonl.entry_to_json_line(entry)
      assert String.ends_with?(line, "\n")
      decoded = JSON.decode!(String.trim(line))
      assert decoded["type"] == "message"
      assert get_in(decoded, ["message", "content"]) == "ok"
      assert length(decoded["message"]["tool_calls"]) == 1
    end

    test "serializes a ThinkingLevelChange entry" do
      entry = %Entries.ThinkingLevelChange{
        id: "tl1",
        parent_id: nil,
        timestamp: 3.0,
        type: "thinking_level_change",
        thinking_level: "high"
      }

      line = Jsonl.entry_to_json_line(entry)
      decoded = JSON.decode!(String.trim(line))
      assert decoded["thinking_level"] == "high"
    end

    test "serializes a Compaction entry" do
      entry = %Entries.Compaction{
        id: "c1",
        parent_id: nil,
        timestamp: 4.0,
        type: "compaction",
        summary: "summary text",
        replaces_entry_ids: ["a", "b"]
      }

      line = Jsonl.entry_to_json_line(entry)
      decoded = JSON.decode!(String.trim(line))
      assert decoded["summary"] == "summary text"
      assert decoded["replaces_entry_ids"] == ["a", "b"]
    end

    test "serializes a BranchSummary entry" do
      entry = %Entries.BranchSummary{
        id: "bs1",
        parent_id: "p2",
        timestamp: 5.0,
        type: "branch_summary",
        summary: "branch",
        branch_root_id: "root1"
      }

      line = Jsonl.entry_to_json_line(entry)
      decoded = JSON.decode!(String.trim(line))
      assert decoded["summary"] == "branch"
      assert decoded["branch_root_id"] == "root1"
    end

    test "serializes a Label entry" do
      entry = %Entries.Label{
        id: "l1",
        parent_id: nil,
        timestamp: 6.0,
        type: "label",
        label: "important"
      }

      line = Jsonl.entry_to_json_line(entry)
      decoded = JSON.decode!(String.trim(line))
      assert decoded["label"] == "important"
    end

    test "serializes a Leaf entry" do
      entry = %Entries.Leaf{
        id: "lf1",
        parent_id: nil,
        timestamp: 7.0,
        type: "leaf",
        entry_id: "e1"
      }

      line = Jsonl.entry_to_json_line(entry)
      decoded = JSON.decode!(String.trim(line))
      assert decoded["entry_id"] == "e1"
    end

    test "serializes a SessionInfo entry" do
      entry = %Entries.SessionInfo{
        id: "si1",
        parent_id: nil,
        timestamp: 8.0,
        type: "session_info",
        cwd: "/home/user",
        title: "my session"
      }

      line = Jsonl.entry_to_json_line(entry)
      decoded = JSON.decode!(String.trim(line))
      assert decoded["cwd"] == "/home/user"
      assert decoded["title"] == "my session"
    end

    test "serializes a Custom entry" do
      entry = %Entries.Custom{
        id: "cu1",
        parent_id: nil,
        timestamp: 9.0,
        type: "custom",
        namespace: "my_ns",
        data: %{"key" => "value"}
      }

      line = Jsonl.entry_to_json_line(entry)
      decoded = JSON.decode!(String.trim(line))
      assert decoded["namespace"] == "my_ns"
      assert decoded["data"]["key"] == "value"
    end
  end

  describe "entry_from_json_line/2" do
    test "deserializes a ModelChange" do
      json =
        ~s({"id":"abc","parent_id":null,"timestamp":1.0,"type":"model_change","model":"gpt-4"})

      entry = Jsonl.entry_from_json_line(json)
      assert %Entries.ModelChange{} = entry
      assert entry.model == "gpt-4"
    end

    test "deserializes a Message with tool calls" do
      json =
        ~s({"id":"m1","parent_id":"p1","timestamp":2.0,"type":"message","message":{"role":"assistant","content":"ok","tool_calls":[{"id":"t1","name":"read","arguments":{"path":"foo.ex"}}]}})

      entry = Jsonl.entry_from_json_line(json)
      assert %Entries.Message{} = entry
      assert entry.message.content == "ok"
      assert [%ToolCall{id: "t1", name: "read"}] = entry.message.tool_calls
    end

    test "deserializes a Message with no tool_calls" do
      json =
        ~s({"id":"m2","parent_id":null,"timestamp":3.0,"type":"message","message":{"role":"assistant","content":"hi","tool_calls":[]}})

      entry = Jsonl.entry_from_json_line(json)
      assert %Entries.Message{} = entry
      assert entry.message.tool_calls == []
    end

    test "deserializes a ThinkingLevelChange with nil level" do
      json =
        ~s({"id":"tl1","parent_id":null,"timestamp":4.0,"type":"thinking_level_change","thinking_level":null})

      entry = Jsonl.entry_from_json_line(json)
      assert %Entries.ThinkingLevelChange{} = entry
      assert is_nil(entry.thinking_level)
    end

    test "deserializes a Compaction with empty replaces_entry_ids" do
      json =
        ~s({"id":"c1","parent_id":null,"timestamp":5.0,"type":"compaction","summary":"summary","replaces_entry_ids":[]})

      entry = Jsonl.entry_from_json_line(json)
      assert %Entries.Compaction{} = entry
      assert entry.replaces_entry_ids == []
    end

    test "deserializes a Compaction with missing replaces_entry_ids defaults to []" do
      json =
        ~s({"id":"c1","parent_id":null,"timestamp":5.0,"type":"compaction","summary":"summary"})

      entry = Jsonl.entry_from_json_line(json)
      assert %Entries.Compaction{} = entry
      assert entry.replaces_entry_ids == []
    end

    test "deserializes a BranchSummary" do
      json =
        ~s({"id":"bs1","parent_id":"p2","timestamp":6.0,"type":"branch_summary","summary":"branch","branch_root_id":"root1"})

      entry = Jsonl.entry_from_json_line(json)
      assert %Entries.BranchSummary{} = entry
      assert entry.branch_root_id == "root1"
    end

    test "deserializes a Label" do
      json = ~s({"id":"l1","parent_id":null,"timestamp":7.0,"type":"label","label":"important"})
      entry = Jsonl.entry_from_json_line(json)
      assert %Entries.Label{} = entry
      assert entry.label == "important"
    end

    test "deserializes a Leaf with nil entry_id" do
      json = ~s({"id":"lf1","parent_id":null,"timestamp":8.0,"type":"leaf","entry_id":null})
      entry = Jsonl.entry_from_json_line(json)
      assert %Entries.Leaf{} = entry
      assert is_nil(entry.entry_id)
    end

    test "deserializes a SessionInfo" do
      json =
        ~s({"id":"si1","parent_id":null,"timestamp":9.0,"type":"session_info","cwd":"/tmp","title":null})

      entry = Jsonl.entry_from_json_line(json)
      assert %Entries.SessionInfo{} = entry
      assert entry.cwd == "/tmp"
      assert is_nil(entry.title)
    end

    test "deserializes a Custom with non-empty data" do
      json =
        ~s({"id":"cu1","parent_id":null,"timestamp":10.0,"type":"custom","namespace":"ns","data":{"k":"v"}})

      entry = Jsonl.entry_from_json_line(json)
      assert %Entries.Custom{} = entry
      assert entry.namespace == "ns"
      assert entry.data == %{"k" => "v"}
    end

    test "deserializes a Custom with missing data defaults to empty map" do
      json = ~s({"id":"cu1","parent_id":null,"timestamp":10.0,"type":"custom","namespace":"ns"})
      entry = Jsonl.entry_from_json_line(json)
      assert %Entries.Custom{} = entry
      assert entry.data == %{}
    end

    test "includes line number in error message" do
      assert_raise Jsonl.SessionJsonlError, ~r/on line 42/, fn ->
        Jsonl.entry_from_json_line("not json", 42)
      end
    end

    test "omits line number when not provided" do
      assert_raise Jsonl.SessionJsonlError, fn ->
        Jsonl.entry_from_json_line("not json")
      end

      refute_received {:line, _}
    end

    test "raises for unknown entry type" do
      json = ~s({"id":"x","parent_id":null,"timestamp":1.0,"type":"bogus"})

      assert_raise Jsonl.SessionJsonlError, ~r/unknown entry type/, fn ->
        Jsonl.entry_from_json_line(json)
      end
    end

    test "raises for missing type field" do
      json = ~s({"id":"x","parent_id":null,"timestamp":1.0})

      assert_raise Jsonl.SessionJsonlError, ~r/missing.*type/, fn ->
        Jsonl.entry_from_json_line(json)
      end
    end

    test "raises for malformed JSON" do
      assert_raise Jsonl.SessionJsonlError, ~r/Invalid session entry/, fn ->
        Jsonl.entry_from_json_line("{bad json")
      end
    end
  end

  describe "entries_from_json_lines/1" do
    test "deserializes multiple entries" do
      line1 =
        ~s({"id":"a","parent_id":null,"timestamp":1.0,"type":"model_change","model":"gpt-4"})

      line2 = ~s({"id":"b","parent_id":null,"timestamp":2.0,"type":"label","label":"test"})

      entries = Jsonl.entries_from_json_lines([line1, line2])
      assert length(entries) == 2
      assert %Entries.ModelChange{model: "gpt-4"} = Enum.at(entries, 0)
      assert %Entries.Label{label: "test"} = Enum.at(entries, 1)
    end

    test "skips blank lines" do
      line1 = ~s({"id":"a","parent_id":null,"timestamp":1.0,"type":"label","label":"a"})
      line2 = ~s({"id":"b","parent_id":null,"timestamp":2.0,"type":"label","label":"b"})

      entries = Jsonl.entries_from_json_lines(["", line1, "  ", "\n", line2])
      assert length(entries) == 2
    end

    test "returns empty list for all-blank input" do
      assert Jsonl.entries_from_json_lines(["", "  ", "\n"]) == []
    end

    test "returns empty list for empty input" do
      assert Jsonl.entries_from_json_lines([]) == []
    end

    test "reports correct line number on error" do
      lines = [
        ~s({"id":"a","parent_id":null,"timestamp":1.0,"type":"label","label":"ok"}),
        "bad json"
      ]

      assert_raise Jsonl.SessionJsonlError, ~r/on line 2/, fn ->
        Jsonl.entries_from_json_lines(lines)
      end
    end

    test "line numbers skip blank lines" do
      lines = [
        "",
        "bad json"
      ]

      assert_raise Jsonl.SessionJsonlError, ~r/on line 2/, fn ->
        Jsonl.entries_from_json_lines(lines)
      end
    end
  end

  describe "round-trip" do
    test "ModelChange survives encode then decode" do
      entry = %Entries.ModelChange{
        id: "abc",
        parent_id: "p1",
        timestamp: 1.5,
        type: "model_change",
        model: "gpt-4"
      }

      assert round_trip(entry).model == "gpt-4"
    end

    test "Message with tool call survives encode then decode" do
      tc = %ToolCall{id: "tc1", name: "bash", arguments: %{"cmd" => "ls"}}
      msg = %Messages.AssistantMessage{role: "assistant", content: "running", tool_calls: [tc]}

      entry = %Entries.Message{
        id: "msg1",
        parent_id: "root",
        timestamp: 2.0,
        type: "message",
        message: msg
      }

      result = round_trip(entry)
      assert result.message.content == "running"
      assert Enum.count(result.message.tool_calls) == 1
    end

    test "ThinkingLevelChange survives encode then decode" do
      entry = %Entries.ThinkingLevelChange{
        id: "tl",
        parent_id: nil,
        timestamp: 3.0,
        type: "thinking_level_change",
        thinking_level: nil
      }

      assert is_nil(round_trip(entry).thinking_level)
    end

    test "Compaction survives encode then decode" do
      entry = %Entries.Compaction{
        id: "c",
        parent_id: nil,
        timestamp: 4.0,
        type: "compaction",
        summary: "sum",
        replaces_entry_ids: ["e1", "e2"]
      }

      result = round_trip(entry)
      assert result.summary == "sum"
      assert result.replaces_entry_ids == ["e1", "e2"]
    end

    test "BranchSummary survives encode then decode" do
      entry = %Entries.BranchSummary{
        id: "bs",
        parent_id: "p",
        timestamp: 5.0,
        type: "branch_summary",
        summary: "branch",
        branch_root_id: nil
      }

      assert is_nil(round_trip(entry).branch_root_id)
    end

    test "Label survives encode then decode" do
      entry = %Entries.Label{
        id: "l",
        parent_id: nil,
        timestamp: 6.0,
        type: "label",
        label: "urgent"
      }

      assert round_trip(entry).label == "urgent"
    end

    test "Leaf survives encode then decode" do
      entry = %Entries.Leaf{
        id: "lf",
        parent_id: nil,
        timestamp: 7.0,
        type: "leaf",
        entry_id: "e1"
      }

      assert round_trip(entry).entry_id == "e1"
    end

    test "SessionInfo survives encode then decode" do
      entry = %Entries.SessionInfo{
        id: "si",
        parent_id: nil,
        timestamp: 8.0,
        type: "session_info",
        cwd: "/app",
        title: "test"
      }

      result = round_trip(entry)
      assert result.cwd == "/app"
      assert result.title == "test"
    end

    test "Custom survives encode then decode" do
      entry = %Entries.Custom{
        id: "cu",
        parent_id: nil,
        timestamp: 9.0,
        type: "custom",
        namespace: "ns",
        data: %{"a" => 1, "b" => %{"c" => 2}}
      }

      result = round_trip(entry)
      assert result.namespace == "ns"
      assert result.data == %{"a" => 1, "b" => %{"c" => 2}}
    end

    test "idempotent: encode twice yields same line" do
      entry = %Entries.ModelChange{
        id: "abc",
        parent_id: nil,
        timestamp: 1.0,
        type: "model_change",
        model: "gpt-4"
      }

      line = Jsonl.entry_to_json_line(entry)
      assert Jsonl.entry_to_json_line(round_trip(entry)) == line
    end
  end

  defp round_trip(entry) do
    entry |> Jsonl.entry_to_json_line() |> Jsonl.entry_from_json_line()
  end
end
