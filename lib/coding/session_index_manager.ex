defmodule Eva.Coding.SessionIndexManager do
  @moduledoc """
  User-home session management for Eva coding sessions

  ```
  ~/.eva/sessions/
    myrepo-a3f2b1/
      index.jsonl          ← all session records for this project
      default.jsonl        ← the default session
      abc123def.jsonl      ← a named/id session
    another-project-7e8c9d/
      index.jsonl
      ...
  ```
  """

  use TypedStruct

  alias Eva.Coding.Paths, as: EvaPaths
  alias Eva.Agent.Session.Entries.SessionIndexEntry
  alias Eva.Agent.Utils

  typedstruct do
    field :paths, EvaPaths.t(), default: %EvaPaths{}
  end

  # -- Public --

  @spec list_sessions(t(), cwd :: String.t() | nil) :: [SessionIndexEntry.t()]
  def list_sessions(%__MODULE__{} = manager, cwd \\ nil) do
    if is_nil(cwd) do
      read_all_indexes(manager)
    else
      read_project_index(manager, cwd)
    end
    |> Enum.sort_by(& &1.updated_at, :desc)
  end

  @spec get_session(t(), session_id :: String.t()) :: SessionIndexEntry.t() | nil
  def get_session(%__MODULE__{} = manager, session_id) do
    read_all_indexes(manager)
    |> Enum.find(fn index -> index.id == session_id end)
  end

  @spec latest_session_for_cwd(t(), cwd :: String.t()) :: SessionIndexEntry.t() | nil
  def latest_session_for_cwd(%__MODULE__{} = manager, cwd) do
    list_sessions(manager, cwd) |> List.first()
  end

  @spec get_or_create_default_session(
          t(),
          cwd :: String.t(),
          model :: String.t(),
          provider_name :: String.t() | nil
        ) :: SessionIndexEntry.t()
  def get_or_create_default_session(%__MODULE__{} = manager, cwd, model, provider_name \\ nil) do
    resolved_cwd = Path.expand(cwd)
    project_hash = EvaPaths.project_session_dir(manager.paths, resolved_cwd) |> Path.basename()
    session_id = "default-#{project_hash}"

    case get_session(manager, session_id) do
      %SessionIndexEntry{} = existing ->
        existing

      nil ->
        path = EvaPaths.default_session_path(manager.paths, resolved_cwd)

        record =
          SessionIndexEntry.new(%{
            id: session_id,
            session_path: path,
            cwd: resolved_cwd,
            model: model,
            provider_name: provider_name,
            title: "Default session"
          })

        index_session!(manager, record)
        record
    end
  end

  @spec touch_session(
          t(),
          session_id :: String.t(),
          model :: String.t() | nil,
          provider_name :: String.t() | nil,
          title :: String.t() | nil
        ) :: SessionIndexEntry.t() | nil
  def touch_session(
        %__MODULE__{} = manager,
        session_id,
        model \\ nil,
        provider_name \\ nil,
        title \\ nil
      ) do
    case get_session(manager, session_id) do
      nil ->
        nil

      %SessionIndexEntry{} = existing ->
        updated = %SessionIndexEntry{
          existing
          | model: if(model in [nil, ""], do: existing.model, else: model),
            provider_name:
              if(is_nil(provider_name), do: existing.provider_name, else: provider_name),
            title: if(is_nil(title), do: existing.title, else: title),
            updated_at: Utils.timestamp()
        }

        index_session!(manager, updated)
        updated
    end
  end

  @spec prepare_index(t(), attrs :: SessionIndexEntry.attrs()) :: SessionIndexEntry.t()
  def create_index(%__MODULE__{} = manager, attrs) do
    index = prepare_index(manager, attrs)
    index_session!(manager, index)
    index
  end

  @spec prepare_index(t(), attrs :: SessionIndexEntry.attrs()) :: SessionIndexEntry.t()
  def prepare_index(%__MODULE__{} = manager, attrs) do
    cwd = Map.fetch!(attrs, :cwd) |> Path.expand()
    session_id = Map.get(attrs, :session_id, Utils.new_entry_id())

    session_path =
      EvaPaths.project_session_dir(manager.paths, cwd) |> Path.join("#{session_id}.jsonl")

    :ok = File.mkdir_p!(Path.dirname(session_path))

    SessionIndexEntry.new(
      Map.merge(attrs, %{id: session_id, session_path: session_path, cwd: cwd})
    )
  end

  @spec index_session!(t(), entry :: SessionIndexEntry.t()) :: :ok
  def index_session!(%__MODULE__{} = manager, %SessionIndexEntry{} = entry) do
    path = EvaPaths.index_path(manager.paths, entry.cwd)
    index_entries = read_index(path) |> Enum.filter(fn item -> item.id !== entry.id end)
    index_entries = index_entries ++ [entry]
    write_index!(path, index_entries)
  end

  # -- Private --

  @spec read_all_indexes(t()) :: [SessionIndexEntry.t()]
  defp read_all_indexes(%__MODULE__{} = manager) do
    sessions_dir = EvaPaths.sessions_dir(manager.paths)

    Path.wildcard(Path.join([sessions_dir, "*/index.jsonl"]))
    |> Enum.map(&read_index(&1))
    |> List.flatten()
  end

  @spec read_project_index(t(), cwd :: String.t()) :: [SessionIndexEntry.t()]
  defp read_project_index(%__MODULE__{} = manager, cwd) do
    index_path = EvaPaths.index_path(manager.paths, Path.expand(cwd))
    read_index(index_path)
  end

  @spec read_index(path :: String.t()) :: [SessionIndexEntry.t()]
  defp read_index(path) do
    if File.exists?(path) do
      File.stream!(path)
      |> Enum.reduce([], fn line, records ->
        trimmed = String.trim(line)

        if String.length(trimmed) != 0 do
          record = JSON.decode!(trimmed)
          index_entry = struct!(SessionIndexEntry, Utils.to_atom_keys(record))
          [index_entry | records]
        else
          records
        end
      end)
      |> Enum.reverse()
    else
      []
    end
  end

  @spec write_index!(path :: String.t(), entries :: [SessionIndexEntry.t()]) :: :ok
  defp write_index!(path, entries) do
    :ok = File.mkdir_p!(Path.dirname(path))

    content =
      Enum.map(entries, &JSON.encode!(&1))
      |> Enum.join("\n")
      |> Kernel.<>("\n")

    :ok = File.write!(path, content)
  end
end
