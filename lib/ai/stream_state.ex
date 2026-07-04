defmodule Eva.AI.StreamState do
  alias Eva.AI.Sse

  defstruct content_rev: [], finish_reason: nil, buffer: "", status: nil

  def feed(%__MODULE__{status: s} = state, _data) when s != nil and s >= 400 do
    {state, []}
  end

  def feed(state, data) do
    full_text = state.buffer <> data
    lines = String.split(full_text, "\n")

    results =
      Enum.reduce(lines, {state.content_rev, state.finish_reason, []}, fn
        "data: " <> _ = line, acc ->
          case parse_line(line) do
            {:ok, result} -> fold_parsed(result, acc)
            _ -> acc
          end

        _, acc ->
          acc
      end)

    {content_rev, finish_reason, events} = results

    last = List.last(lines) || ""
    buffer = if String.starts_with?(last, "data:"), do: "", else: last

    {%{state | content_rev: content_rev, finish_reason: finish_reason, buffer: buffer}, events}
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

  defp fold_parsed(delta, {content_rev, finish_reason, events}) do
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

    {cr, fr, events}
  end
end
