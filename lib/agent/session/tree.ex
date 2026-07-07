defmodule Eva.Agent.Session.Tree do
  def entries_by_id(entries) do
    Enum.reduce(entries, %{}, fn entry, map ->
      if Map.has_key?(map, entry.id) do
        raise "Duplicate session entry id: #{entry.id}"
      end

      Map.put(map, entry.id, entry)
    end)
  end

  @doc """
  JSONL is append-only log.
  It can have entries with branching.
  Example:
  ```
    %Entries.Session{id: 1, parent_id: nil}
    %Entries.ModelChange{id: 2, parent_id: 1}
    %Entries.Message{id: 3, parent_id: 2}
    %Entries.Message{id: 4, parent_id: 2} <- Fork
  ```

  Two branches diverge from entry 2.
  Leaf entry(leaf_id) mark which node is currently the tip.
  Given a leaf id, walk parent pointers back to the root(only entries on the branch; skipping other branches).
  """
  def path_to_entry(entries, leaf_id) do
    by_id = entries_by_id(entries)
    path = walk_up(by_id, leaf_id, MapSet.new(), [])
    Enum.reverse(path)
  end

  defp walk_up(_by_id, nil, _seen, path), do: path

  defp walk_up(by_id, current_id, seen, path) do
    if MapSet.member?(seen, current_id) do
      raise "Cycle detected at session entry: #{current_id}"
    end

    entry = Map.fetch!(by_id, current_id)
    walk_up(by_id, entry.parent_id, MapSet.put(seen, current_id), [entry | path])
  end
end
