defmodule Eva.Agent.Session.Storage do
  alias Eva.Agent.Session.Jsonl

  defstruct [:path]

  def new(path) when is_binary(path) do
    %__MODULE__{path: path}
  end

  def append(%__MODULE__{path: path}, entry) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, Jsonl.entry_to_json_line(entry), [:append])
  end

  def read_all(%__MODULE__{path: path}) do
    if File.exists?(path) do
      path |> File.read!() |> String.split("\n") |> Jsonl.entries_from_json_lines()
    else
      []
    end
  end
end
