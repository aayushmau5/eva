defmodule Eva.Coding.ProjectContextTest do
  use ExUnit.Case

  alias Eva.Coding.ProjectContext
  alias Eva.Coding.ProjectContext.ContextFile
  alias Eva.Coding.Resources

  @tmp_root "/tmp/eva_test_project_context"

  setup do
    tmp =
      @tmp_root
      |> Path.join("#{System.unique_integer([:positive, :monotonic])}")
      |> tap(&File.mkdir_p!/1)

    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  defp write_file(dir, filename, content) do
    Path.join(dir, filename)
    |> tap(&File.write!(&1, content))
  end

  describe "ContextFile struct" do
    test "has path and content fields" do
      cf = %ContextFile{path: "/tmp/AGENTS.md", content: "# Hello"}
      assert cf.path == "/tmp/AGENTS.md"
      assert cf.content == "# Hello"
    end
  end

  describe "discover/1" do
    test "returns empty list when no AGENTS.md files exist", %{tmp: tmp} do
      resources = %Resources{root: tmp, agents_root: nil, cwd: nil}
      assert [] = ProjectContext.discover(resources)
    end

    test "discovers AGENTS.md at root", %{tmp: tmp} do
      write_file(tmp, "AGENTS.md", "# Root instructions")
      resources = %Resources{root: tmp, agents_root: nil, cwd: nil}

      path = Path.join(tmp, "AGENTS.md")
      context_files = ProjectContext.discover(resources)

      assert length(context_files) == 1

      assert %ContextFile{content: "# Root instructions", path: ^path} =
               hd(context_files)

      assert String.ends_with?(hd(context_files).path, "AGENTS.md")
    end

    test "discovers AGENTS.md at agents_root", %{tmp: tmp} do
      agents_dir = Path.join(tmp, "shared_agents")
      File.mkdir_p!(agents_dir)
      write_file(agents_dir, "AGENTS.md", "# Agent instructions")

      resources = %Resources{root: tmp, agents_root: agents_dir, cwd: nil}
      context_files = ProjectContext.discover(resources)

      assert length(context_files) == 1
      assert %ContextFile{content: "# Agent instructions"} = hd(context_files)
    end

    test "discovers AGENTS.md at both root and agents_root", %{tmp: tmp} do
      agents_dir = Path.join(tmp, "shared_agents")
      File.mkdir_p!(agents_dir)
      write_file(tmp, "AGENTS.md", "# Root")
      write_file(agents_dir, "AGENTS.md", "# Agents")

      resources = %Resources{root: tmp, agents_root: agents_dir, cwd: nil}
      context_files = ProjectContext.discover(resources)

      assert length(context_files) == 2
      contents = Enum.map(context_files, & &1.content)
      assert "# Root" in contents
      assert "# Agents" in contents
    end

    test "ignores non-regular files like directories named AGENTS.md", %{tmp: tmp} do
      File.mkdir_p!(Path.join(tmp, "AGENTS.md"))

      resources = %Resources{root: tmp, agents_root: nil, cwd: nil}
      assert [] = ProjectContext.discover(resources)
    end

    test "discovers AGENTS.md from cwd project ancestors", %{tmp: tmp} do
      project_root = Path.join(tmp, "my_project")
      File.mkdir_p!(project_root)
      write_file(project_root, "mix.exs", "")
      write_file(project_root, "AGENTS.md", "# Project root")

      lib_dir = Path.join(project_root, "lib")
      File.mkdir_p!(lib_dir)
      write_file(lib_dir, "AGENTS.md", "# Lib layer")

      cwd = Path.join(lib_dir, "eva")
      File.mkdir_p!(cwd)

      resources = %Resources{root: tmp, agents_root: nil, cwd: cwd}
      context_files = ProjectContext.discover(resources)

      assert length(context_files) >= 2
      contents = Enum.map(context_files, & &1.content)
      assert "# Project root" in contents
      assert "# Lib layer" in contents
    end

    test "discovers .eva/AGENTS.md and .agents/AGENTS.md under cwd", %{tmp: tmp} do
      project_root = Path.join(tmp, "my_project")
      File.mkdir_p!(project_root)
      write_file(project_root, "mix.exs", "")
      write_file(project_root, "AGENTS.md", "# Project root")

      cwd = Path.join(project_root, "src")
      File.mkdir_p!(cwd)
      eva_dir = Path.join(cwd, ".eva")
      agents_dir = Path.join(cwd, ".agents")
      File.mkdir_p!(eva_dir)
      File.mkdir_p!(agents_dir)
      write_file(eva_dir, "AGENTS.md", "# CWD .eva")
      write_file(agents_dir, "AGENTS.md", "# CWD .agents")

      resources = %Resources{root: tmp, agents_root: nil, cwd: cwd}
      context_files = ProjectContext.discover(resources)

      contents = Enum.map(context_files, & &1.content)
      assert "# Project root" in contents
      assert "# CWD .eva" in contents
      assert "# CWD .agents" in contents
    end

    test "finds project root by walking up to a marker file", %{tmp: tmp} do
      project_root = Path.join(tmp, "deep_project")
      File.mkdir_p!(project_root)
      write_file(project_root, "package.json", "")

      deep_dir = Path.join([project_root, "src", "lib", "utils"])
      File.mkdir_p!(deep_dir)
      write_file(project_root, "AGENTS.md", "# Top-level")

      resources = %Resources{root: tmp, agents_root: nil, cwd: deep_dir}
      context_files = ProjectContext.discover(resources)

      assert length(context_files) >= 1
      contents = Enum.map(context_files, & &1.content)
      assert "# Top-level" in contents
    end

    test "uses cwd itself as project root when cwd has a marker", %{tmp: tmp} do
      cwd = Path.join(tmp, "standalone")
      File.mkdir_p!(cwd)
      write_file(cwd, "mix.exs", "")
      write_file(cwd, "AGENTS.md", "# Self-contained")

      resources = %Resources{root: tmp, agents_root: nil, cwd: cwd}
      context_files = ProjectContext.discover(resources)

      contents = Enum.map(context_files, & &1.content)
      assert "# Self-contained" in contents
    end

    test "deduplicates AGENTS.md paths", %{tmp: tmp} do
      write_file(tmp, "AGENTS.md", "# Only root")

      resources = %Resources{root: tmp, agents_root: tmp, cwd: nil}
      context_files = ProjectContext.discover(resources)

      assert length(context_files) == 1
      assert %ContextFile{content: "# Only root"} = hd(context_files)
    end

    test "returns empty when cwd has no project markers and no .eva/.agents files", %{tmp: tmp} do
      cwd = Path.join(tmp, "orphan_dir")
      File.mkdir_p!(cwd)

      resources = %Resources{root: tmp, agents_root: nil, cwd: cwd}
      assert [] = ProjectContext.discover(resources)
    end

    test "falls back to cwd AGENTS.md when cwd is outside any project root", %{tmp: tmp} do
      cwd = Path.join(tmp, "no_project")
      File.mkdir_p!(cwd)
      write_file(cwd, "AGENTS.md", "# Standalone dir")

      resources = %Resources{root: tmp, agents_root: nil, cwd: cwd}
      context_files = ProjectContext.discover(resources)

      assert length(context_files) >= 1
      contents = Enum.map(context_files, & &1.content)
      assert "# Standalone dir" in contents
    end
  end

  describe "discover_with_diagnostics/1" do
    test "returns context files and empty diagnostics on success", %{tmp: tmp} do
      write_file(tmp, "AGENTS.md", "# Hello")
      resources = %Resources{root: tmp, agents_root: nil, cwd: nil}

      {context_files, diagnostics} = ProjectContext.discover_with_diagnostics(resources)

      assert length(context_files) == 1
      assert %ContextFile{content: "# Hello"} = hd(context_files)
      assert diagnostics == []
    end

    test "returns empty lists when no AGENTS.md files exist", %{tmp: tmp} do
      resources = %Resources{root: tmp, agents_root: nil, cwd: nil}

      {context_files, diagnostics} = ProjectContext.discover_with_diagnostics(resources)

      assert context_files == []
      assert diagnostics == []
    end

    test "returns diagnostics for files that exist but cannot be read", %{tmp: tmp} do
      agents_md = Path.join(tmp, "AGENTS.md")
      File.write!(agents_md, "# Content")
      File.chmod!(agents_md, 0o000)

      resources = %Resources{root: tmp, agents_root: nil, cwd: nil}

      {context_files, diagnostics} = ProjectContext.discover_with_diagnostics(resources)

      assert context_files == []
      assert length(diagnostics) == 1

      File.chmod!(agents_md, 0o644)
    end

    test "returns context_files in the order they are discovered", %{tmp: tmp} do
      project_root = Path.join(tmp, "proj")
      File.mkdir_p!(project_root)
      write_file(project_root, "mix.exs", "")
      write_file(project_root, "AGENTS.md", "# First")

      cwd = Path.join(project_root, "lib")
      File.mkdir_p!(cwd)
      write_file(cwd, "AGENTS.md", "# Second")

      resources = %Resources{root: tmp, agents_root: nil, cwd: cwd}
      {context_files, diagnostics} = ProjectContext.discover_with_diagnostics(resources)

      assert diagnostics == []

      contents = Enum.map(context_files, & &1.content)
      assert List.first(contents) == "# First"
      assert List.last(contents) == "# Second"
    end
  end
end
