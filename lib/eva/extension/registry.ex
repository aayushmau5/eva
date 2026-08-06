defmodule Eva.Extension.Registry do
  @moduledoc """
  The list of project extensions, written by `mix eva.ext.*` and read at session start.

  A script is discovered by scanning a directory; a project is *registered*. Adding one is
  an explicit command, which is also its trust model — nothing here is picked up by
  cloning a repository.

  > Not to be confused with `Eva.Extension.Processes`, which is an actual `Registry` of
  > running extension processes. This is a JSON file.

  Each entry:

      %{
        "name" => "mcp",
        "kind" => "project",
        "dir" => "/Users/you/.eva/packages/eva_mcp",
        "start" => ["mix", "run", "--no-halt"]
      }

  Four fields, every one of them something a human would have written anyway. Eva does not
  launch extension nodes as part of running — `mix eva.ext.start mcp` does, and that is
  what `start` is for. Everything a previous design needed to *assemble* someone else's VM
  (`ebin`, `lib_dir`, `app`, `core_version`, `built_at`) is gone with it: the node builds
  and starts itself, and says what it is when it announces.
  """

  alias Eva.Coding.Resources

  @store "extensions.json"
  @key "extensions"

  @type entry :: %{String.t() => term()}

  @doc """
  Where the registry lives — a sibling of `mcp.json` and `trust.json`.
  """
  @spec store_path(Resources.t()) :: String.t()
  def store_path(%Resources{root: root}), do: Path.join(root, @store)

  @doc """
  Every registered extension, in the order they were added.
  """
  @spec read(Resources.t()) :: [entry()]
  def read(%Resources{} = resources) do
    with {:ok, binary} <- File.read(store_path(resources)),
         {:ok, %{@key => entries}} when is_list(entries) <- JSON.decode(binary) do
      Enum.filter(entries, &is_map/1)
    else
      _other -> []
    end
  end

  @doc """
  One entry by name.
  """
  @spec fetch(Resources.t(), String.t()) :: {:ok, entry()} | :error
  def fetch(%Resources{} = resources, name) do
    case Enum.find(read(resources), &(&1["name"] == name)) do
      nil -> :error
      entry -> {:ok, entry}
    end
  end

  @doc """
  Adds or replaces an entry, keeping the position of one being replaced.
  """
  @spec put(Resources.t(), entry()) :: :ok | {:error, term()}
  def put(%Resources{} = resources, %{"name" => name} = entry) do
    entries = read(resources)

    entries =
      if Enum.any?(entries, &(&1["name"] == name)) do
        Enum.map(entries, fn existing ->
          if existing["name"] == name, do: entry, else: existing
        end)
      else
        entries ++ [entry]
      end

    write(resources, entries)
  end

  @doc """
  Removes an entry. Removing one that isn't there is not an error.
  """
  @spec delete(Resources.t(), String.t()) :: :ok | {:error, term()}
  def delete(%Resources{} = resources, name) do
    resources
    |> read()
    |> Enum.reject(&(&1["name"] == name))
    |> then(&write(resources, &1))
  end

  # -- Private --

  # Temp-then-rename, like `Trust`: a half-written registry would read as "these
  # extensions do not exist".
  defp write(%Resources{} = resources, entries) do
    path = store_path(resources)
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, :json.format(%{@key => entries})) do
      File.rename(tmp, path)
    end
  end
end
