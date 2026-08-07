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

  # An extension's module has to match its name, so the two travel together: the file
  # is `<name>.exs` and the module is `Eva.Extension.<Name>`.
  defp unique(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp module_for(name), do: Eva.Core.Extension.namespace(name)

  defp valid_extension(name) do
    ~s'''
    defmodule #{inspect(module_for(name))} do
      use Eva.Core.Extension

      def setup(_ctx) do
        {:ok, %Eva.Core.Extension.Spec{guidelines: ["test guideline"]}}
      end
    end
    '''
  end

  defp extension_with_no_setup(name) do
    ~s'''
    defmodule #{inspect(module_for(name))} do
      use Eva.Core.Extension

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

  defp stateful_extension(name) do
    ~s'''
    defmodule #{inspect(module_for(name))} do
      use Eva.Core.Extension

      def setup(_ctx) do
        {:ok, %Eva.Core.Extension.Spec{
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
      write_extension(extensions_dir, "my_ext.exs", valid_extension("my_ext"))

      resources = %Resources{root: tmp}

      {candidates, _blocked} = Loader.candidates(resources)

      assert List.keymember?(candidates, "my_ext", 0)
    end

    test "finds extension.exs inside a subdirectory" do
      tmp = tmp_dir()
      extensions_dir = Path.join(tmp, "extensions")
      ext_dir = Path.join(extensions_dir, "my_package")
      File.mkdir_p!(ext_dir)
      File.write!(Path.join(ext_dir, "extension.exs"), valid_extension("my_package"))

      resources = %Resources{root: tmp}

      {candidates, _blocked} = Loader.candidates(resources)

      assert List.keymember?(candidates, "my_package", 0)
    end

    test "ignores non-.exs files" do
      tmp = tmp_dir()
      extensions_dir = Path.join(tmp, "extensions")
      File.mkdir_p!(extensions_dir)
      File.write!(Path.join(extensions_dir, "README.md"), "# docs")
      File.write!(Path.join(extensions_dir, "script.py"), "print('hello')")

      resources = %Resources{root: tmp}

      {candidates, _blocked} = Loader.candidates(resources)

      refute List.keymember?(candidates, "README", 0)
      refute List.keymember?(candidates, "script", 0)
    end

    test "extra_paths arg allows explicit file paths" do
      tmp = tmp_dir()

      write_extension(tmp, "direct.exs", valid_extension("direct"))

      resources = %Resources{root: tmp}

      {candidates, _blocked} = Loader.candidates(resources, [Path.join(tmp, "direct.exs")])

      assert List.keymember?(candidates, "direct", 0)
    end

    test "extra_paths arg allows directory paths" do
      tmp = tmp_dir()
      ext_dir = Path.join(tmp, "dir_ext")
      File.mkdir_p!(ext_dir)
      File.write!(Path.join(ext_dir, "extension.exs"), valid_extension("dir_ext"))

      resources = %Resources{root: tmp}

      {candidates, _blocked} = Loader.candidates(resources, [ext_dir])

      assert List.keymember?(candidates, "dir_ext", 0)
    end

    test "deduplicates by name with project beating global" do
      tmp = tmp_dir()
      global_ext = Path.join(tmp, "extensions")
      project_ext = Path.join([tmp, ".eva", "extensions"])
      File.mkdir_p!(global_ext)
      File.mkdir_p!(project_ext)
      write_extension(global_ext, "shared.exs", valid_extension("shared"))
      write_extension(project_ext, "shared.exs", valid_extension("shared"))

      resources = %Resources{root: tmp}

      {candidates, _blocked} = Loader.candidates(resources)

      matched = Enum.filter(candidates, fn {name, _path} -> name == "shared" end)
      assert length(matched) == 1
    end

    test "returns empty list when extensions_dir is missing" do
      tmp = tmp_dir()

      resources = %Resources{root: tmp}

      {candidates, _blocked} = Loader.candidates(resources)

      assert candidates == []
    end
  end

  describe "load/1" do
    test "loads a valid extension" do
      tmp = tmp_dir()
      name = unique("hello")
      path = write_extension(tmp, "#{name}.exs", valid_extension(name))

      {loaded, diagnostics} = Loader.load([{name, path}])

      assert diagnostics == []
      assert length(loaded) == 1
      assert hd(loaded).name == name
      assert hd(loaded).module == module_for(name)
    end

    test "reports diagnostic for extension without setup/1" do
      tmp = tmp_dir()
      name = unique("bad")
      path = write_extension(tmp, "#{name}.exs", extension_with_no_setup(name))

      {loaded, diagnostics} = Loader.load([{name, path}])

      assert loaded == []
      assert length(diagnostics) == 1
      assert String.contains?(hd(diagnostics), "does not export setup/1")
    end

    test "reports diagnostic for module without use Eva.Core.Extension" do
      tmp = tmp_dir()
      write_extension(tmp, "plain.exs", extension_without_use())

      {loaded, diagnostics} = Loader.load([{"plain", Path.join(tmp, "plain.exs")}])

      assert loaded == []
      assert length(diagnostics) == 1
      assert String.contains?(hd(diagnostics), "no module that uses Eva.Core.Extension")
    end

    test "refuses a module outside the Eva.Extension namespace" do
      tmp = tmp_dir()
      name = unique("outsider")

      path =
        write_extension(tmp, "#{name}.exs", ~s'''
        defmodule NotNamespaced_#{System.unique_integer([:positive])} do
          use Eva.Core.Extension

          def setup(_ctx), do: {:ok, %Eva.Core.Extension.Spec{}}
        end
        ''')

      {loaded, diagnostics} = Loader.load([{name, path}])

      assert loaded == []
      assert String.contains?(hd(diagnostics), "must be namespaced under Eva.Extension.*")
    end

    test "refuses an extension claiming another extension's name" do
      tmp = tmp_dir()
      name = unique("impostor")
      other = unique("victim")

      path =
        write_extension(tmp, "#{name}.exs", ~s'''
        defmodule #{inspect(module_for(other))} do
          use Eva.Core.Extension

          def setup(_ctx), do: {:ok, %Eva.Core.Extension.Spec{}}
        end
        ''')

      {loaded, diagnostics} = Loader.load([{name, path}])

      assert loaded == []
      assert String.contains?(hd(diagnostics), "must define #{inspect(module_for(name))}")
    end

    test "accepts modules nested under the extension's own namespace" do
      tmp = tmp_dir()
      name = unique("nested")

      path =
        write_extension(tmp, "#{name}.exs", ~s'''
        defmodule #{inspect(module_for(name))}.Client do
          def ping, do: :pong
        end

        defmodule #{inspect(module_for(name))} do
          use Eva.Core.Extension

          def setup(_ctx), do: {:ok, %Eva.Core.Extension.Spec{}}
        end
        ''')

      {loaded, diagnostics} = Loader.load([{name, path}])

      assert diagnostics == []
      assert hd(loaded).module == module_for(name)
      assert Module.concat(module_for(name), Client) in hd(loaded).modules
    end

    test "reports diagnostic for file with compile error" do
      tmp = tmp_dir()
      File.write!(Path.join(tmp, "broken.exs"), "{{{" <> valid_extension("broken"))

      {loaded, diagnostics} = Loader.load([{"broken", Path.join(tmp, "broken.exs")}])

      assert loaded == []
      assert length(diagnostics) == 1
      assert String.contains?(hd(diagnostics), "failed to compile")
    end

    test "loads a stateful extension" do
      tmp = tmp_dir()
      name = unique("stateful")
      path = write_extension(tmp, "#{name}.exs", stateful_extension(name))

      {loaded, diagnostics} = Loader.load([{name, path}])

      assert diagnostics == []
      assert length(loaded) == 1
      assert hd(loaded).module == module_for(name)
    end
  end

  describe "discover/2" do
    test "discovers and loads from resources" do
      tmp = tmp_dir()
      ext_dir = Path.join(tmp, "extensions")
      File.mkdir_p!(ext_dir)
      name = unique("discoverable")
      write_extension(ext_dir, "#{name}.exs", valid_extension(name))

      resources = %Resources{root: tmp}

      {loaded, diagnostics} = Loader.discover(resources)

      assert diagnostics == []
      assert length(loaded) == 1
      assert hd(loaded).name == name
    end
  end

  describe "purge/1" do
    test "unloads modules so they can be reloaded" do
      tmp = tmp_dir()
      name = unique("purge_test")
      path = write_extension(tmp, "#{name}.exs", valid_extension(name))

      {loaded, _diagnostics} = Loader.load([{name, path}])
      assert length(loaded) == 1

      mod = hd(loaded).module
      :ok = Loader.purge(loaded)

      refute function_exported?(mod, :setup, 1)
    end

    test "reloads modules the extension required itself" do
      tmp = tmp_dir()
      name = unique("parent")
      extension = module_for(name)
      helper = Module.concat(extension, Helper)

      write_extension(tmp, "helper.exs", ~s'''
      defmodule #{inspect(helper)} do
        def value, do: :before
      end
      ''')

      path =
        write_extension(tmp, "#{name}.exs", ~s'''
        Code.require_file(Path.join(__DIR__, "helper.exs"))

        defmodule #{inspect(extension)} do
          use Eva.Core.Extension

          def setup(_ctx), do: {:ok, %Eva.Core.Extension.Spec{}}
          def value, do: #{inspect(helper)}.value()
        end
        ''')

      {loaded, []} = Loader.load([{name, path}])
      assert extension.value() == :before
      assert helper in hd(loaded).modules

      # The sibling changing on disk is the whole point — a purge that only knows
      # about the marker module leaves this at `:before` with no error.
      write_extension(tmp, "helper.exs", ~s'''
      defmodule #{inspect(helper)} do
        def value, do: :after
      end
      ''')

      :ok = Loader.purge(loaded)
      {[_reloaded], []} = Loader.load([{name, path}])

      assert extension.value() == :after
    end
  end
end
