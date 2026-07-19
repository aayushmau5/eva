defmodule Eva.AI.StreamState do
  @moduledoc """
  Streaming SSE parser state for OpenAI-compatible `/chat/completions`
  responses.

  Each `feed/2` call hands in one chunk of raw bytes from Finch and returns
  `{state, deltas}` — the ordered list of parsed deltas from this chunk.

  Whole lines are parsed immediately; a line that arrives split across chunks
  is buffered in `state.buffer` and completed on the next call. Tool-call
  arguments arrive as fragments and are accumulated into builders in
  `state.tool_calls`; call `build_tool_calls/1` at stream end to materialize
  them into `ToolCall` structs.
  """

  alias Eva.AI.Sse
  alias Eva.Agent.Messages.ToolCall

  # TODO: also need to add usage etc.
  defstruct buffer: "",
            finish_reason: nil,
            status: nil,
            tool_calls: %{},
            body_rev: []

  @doc "Feed one chunk of raw SSE bytes; returns `{state, deltas}`."
  def feed(%__MODULE__{status: status} = state, data)
      when status != nil and status >= 400 do
    # HTTP error: collect the raw body for surfacing, no SSE parsing.
    {%{state | body_rev: [data | state.body_rev]}, []}
  end

  def feed(state, data) do
    # data look like this:
    # "data: {...reasoning_content:\"Thinking \"...}\ndata: {...reasoning_content:\"about it\"...}\n
    # data: {...content:\"Hello\"...}\ndata: {...tool_calls:[{index:0,id:\"call_1\",...]..}\n
    # data: {...content:\"partial\"...}"
    #
    #
    # lines are complete lines. Ex. ["data: {....}", "data: {....}"]
    # buffer is incomplete/partial/leftover response(that doesn't have an ending).
    # On next chunk of data, we combine the new data with leftover and then create lines
    {lines, buffer} = split_lines(state.buffer, data)
    state = %{state | buffer: buffer}

    Enum.reduce(lines, {state, []}, fn line, {state, deltas} ->
      case parse_line(line) do
        {:delta, delta} ->
          # `delta` is a map
          #   content: "for common lines",
          #   thinking: "for thinking lines",
          #   tool_calls: "tool calls in the lines",
          #   finish_reason: "response ended, why?"
          #
          # ex(each line is an iteration)>
          #     %{content: "", thinking: "Thinking ", tool_calls: [], finish_reason: nil}
          #     %{content: "", thinking: "about it", tool_calls: [], finish_reason: nil}
          #     %{content: "Hello", thinking: "", tool_calls: [], finish_reason: nil}
          #     %{content: "", thinking: "", tool_calls: ["{index: 0, id:\"call_id\",....}"], finish_reason: nil}
          #
          #
          # apply_delta() iteration:
          #     [%{state}, {:thinking, "Thinking "}]
          #     [%{state}, {:thinking, "about it"}]
          #     [%{state}, {:content, "Hello"}]
          #     [%{tool_calls: %{0 => %ToolCall{id, name, arguments(string that acts like a buffer)}}}, []]
          #
          #
          # Ultimately from the loop:
          #    we get {updated_stream_state, [{:thinking, "Thinking "}, {:thinking, "about it"}, {:content, "Hello"}]}
          {state, line_deltas} = apply_delta(state, delta)
          {state, deltas ++ line_deltas}

        :ignore ->
          {state, deltas}
      end
    end)
  end

  # Split buffered + raw text into complete lines and the trailing fragment
  # that has no `\n` terminator yet — it becomes the new buffer.
  @spec split_lines(String.t(), String.t()) :: {[String.t()], String.t()}
  defp split_lines(buffer, data) do
    # buffer accumulates partial content until another chunk arrives
    parts = String.split(buffer <> data, "\n")
    complete = Enum.drop(parts, -1)
    leftover = List.last(parts)
    {complete, leftover}
  end

  defp parse_line(line) do
    # line => "data: {"reasoning_content":"Thinking "}"
    # After parse: {:line, %{"reasoning_content" => "Thinking "}}
    case Sse.parse(line) do
      :done -> :ignore
      {:line, json} -> {:delta, Sse.parse_delta(json)}
    end
  rescue
    _ -> :ignore
  end

  # Apply one parsed delta: thread `finish_reason` and tool-call builders into
  # the state, and emit `:content` / `:thinking` deltas in arrival order.
  defp apply_delta(state, delta) do
    state = %{state | finish_reason: delta.finish_reason || state.finish_reason}
    state = merge_tool_calls(state, delta.tool_calls)

    deltas =
      [event_if(:content, delta.content), event_if(:thinking, delta.thinking)]
      |> Enum.reject(&is_nil/1)

    {state, deltas}
  end

  defp event_if(_tag, nil), do: nil
  defp event_if(_tag, ""), do: nil
  defp event_if(tag, value) when is_binary(value), do: {tag, value}

  # Merge streamed tool-call fragments into per-index builders. The model
  # emits `id`/`name` once at the start, then shards `arguments` across many
  # deltas; we concatenate the fragments and JSON-decode at the end.
  defp merge_tool_calls(state, deltas) when is_list(deltas) and deltas != [] do
    builders =
      Enum.reduce(deltas, state.tool_calls, fn delta_call, builders ->
        idx = delta_call["index"] || 0
        func = delta_call["function"]

        default = %ToolCall{id: "tool-call-#{idx}", name: nil, arguments: ""}

        # Pin the type via pattern match so the gradual type checker keeps
        # `current` as `%ToolCall{}` (Map.get/3 otherwise widens it to dynamic()).
        %ToolCall{} = current = Map.get(builders, idx, default)

        current = %ToolCall{
          current
          | id: take_string(delta_call["id"]) || current.id,
            name: take_string(func && func["name"]) || current.name,
            arguments: current.arguments <> (take_string(func && func["arguments"]) || "")
        }

        Map.put(builders, idx, current)
      end)

    %{state | tool_calls: builders}
  end

  defp merge_tool_calls(state, _), do: state

  defp take_string(value) when is_binary(value), do: value
  defp take_string(_), do: nil

  @doc """
  Finalize accumulated tool-call builders into `ToolCall` structs, sorted by
  index. Argument JSON is decoded; a parse failure falls back to wrapping the
  raw fragment string in `{"_raw_arguments" => args}`.
  """
  def build_tool_calls(tool_calls) do
    tool_calls
    |> Enum.sort_by(fn {idx, _} -> idx end)
    |> Enum.map(fn {_idx, %ToolCall{} = tc} ->
      %ToolCall{tc | arguments: decode_arguments(tc.arguments)}
    end)
  end

  defp decode_arguments(""), do: %{}

  defp decode_arguments(args) do
    case JSON.decode(args) do
      {:ok, parsed} -> parsed
      _ -> %{"_raw_arguments" => args}
    end
  end
end
