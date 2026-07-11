defmodule Eva.Coding.SessionIndexManagerTest do
  use ExUnit.Case

  alias Eva.Coding.SessionIndexManager, as: Manager
  alias Eva.Coding.Paths
  alias Eva.Agent.Session.Entries.SessionIndexEntry

  @tmp_root Path.expand("tmp/test")

  setup do
    tmp =
      @tmp_root
      |> Path.join("#{System.unique_integer([:positive, :monotonic])}")
      |> tap(&File.mkdir_p!/1)

    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  defp new_manager(tmp) do
    %Manager{paths: %Paths{home: tmp}}
  end

  defp write_index_file(path, entries) when is_list(entries) do
    path |> Path.dirname() |> File.mkdir_p!()

    content =
      Enum.map(entries, &JSON.encode!(&1))
      |> Enum.join("\n")
      |> Kernel.<>("\n")

    File.write!(path, content)
  end

  describe "list_sessions/2" do
    test "returns empty list when no sessions exist", %{tmp: tmp} do
      manager = new_manager(tmp)
      assert Manager.list_sessions(manager) == []
    end

    test "returns all sessions sorted by updated_at desc", %{tmp: tmp} do
      manager = new_manager(tmp)

      proj_a_dir = Path.join([tmp, "sessions", "proj-a-abc123"])
      proj_b_dir = Path.join([tmp, "sessions", "proj-b-def456"])
      File.mkdir_p!(proj_a_dir)
      File.mkdir_p!(proj_b_dir)

      entry1 = %{
        id: "s1",
        session_path: "#{proj_a_dir}/s1.jsonl",
        cwd: "/proj/a",
        model: "gpt-4",
        created_at: 1.0,
        updated_at: 3.0
      }

      entry2 = %{
        id: "s2",
        session_path: "#{proj_b_dir}/s2.jsonl",
        cwd: "/proj/b",
        model: "gpt-4",
        created_at: 2.0,
        updated_at: 5.0
      }

      entry3 = %{
        id: "s3",
        session_path: "#{proj_a_dir}/s3.jsonl",
        cwd: "/proj/a",
        model: "gpt-4",
        created_at: 3.0,
        updated_at: 1.0
      }

      write_index_file(Path.join(proj_a_dir, "index.jsonl"), [entry1, entry3])
      write_index_file(Path.join(proj_b_dir, "index.jsonl"), [entry2])

      sessions = Manager.list_sessions(manager)
      assert length(sessions) == 3
      assert Enum.map(sessions, & &1.id) == ["s2", "s1", "s3"]
    end

    test "filters by cwd when provided", %{tmp: tmp} do
      manager = new_manager(tmp)

      cwd = Path.expand("~/some-project")
      proj_dir = Paths.project_session_dir(manager.paths, cwd)
      File.mkdir_p!(proj_dir)

      entry = %{
        id: "s1",
        session_path: "#{proj_dir}/s1.jsonl",
        cwd: cwd,
        model: "gpt-4",
        created_at: 1.0,
        updated_at: 1.0
      }

      write_index_file(Path.join(proj_dir, "index.jsonl"), [entry])

      sessions = Manager.list_sessions(manager, cwd)
      assert [%SessionIndexEntry{id: "s1"}] = sessions
    end
  end

  describe "get_session/2" do
    test "returns nil when session not found", %{tmp: tmp} do
      manager = new_manager(tmp)
      assert is_nil(Manager.get_session(manager, "nonexistent"))
    end

    test "returns the session entry when found", %{tmp: tmp} do
      manager = new_manager(tmp)

      cwd = "/home/user/project"
      proj_dir = Paths.project_session_dir(manager.paths, cwd)
      File.mkdir_p!(proj_dir)

      entry_data = %{
        id: "my-session",
        session_path: "#{proj_dir}/my-session.jsonl",
        cwd: cwd,
        model: "gpt-4",
        created_at: 10.0,
        updated_at: 10.0
      }

      write_index_file(Path.join(proj_dir, "index.jsonl"), [entry_data])

      assert %SessionIndexEntry{id: "my-session", model: "gpt-4"} =
               Manager.get_session(manager, "my-session")
    end
  end

  describe "latest_session_for_cwd/2" do
    test "returns nil when no sessions exist for cwd", %{tmp: tmp} do
      manager = new_manager(tmp)
      assert is_nil(Manager.latest_session_for_cwd(manager, "/some/cwd"))
    end

    test "returns the session with highest updated_at", %{tmp: tmp} do
      manager = new_manager(tmp)

      cwd = "/home/user/project"
      proj_dir = Paths.project_session_dir(manager.paths, cwd)
      File.mkdir_p!(proj_dir)

      entry1 = %{
        id: "old",
        session_path: "#{proj_dir}/old.jsonl",
        cwd: cwd,
        model: "gpt-4",
        created_at: 1.0,
        updated_at: 1.0
      }

      entry2 = %{
        id: "new",
        session_path: "#{proj_dir}/new.jsonl",
        cwd: cwd,
        model: "gpt-4",
        created_at: 2.0,
        updated_at: 5.0
      }

      entry3 = %{
        id: "mid",
        session_path: "#{proj_dir}/mid.jsonl",
        cwd: cwd,
        model: "gpt-4",
        created_at: 3.0,
        updated_at: 3.0
      }

      write_index_file(Path.join(proj_dir, "index.jsonl"), [entry1, entry2, entry3])

      assert %SessionIndexEntry{id: "new"} = Manager.latest_session_for_cwd(manager, cwd)
    end
  end

  describe "get_or_create_default_session/4" do
    test "creates a new default session when none exists", %{tmp: tmp} do
      manager = new_manager(tmp)
      cwd = "/home/user/my-project"

      entry = Manager.get_or_create_default_session(manager, cwd, "gpt-4", "openai")

      assert entry.model == "gpt-4"
      assert entry.provider_name == "openai"
      assert entry.title == "Default session"
      assert entry.cwd == Path.expand(cwd)
      assert String.starts_with?(entry.id, "default-")
      assert String.ends_with?(entry.session_path, "default.jsonl")

      # Verify persisted
      refute is_nil(Manager.get_session(manager, entry.id))
    end

    test "returns existing default session when already created", %{tmp: tmp} do
      manager = new_manager(tmp)
      cwd = "/home/user/my-project"

      first = Manager.get_or_create_default_session(manager, cwd, "gpt-4", "openai")
      second = Manager.get_or_create_default_session(manager, cwd, "gpt-3", "anthropic")

      assert second.id == first.id
      assert second.model == "gpt-4"
      assert second.provider_name == "openai"
    end

    test "provider_name defaults to nil when not given", %{tmp: tmp} do
      manager = new_manager(tmp)
      cwd = "/home/user/my-project"

      entry = Manager.get_or_create_default_session(manager, cwd, "gpt-4")

      assert is_nil(entry.provider_name)
    end
  end

  describe "touch_session/5" do
    test "returns nil when session not found", %{tmp: tmp} do
      manager = new_manager(tmp)
      assert is_nil(Manager.touch_session(manager, "nonexistent"))
    end

    test "updates updated_at without changing fields when no overrides given", %{tmp: tmp} do
      manager = new_manager(tmp)
      cwd = "/home/user/project"
      proj_dir = Paths.project_session_dir(manager.paths, cwd)
      File.mkdir_p!(proj_dir)

      entry_data = %{
        id: "s1",
        session_path: "#{proj_dir}/s1.jsonl",
        cwd: cwd,
        model: "gpt-4",
        provider_name: "openai",
        title: "Original",
        created_at: 1.0,
        updated_at: 1.0
      }

      write_index_file(Path.join(proj_dir, "index.jsonl"), [entry_data])

      # Sleep briefly to ensure new timestamp differs
      Process.sleep(10)

      updated = Manager.touch_session(manager, "s1")

      assert updated.model == "gpt-4"
      assert updated.provider_name == "openai"
      assert updated.title == "Original"
      assert updated.created_at == 1.0
      assert updated.updated_at > 1.0
    end

    test "updates only the fields that are provided", %{tmp: tmp} do
      manager = new_manager(tmp)
      cwd = "/home/user/project"
      proj_dir = Paths.project_session_dir(manager.paths, cwd)
      File.mkdir_p!(proj_dir)

      entry_data = %{
        id: "s1",
        session_path: "#{proj_dir}/s1.jsonl",
        cwd: cwd,
        model: "gpt-4",
        provider_name: nil,
        title: "Original",
        created_at: 1.0,
        updated_at: 1.0
      }

      write_index_file(Path.join(proj_dir, "index.jsonl"), [entry_data])

      Process.sleep(10)

      updated = Manager.touch_session(manager, "s1", "gpt-5", "anthropic", "New title")

      assert updated.model == "gpt-5"
      assert updated.provider_name == "anthropic"
      assert updated.title == "New title"
      assert updated.updated_at > 1.0
    end

    test "does not overwrite with empty string for model", %{tmp: tmp} do
      manager = new_manager(tmp)
      cwd = "/home/user/project"
      proj_dir = Paths.project_session_dir(manager.paths, cwd)
      File.mkdir_p!(proj_dir)

      entry_data = %{
        id: "s1",
        session_path: "#{proj_dir}/s1.jsonl",
        cwd: cwd,
        model: "gpt-4",
        provider_name: nil,
        title: "Original",
        created_at: 1.0,
        updated_at: 1.0
      }

      write_index_file(Path.join(proj_dir, "index.jsonl"), [entry_data])

      updated = Manager.touch_session(manager, "s1", "")

      assert updated.model == "gpt-4"
    end

    test "persists the updated entry", %{tmp: tmp} do
      manager = new_manager(tmp)
      cwd = "/home/user/project"
      proj_dir = Paths.project_session_dir(manager.paths, cwd)
      File.mkdir_p!(proj_dir)

      entry_data = %{
        id: "s1",
        session_path: "#{proj_dir}/s1.jsonl",
        cwd: cwd,
        model: "gpt-4",
        provider_name: nil,
        title: "Original",
        created_at: 1.0,
        updated_at: 1.0
      }

      write_index_file(Path.join(proj_dir, "index.jsonl"), [entry_data])

      Manager.touch_session(manager, "s1", "gpt-5")

      reloaded = Manager.get_session(manager, "s1")
      assert reloaded.model == "gpt-5"
    end
  end

  describe "create_index/2" do
    test "creates and persists a new session entry", %{tmp: tmp} do
      manager = new_manager(tmp)
      cwd = Path.expand("~/create-index-test")

      entry = Manager.create_index(manager, %{cwd: cwd, model: "gpt-4", title: "My session"})

      assert entry.model == "gpt-4"
      assert entry.title == "My session"
      assert entry.cwd == cwd
      assert String.ends_with?(entry.session_path, ".jsonl")
      assert File.dir?(Path.dirname(entry.session_path))

      # Verify persisted
      sessions = Manager.list_sessions(manager, cwd)
      assert length(sessions) == 1
      assert hd(sessions).id == entry.id
    end

    test "accepts optional session_id", %{tmp: tmp} do
      manager = new_manager(tmp)
      cwd = "/home/user/custom-id-test"

      entry = Manager.create_index(manager, %{cwd: cwd, model: "gpt-4", session_id: "custom-id"})

      assert entry.id == "custom-id"
    end
  end

  describe "prepare_index/2" do
    test "creates session directory", %{tmp: tmp} do
      manager = new_manager(tmp)
      cwd = Path.expand("~/prepare-test")

      entry = Manager.prepare_index(manager, %{cwd: cwd, model: "gpt-4"})

      assert entry.cwd == cwd
      assert entry.model == "gpt-4"
      assert File.dir?(Path.dirname(entry.session_path))
    end

    test "generates an id when not provided", %{tmp: tmp} do
      manager = new_manager(tmp)
      cwd = "/home/user/no-id"

      entry = Manager.prepare_index(manager, %{cwd: cwd, model: "gpt-4"})

      assert is_binary(entry.id) and byte_size(entry.id) > 0
    end
  end
end
