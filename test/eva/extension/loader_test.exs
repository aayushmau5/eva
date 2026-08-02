defmodule Eva.Extension.LoaderTest do
  use ExUnit.Case, async: false

  alias Eva.Extension.Loader
  alias Eva.Coding.Resources

  defp tmp_dir do
    path = Path.join(System.tmp_dir!(), "loader_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp write_extension(dir, name, content) do
    path = Path.join(dir, name)
    File.write!(path, content)
    path
  end

  defp valid_extension(uid \\ System.unique_integer([:positive])) do
    ~s'''
    defmodule TestExtension_#{uid} do
      use Eva.Extension

      def setup(_ctx) do
        {:ok, %Eva.Extension.Spec{guidelines: ["test guideline"]}}
      end
    end
    '''
  end

  defp extension_with_no_setup(uid \\ System.unique_integer([:positive])) do
    ~s'''
    defmodule TestBadExtension_#{uid} do
      use Eva.Extension

      def init(_ctx), do: {:ok, nil}
    end
    '''
  end

  defp extension_without_use(uid \\ System.unique_integer([:positive])) do
    ~s'''
    defmodule PlainModule_#{uid} do
      def setup(_ctx), do: {:ok, %{}}
    end
    '''
  end

  defp stateful_extension(uid \\ System.unique_integer([:positive])) do
    ~s'''
    defmodule StatefulTest_#{uid} do
      use Eva.Extension

      def setup(_ctx) do
        {:ok, %Eva.Extension.Spec{
          hooks: [:tool_call],
          event_classes: [:stream]
        }}
      end
    end
    '''
  end

  describe "candidates/2" do
    test "finds .exs files in extensions_dir" do
      tmp = tmp_dir()
      extensions_dir = Path.join(tmp, "extensions")
      File.mkdir_p!(extensions_dir)
      write_extension(extensions_dir, "my_ext.exs", valid_extension())

      resources = %Resources{root: tmp}

      candidates = Loader.candidates(resources)

      assert List.keymember?(candidates, "my_ext", 0)
    end

    test "finds extension.exs inside a subdirectory" do
      tmp = tmp_dir()
      extensions_dir = Path.join(tmp, "extensions")
      ext_dir = Path.join(extensions_dir, "my_package")
      File.mkdir_p!(ext_dir)
      File.write!(Path.join(ext_dir, "extension.exs"), valid_extension())

      resources = %Resources{root: tmp}

      candidates = Loader.candidates(resources)

      assert List.keymember?(candidates, "my_package", 0)
    end

    test "ignores non-.exs files" do
      tmp = tmp_dir()
      extensions_dir = Path.join(tmp, "extensions")
      File.mkdir_p!(extensions_dir)
      File.write!(Path.join(extensions_dir, "README.md"), "# docs")
      File.write!(Path.join(extensions_dir, "script.py"), "print('hello')")

      resources = %Resources{root: tmp}

      candidates = Loader.candidates(resources)

      refute List.keymember?(candidates, "README", 0)
      refute List.keymember?(candidates, "script", 0)
    end

    test "extra_paths arg allows explicit file paths" do
      tmp = tmp_dir()

      write_extension(tmp, "direct.exs", valid_extension())

      resources = %Resources{root: tmp}

      candidates = Loader.candidates(resources, [Path.join(tmp, "direct.exs")])

      assert List.keymember?(candidates, "direct", 0)
    end

    test "extra_paths arg allows directory paths" do
      tmp = tmp_dir()
      ext_dir = Path.join(tmp, "dir_ext")
      File.mkdir_p!(ext_dir)
      File.write!(Path.join(ext_dir, "extension.exs"), valid_extension())

      resources = %Resources{root: tmp}

      candidates = Loader.candidates(resources, [ext_dir])

      assert List.keymember?(candidates, "dir_ext", 0)
    end

    test "deduplicates by name with project beating global" do
      tmp = tmp_dir()
      global_ext = Path.join(tmp, "extensions")
      project_ext = Path.join([tmp, ".eva", "extensions"])
      File.mkdir_p!(global_ext)
      File.mkdir_p!(project_ext)
      write_extension(global_ext, "shared.exs", valid_extension())
      write_extension(project_ext, "shared.exs", valid_extension())

      resources = %Resources{root: tmp}

      candidates = Loader.candidates(resources)

      matched = Enum.filter(candidates, fn {name, _path} -> name == "shared" end)
      assert length(matched) == 1
    end

    test "returns empty list when extensions_dir is missing" do
      tmp = tmp_dir()

      resources = %Resources{root: tmp}

      candidates = Loader.candidates(resources)

      assert candidates == []
    end
  end

  describe "load/1" do
    test "loads a valid extension" do
      tmp = tmp_dir()
      write_extension(tmp, "hello.exs", valid_extension())

      {loaded, diagnostics} = Loader.load([{"hello", Path.join(tmp, "hello.exs")}])

      assert diagnostics == []
      assert length(loaded) == 1
      assert hd(loaded).name == "hello"
      assert is_atom(hd(loaded).module)
    end

    test "reports diagnostic for extension without setup/1" do
      tmp = tmp_dir()
      write_extension(tmp, "bad.exs", extension_with_no_setup())

      {loaded, diagnostics} = Loader.load([{"bad", Path.join(tmp, "bad.exs")}])

      assert loaded == []
      assert length(diagnostics) == 1
      assert String.contains?(hd(diagnostics), "does not export setup/1")
    end

    test "reports diagnostic for module without use Eva.Extension" do
      tmp = tmp_dir()
      write_extension(tmp, "plain.exs", extension_without_use())

      {loaded, diagnostics} = Loader.load([{"plain", Path.join(tmp, "plain.exs")}])

      assert loaded == []
      assert length(diagnostics) == 1
      assert String.contains?(hd(diagnostics), "no module that uses Eva.Extension")
    end

    test "reports diagnostic for file with compile error" do
      tmp = tmp_dir()
      File.write!(Path.join(tmp, "broken.exs"), "{{{" <> valid_extension())

      {loaded, diagnostics} = Loader.load([{"broken", Path.join(tmp, "broken.exs")}])

      assert loaded == []
      assert length(diagnostics) == 1
      assert String.contains?(hd(diagnostics), "failed to compile")
    end

    test "loads a stateful extension" do
      tmp = tmp_dir()
      write_extension(tmp, "stateful.exs", stateful_extension())

      {loaded, diagnostics} = Loader.load([{"stateful", Path.join(tmp, "stateful.exs")}])

      assert diagnostics == []
      assert length(loaded) == 1
      assert is_atom(hd(loaded).module)
    end
  end

  describe "discover/2" do
    test "discovers and loads from resources" do
      tmp = tmp_dir()
      ext_dir = Path.join(tmp, "extensions")
      File.mkdir_p!(ext_dir)
      write_extension(ext_dir, "discoverable.exs", valid_extension())

      resources = %Resources{root: tmp}

      {loaded, diagnostics} = Loader.discover(resources)

      assert diagnostics == []
      assert length(loaded) == 1
      assert hd(loaded).name == "discoverable"
    end
  end

  describe "purge/1" do
    test "unloads modules so they can be reloaded" do
      tmp = tmp_dir()
      path = write_extension(tmp, "purge_test.exs", valid_extension())

      {loaded, _diagnostics} = Loader.load([{"purge_test", path}])
      assert length(loaded) == 1

      mod = hd(loaded).module
      :ok = Loader.purge(loaded)

      refute function_exported?(mod, :setup, 1)
    end
  end
end
