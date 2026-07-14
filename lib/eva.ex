defmodule Eva do
  alias Eva.AI.Config, as: ProviderConfig

  alias Eva.Coding.Session, as: CodingSession
  alias Eva.Coding.SessionConfig
  alias Eva.Coding.SessionIndexManager
  alias Eva.Coding.Paths, as: EvaPaths

  def setup(listener_pid \\ nil) do
    cwd = File.cwd!()
    eva_paths = %EvaPaths{}
    session_index_manager = SessionIndexManager.new(eva_paths)
    session_index_entry = SessionIndexManager.prepare_index(session_index_manager, %{cwd: cwd})
    storage = %Eva.Agent.Session.Storage.Jsonl{path: session_index_entry.session_path}
    provider_config = %ProviderConfig{model: "", base_url: "", endpoint: ""}

    session_config = %SessionConfig{
      cwd: cwd,
      storage: storage,
      session_index_manager: session_index_manager,
      provider_config: provider_config,
      session_id: session_index_entry.id,
      listener_pid: listener_pid
    }

    {:ok, coding_session_pid} = CodingSession.start_link(%{config: session_config})
    coding_session_pid
  end
end
