defmodule Eva.MCP.SSE do
  @moduledoc """
  SSE parser for MCP's Streamable HTTP transport.
  """

  @doc """
  Appends `chunk` to `buffer` and extracts every complete event.

  An event is terminated by a blank line. Returns `{id, data}` pairs — `id` is
  `nil` when the event carried none — plus whatever trails the last complete
  event, to be fed back in on the next chunk.
  """
  @spec feed(binary(), binary()) :: {[{String.t() | nil, binary()}], binary()}
  def feed(buffer, chunk) do
    {complete, [remainder]} =
      (buffer <> chunk)
      |> String.split("\n\n")
      |> Enum.split(-1)

    events =
      complete
      |> Enum.map(&parse_event/1)
      |> Enum.reject(&is_nil/1)

    {events, remainder}
  end

  defp parse_event(block) do
    {id, data_lines} =
      block
      |> String.split("\n")
      |> Enum.reduce({nil, []}, &parse_line/2)

    case Enum.reverse(data_lines) do
      [] -> nil
      lines -> {id, Enum.join(lines, "\n")}
    end
  end

  defp parse_line("data:" <> rest, {id, data_lines}) do
    {id, [strip_leading_space(rest) | data_lines]}
  end

  defp parse_line("id:" <> rest, {_id, data_lines}) do
    {strip_leading_space(rest), data_lines}
  end

  # `event:`, `retry:`, `:`-comments, and blank lines carry no MCP-relevant
  # state — ignored rather than special-cased.
  defp parse_line(_line, acc), do: acc

  # Exactly one leading space is part of the field syntax, not the value —
  # `String.trim_leading/1` would also eat real leading whitespace the value
  # is entitled to.
  defp strip_leading_space(" " <> value), do: value
  defp strip_leading_space(value), do: value
end
