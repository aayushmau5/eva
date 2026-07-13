defprotocol Eva.Agent.Session.Storage do
  @moduledoc """
  Behaviours for storage backends.
  """
  @spec append(t, entry :: Eva.Agent.Session.Entries.t()) :: :ok
  def append(t, entry)

  @spec read_all(t) :: [Eva.Agent.Session.Entries.t()]
  def read_all(t)
end

# JSONL storage

defmodule Eva.Agent.Session.Storage.Jsonl do
  @moduledoc """
  JSONL storage for entries.
  """
  use TypedStruct

  alias Eva.Agent.Session.Jsonl

  typedstruct do
    field :path, String.t(), enforce: true
  end

  @spec new(path :: String.t()) :: t()
  def new(path) when is_binary(path) do
    %__MODULE__{path: path}
  end
end

defimpl Eva.Agent.Session.Storage, for: Eva.Agent.Session.Storage.Jsonl do
  alias Eva.Agent.Session.Jsonl

  def append(%Eva.Agent.Session.Storage.Jsonl{path: path}, entry) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, Jsonl.entry_to_json_line(entry), [:append])
  end

  def read_all(%Eva.Agent.Session.Storage.Jsonl{path: path}) do
    if File.exists?(path) do
      path |> File.read!() |> String.split("\n") |> Jsonl.entries_from_json_lines()
    else
      []
    end
  end
end
