defmodule Eva.Agent.Session.Jsonl do
  @moduledoc "JSONL serialization helpers for session entries."

  alias Eva.Agent.Session.Entries

  defmodule SessionJsonlError, do: defexception([:message])

  def entry_to_json_line(entry) do
    JSON.encode!(entry) <> "\n"
  end

  def entry_from_json_line(line, line_number \\ nil) do
    try do
      line |> JSON.decode!() |> Entries.from_json_map()
    rescue
      e ->
        loc = location_suffix(line_number)

        reraise SessionJsonlError,
                [message: "Invalid session entry#{loc}: #{Exception.message(e)}"],
                __STACKTRACE__
    end
  end

  def entries_from_json_lines(lines) do
    lines
    |> Stream.with_index(1)
    |> Stream.reject(fn {l, _idx} -> String.trim(l) == "" end)
    |> Enum.map(fn {line, idx} -> entry_from_json_line(line, idx) end)
  end

  defp location_suffix(nil), do: ""
  defp location_suffix(n), do: " on line #{n}"
end
