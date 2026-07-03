defmodule Eva.AI.SseTest do
  use ExUnit.Case

  alias Eva.AI.Sse

  describe "parse/1" do
    test "returns :done for [DONE] marker" do
      assert Sse.parse("data: [DONE]") == :done
    end

    test "returns {:line, decoded_json} for valid JSON data line" do
      line = ~s(data: {"choices":[{"delta":{"content":"hello"}}]})
      assert {:line, json} = Sse.parse(line)
      assert json["choices"] |> hd() |> get_in(["delta", "content"]) == "hello"
    end
  end

  describe "parse_delta/1" do
    test "extracts content from choices[0].delta.content" do
      chunk = %{
        "choices" => [
          %{
            "delta" => %{"content" => "Hello, world!"},
            "finish_reason" => nil
          }
        ]
      }

      assert Sse.parse_delta(chunk) == %{
               content: "Hello, world!",
               thinking: nil,
               tool_calls: [],
               finish_reason: nil
             }
    end

    test "extracts thinking from reasoning_content" do
      chunk = %{
        "choices" => [
          %{
            "delta" => %{"reasoning_content" => "Let me think..."},
            "finish_reason" => nil
          }
        ]
      }

      assert Sse.parse_delta(chunk).thinking == "Let me think..."
    end

    test "extracts thinking from reasoning field" do
      chunk = %{
        "choices" => [
          %{
            "delta" => %{"reasoning" => "Hmm..."},
            "finish_reason" => nil
          }
        ]
      }

      assert Sse.parse_delta(chunk).thinking == "Hmm..."
    end

    test "extracts thinking from thinking field" do
      chunk = %{
        "choices" => [
          %{
            "delta" => %{"thinking" => "I wonder..."},
            "finish_reason" => nil
          }
        ]
      }

      assert Sse.parse_delta(chunk).thinking == "I wonder..."
    end

    test "prefers reasoning_content over reasoning" do
      chunk = %{
        "choices" => [
          %{
            "delta" => %{
              "reasoning_content" => "deep thought",
              "reasoning" => "shallow thought"
            },
            "finish_reason" => nil
          }
        ]
      }

      assert Sse.parse_delta(chunk).thinking == "deep thought"
    end

    test "extracts finish_reason from choice" do
      chunk = %{
        "choices" => [
          %{
            "delta" => %{},
            "finish_reason" => "stop"
          }
        ]
      }

      assert Sse.parse_delta(chunk).finish_reason == "stop"
    end

    test "extracts tool_calls from delta" do
      tool_call = %{
        "id" => "call_123",
        "type" => "function",
        "function" => %{"name" => "greet", "arguments" => "{}"}
      }

      chunk = %{
        "choices" => [
          %{
            "delta" => %{"tool_calls" => [tool_call]},
            "finish_reason" => nil
          }
        ]
      }

      assert Sse.parse_delta(chunk).tool_calls == [tool_call]
    end

    test "returns defaults when no choices present" do
      chunk = %{"other" => "data"}

      assert Sse.parse_delta(chunk) == %{
               content: nil,
               thinking: nil,
               tool_calls: [],
               finish_reason: nil
             }
    end

    test "returns defaults when choices is empty list" do
      chunk = %{"choices" => []}

      assert Sse.parse_delta(chunk) == %{
               content: nil,
               thinking: nil,
               tool_calls: [],
               finish_reason: nil
             }
    end

    test "returns defaults for empty delta" do
      chunk = %{
        "choices" => [
          %{
            "delta" => %{},
            "finish_reason" => nil
          }
        ]
      }

      assert Sse.parse_delta(chunk) == %{
               content: nil,
               thinking: nil,
               tool_calls: [],
               finish_reason: nil
             }
    end
  end
end
