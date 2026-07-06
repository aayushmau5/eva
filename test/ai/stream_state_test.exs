defmodule Eva.AI.StreamStateTest do
  use ExUnit.Case

  alias Eva.AI.StreamState
  alias Eva.Agent.Tools.ToolCall

  describe "feed/2" do
    test "accumulates content across multiple data chunks" do
      data =
        "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\ndata: {\"choices\":[{\"delta\":{\"content\":\" World\"}}]}\n"

      {state, events} = StreamState.feed(%StreamState{}, data)

      content_events = Enum.filter(events, fn e -> match?({:content, _}, e) end)
      assert length(content_events) == 2
      assert {:content, "Hello"} in content_events
      assert {:content, " World"} in content_events
      assert state.content_rev == [" World", "Hello"]
    end

    test "accumulates thinking deltas" do
      data =
        "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"Let me think...\"}}]}\ndata: {\"choices\":[{\"delta\":{\"reasoning_content\":\" done.\"}}]}\n"

      {_state, events} = StreamState.feed(%StreamState{}, data)

      thinking_events = Enum.filter(events, fn e -> match?({:thinking, _}, e) end)
      assert length(thinking_events) == 2
      assert {:thinking, "Let me think..."} in thinking_events
      assert {:thinking, " done."} in thinking_events
    end

    test "accumulates tool call deltas across multiple chunks" do
      chunk1 =
        ~s|data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_abc","function":{"name":"get_weather","arguments":"{\\"city\\":\\""}}]}}]}\n|

      chunk2 =
        ~s|data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"NYC\\"}"}}]}}]}\n|

      {state, events} = StreamState.feed(%StreamState{}, chunk1 <> chunk2)

      refute Enum.any?(events, fn e -> match?({:tool_call, _}, e) end)
      assert map_size(state.tool_calls) == 1
      builder = state.tool_calls[0]
      assert builder.id == "call_abc"
      assert builder.name == "get_weather"
      assert builder.arguments == "{\"city\":\"" <> "NYC\"}"
    end

    test "handles multiple tool calls with different indices" do
      data =
        ~s|data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","function":{"name":"fn_a","arguments":"A"}},{"index":1,"id":"call_b","function":{"name":"fn_b","arguments":"B"}}]}}]}\n|

      {state, _events} = StreamState.feed(%StreamState{}, data)

      assert map_size(state.tool_calls) == 2
      assert state.tool_calls[0].name == "fn_a"
      assert state.tool_calls[1].name == "fn_b"
    end

    test "tracks finish_reason" do
      data = ~s|data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n|

      {state, _events} = StreamState.feed(%StreamState{}, data)

      assert state.finish_reason == "stop"
    end

    test "skips non-data lines" do
      data = "event: ping\ndata: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}\n"

      {_state, events} = StreamState.feed(%StreamState{}, data)

      content_events = Enum.filter(events, fn e -> match?({:content, _}, e) end)
      assert length(content_events) == 1
    end

    test "buffers partial lines across feed calls" do
      {state1, events1} = StreamState.feed(%StreamState{}, "data: {\"ch")
      assert events1 == []
      assert state1.buffer == "data: {\"ch"

      {_state2, events2} =
        StreamState.feed(state1, "oices\":[{\"delta\":{\"content\":\"hi\"}}]}\n")

      content_events = Enum.filter(events2, fn e -> match?({:content, _}, e) end)
      assert length(content_events) == 1
      assert {:content, "hi"} in content_events
    end

    test "returns no events when status is already error" do
      state = %StreamState{status: 500}

      {returned_state, events} =
        StreamState.feed(state, "data: {\"choices\":[{\"delta\":{\"content\":\"nope\"}}]}\n")

      assert events == []
      assert returned_state.status == 500
    end

    test "handles tool call missing index (defaults to 0)" do
      data =
        ~s|data: {"choices":[{"delta":{"tool_calls":[{"id":"no_index","function":{"name":"f","arguments":"{}"}}]}}]}\n|

      {state, _events} = StreamState.feed(%StreamState{}, data)

      assert map_size(state.tool_calls) == 1
      assert state.tool_calls[0].id == "no_index"
    end

    test "handles tool call delta with no function field" do
      data = ~s|data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_x"}]}}]}\n|

      {state, _events} = StreamState.feed(%StreamState{}, data)

      builder = state.tool_calls[0]
      assert builder.id == "call_x"
      assert builder.name == nil
      assert builder.arguments == ""
    end
  end

  describe "build_tool_calls/1" do
    test "builds ToolCall structs from accumulated builders, sorted by index" do
      builders = %{
        1 => %ToolCall{id: "call_b", name: "second", arguments: ~s({"b":2})},
        0 => %ToolCall{id: "call_a", name: "first", arguments: ~s({"a":1})}
      }

      [tc_a, tc_b] = StreamState.build_tool_calls(builders)

      assert %ToolCall{id: "call_a", name: "first", arguments: %{"a" => 1}} = tc_a
      assert %ToolCall{id: "call_b", name: "second", arguments: %{"b" => 2}} = tc_b
    end

    test "auto-generates id when nil" do
      builders = %{0 => %ToolCall{id: "tool-call-0", name: "greet", arguments: "{}"}}

      [tc] = StreamState.build_tool_calls(builders)

      assert %ToolCall{id: "tool-call-0", name: "greet"} = tc
    end

    test "stores raw arguments when JSON parse fails" do
      builders = %{0 => %ToolCall{id: "call_1", name: "bad", arguments: "not json"}}

      [tc] = StreamState.build_tool_calls(builders)

      assert tc.arguments == %{"_raw_arguments" => "not json"}
    end

    test "returns empty arguments map for empty string" do
      builders = %{0 => %ToolCall{id: "call_x", name: "no_args", arguments: ""}}

      [tc] = StreamState.build_tool_calls(builders)

      assert tc.arguments == %{}
    end

    test "returns empty list for empty builders" do
      assert StreamState.build_tool_calls(%{}) == []
    end
  end

  describe "full streaming integration" do
    test "content, thinking, and tool calls together produce correct state and events" do
      data =
        "data: {\"choices\":[{\"delta\":{\"content\":\"Let me check\"}}]}\n" <>
          ~s|data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"weather","arguments":"{\\"city\\":\\""}}]}}]}\n| <>
          ~s|data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"NYC\\"}"}}]}}]}\n| <>
          "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"thinking...\"}}]}\n" <>
          "data: {\"choices\":[{\"delta\":{\"content\":\" weather\"}}]}\n" <>
          ~s|data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}\n|

      {state, events} = StreamState.feed(%StreamState{}, data)

      content_events = Enum.filter(events, fn e -> match?({:content, _}, e) end)
      thinking_events = Enum.filter(events, fn e -> match?({:thinking, _}, e) end)

      assert length(content_events) == 2
      assert {:content, "Let me check"} in content_events
      assert {:content, " weather"} in content_events

      assert length(thinking_events) == 1
      assert {:thinking, "thinking..."} in thinking_events

      assert state.finish_reason == "tool_calls"
      assert map_size(state.tool_calls) == 1

      [tc] = StreamState.build_tool_calls(state.tool_calls)
      assert %ToolCall{id: "call_1", name: "weather", arguments: %{"city" => "NYC"}} = tc
    end
  end
end
