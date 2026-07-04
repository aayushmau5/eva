defmodule Eva.AI.StreamState do
  alias Eva.AI.Sse
  alias Eva.Agent.Tools.ToolCall

  defstruct content_rev: [], finish_reason: nil, buffer: "", status: nil, tool_calls: %{}

  def feed(%__MODULE__{status: s} = state, _data) when s != nil and s >= 400 do
    {state, []}
  end

  def feed(state, data) do
    full_text = state.buffer <> data
    lines = String.split(full_text, "\n")

    results =
      Enum.reduce(
        lines,
        {state.content_rev, state.finish_reason, [], state.tool_calls},
        fn
          "data: " <> _ = line, acc ->
            case parse_line(line) do
              {:ok, result} -> fold_parsed(result, acc)
              _ -> acc
            end

          _, acc ->
            acc
        end
      )

    {content_rev, finish_reason, events, tools} = results

    buffer = List.last(lines) || ""

    {%{
       state
       | content_rev: content_rev,
         finish_reason: finish_reason,
         buffer: buffer,
         tool_calls: tools
     }, events}
  end

  defp parse_line(line) do
    case Sse.parse(line) do
      :done -> {:ok, :done}
      {:line, json} -> {:ok, Sse.parse_delta(json)}
    end
  rescue
    _ -> :error
  end

  defp fold_parsed(:done, acc), do: acc

  defp fold_parsed(delta, {content_rev, finish_reason, events, tools}) do
    fr = delta.finish_reason || finish_reason

    {cr, events} =
      if is_binary(delta.content) and delta.content != "" do
        {[delta.content | content_rev], [{:content, delta.content} | events]}
      else
        {content_rev, events}
      end

    events =
      if is_binary(delta.thinking) and delta.thinking != "" do
        [{:thinking, delta.thinking} | events]
      else
        events
      end

    tools =
      case delta.tool_calls do
        deltas when is_list(deltas) and deltas != [] ->
          merge_tool_calls(tools, deltas)

        _ ->
          tools
      end

    {cr, fr, events, tools}
  end

  defp merge_tool_calls(builders, tool_calls) do
    Enum.reduce(tool_calls, builders, fn tool_call, acc ->
      idx = tool_call["index"] || 0

      # Elixir typesystem was picking this up a dynamic() so pattern matching on the type
      %ToolCall{} =
      current = Map.get(acc, idx, %ToolCall{id: "tool-call-#{idx}", name: nil, arguments: ""})

      func = tool_call["function"]

      current = %ToolCall{
        current
        | id: pick_string(tool_call["id"], current.id),
          name: pick_string(is_map(func) && func["name"], current.name),
          arguments: current.arguments <> with_string(is_map(func) && func["arguments"])
      }

      Map.put(acc, idx, current)
    end)
  end

  defp pick_string(val, _default) when is_binary(val), do: val
  defp pick_string(_, default), do: default

  defp with_string(val) when is_binary(val), do: val
  defp with_string(_), do: ""

  def build_tool_calls(tool_calls) do
    tool_calls
    |> Enum.sort_by(fn {idx, _} -> idx end)
    |> Enum.map(fn {_idx, %ToolCall{} = tc} ->
      %ToolCall{
        tc
        | arguments: decode_arguments(tc.arguments)
      }
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
