defmodule Eva.Agent.Utils do
  def new_entry_id() do
    UUID.uuid4(:hex)
  end

  def timestamp() do
    System.os_time(:millisecond) / 1000
  end

  def to_atom_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {String.to_existing_atom(k), v} end)
  end
end
