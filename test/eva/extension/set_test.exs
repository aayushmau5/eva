defmodule Eva.Extension.SetTest do
  use ExUnit.Case, async: false

  alias Eva.Extension.Set

  alias Eva.Coding.Resources

  defp tmp_dir do
    path = Path.join(System.tmp_dir!(), "set_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp write_extension(dir, name, content) do
    path = Path.join(dir, name)
    File.write!(path, content)
    path
  end

  # An extension's module has to match its name, so the file, the name Set knows it by,
  # and the module all derive from one string.
  defp module_for(name), do: Eva.Core.Extension.namespace(name)

  defp tools_only_extension(name, tool_name) do
    ~s'''
    defmodule #{inspect(module_for(name))} do
      use Eva.Core.Extension

      def setup(_ctx) do
        {:ok, %Eva.Core.Extension.Spec{
          tools: [
            %Eva.Core.Agent.Tools.AgentTool{
              name: "#{tool_name}",
              description: "A test tool",
              input_schema: %{type: "object", properties: %{}},
              executor: fn _args, _ctx ->
                %Eva.Core.Agent.Tools.AgentToolResult{
                  content: [%Eva.Core.Agent.Messages.TextContent{text: "result"}]
                }
              end
            }
          ]
        }}
      end
    end
    '''
  end

  defp guideline_extension(name) do
    ~s'''
    defmodule #{inspect(module_for(name))} do
      use Eva.Core.Extension

      def setup(_ctx) do
        {:ok, %Eva.Core.Extension.Spec{
          guidelines: ["Always use types", "Write tests first"]
        }}
      end
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
          event_classes: [:stream],
          commands: [
            %Eva.Core.Extension.Spec.Command{name: "ping", description: "pong", arg_hint: ""}
          ]
        }}
      end

      def init(_ctx), do: {:ok, nil}

      def handle_hook(:tool_call, _payload, state), do: {:proceed, state}

      def handle_command("ping", _args, state), do: {{:text, "pong"}, state}
    end
    '''
  end

  defp command_extension(name) do
    ~s'''
    defmodule #{inspect(module_for(name))} do
      use Eva.Core.Extension

      def setup(_ctx) do
        {:ok, %Eva.Core.Extension.Spec{
          commands: [
            %Eva.Core.Extension.Spec.Command{name: "hello", description: "says hello", arg_hint: "[name]"}
          ]
        }}
      end

      def init(_ctx), do: {:ok, %{}}

      def handle_command("hello", args, state), do: {{:text, "hello " <> args}, state}
    end
    '''
  end

  describe "empty/1" do
    test "returns an empty set struct" do
      set = Set.empty()
      assert %Set{} = set
      assert set.order == []
      assert set.loaded == %{}
      assert set.specs == %{}
      assert set.diagnostics == []
    end

    test "accepts diagnostics" do
      set = Set.empty(["error 1", "error 2"])
      assert set.diagnostics == ["error 1", "error 2"]
    end
  end

  describe "load/3" do
    test "loads extensions from a directory" do
      tmp = tmp_dir()
      ext_dir = Path.join(tmp, "extensions")
      File.mkdir_p!(ext_dir)
      write_extension(ext_dir, "tool_ext.exs", tools_only_extension("tool_ext", "my_tool"))

      resources = %Resources{root: tmp}
      set = Set.load(resources, self())

      assert "tool_ext" in set.order
      assert length(Set.tools(set)) == 1
      assert hd(Set.tools(set)).name == "my_tool"
    end

    test "loads multiple extensions in discovery order" do
      tmp = tmp_dir()
      ext_dir = Path.join(tmp, "extensions")
      File.mkdir_p!(ext_dir)
      write_extension(ext_dir, "first.exs", tools_only_extension("first", "tool_a"))
      write_extension(ext_dir, "second.exs", tools_only_extension("second", "tool_b"))

      resources = %Resources{root: tmp}
      set = Set.load(resources, self())

      assert set.order == ["first", "second"]

      tool_names = Set.tools(set) |> Enum.map(& &1.name)
      assert tool_names == ["tool_a", "tool_b"]
    end

    test "respects overrides to filter extensions" do
      tmp = tmp_dir()
      ext_dir = Path.join(tmp, "extensions")
      File.mkdir_p!(ext_dir)
      write_extension(ext_dir, "keep.exs", tools_only_extension("keep", "keeper"))
      write_extension(ext_dir, "skip.exs", tools_only_extension("skip", "skipped"))

      resources = %Resources{root: tmp}

      set = Set.load(resources, self(), %{overrides: %{"skip" => false}})

      assert "keep" in set.order
      refute "skip" in set.order
      assert length(Set.tools(set)) == 1
    end

    test "collects guidelines from extensions" do
      tmp = tmp_dir()
      ext_dir = Path.join(tmp, "extensions")
      File.mkdir_p!(ext_dir)
      write_extension(ext_dir, "guide.exs", guideline_extension("guide"))

      resources = %Resources{root: tmp}
      set = Set.load(resources, self())

      guidelines = Set.guidelines(set)
      assert "Always use types" in guidelines
      assert "Write tests first" in guidelines
    end

    test "starts stateful extension processes" do
      tmp = tmp_dir()
      ext_dir = Path.join(tmp, "extensions")
      File.mkdir_p!(ext_dir)
      write_extension(ext_dir, "stateful.exs", stateful_extension("stateful"))

      resources = %Resources{root: tmp}
      set = Set.load(resources, self())

      info = Set.list(set) |> Enum.find(&(&1.name == "stateful"))
      assert info.running?
      assert info.hooks == [:tool_call]
      assert info.event_classes == [:stream]
      assert info.commands == ["ping"]
    end

    test "starts command extension and allows command dispatch" do
      tmp = tmp_dir()
      ext_dir = Path.join(tmp, "extensions")
      File.mkdir_p!(ext_dir)
      write_extension(ext_dir, "cmd_dispatch.exs", command_extension("cmd_dispatch"))

      resources = %Resources{root: tmp}
      set = Set.load(resources, self())

      reply = Set.run_command(set, "hello", "world")
      assert reply == {:text, "hello world"}
    end

    test "run_command returns error for unknown command" do
      tmp = tmp_dir()
      ext_dir = Path.join(tmp, "extensions")
      File.mkdir_p!(ext_dir)
      write_extension(ext_dir, "cmd_unknown.exs", command_extension("cmd_unknown"))

      resources = %Resources{root: tmp}
      set = Set.load(resources, self())

      assert Set.run_command(set, "nonexistent", "") == {:error, :unknown_command}
    end

    test "run_command returns error when process not running" do
      tmp = tmp_dir()
      ext_dir = Path.join(tmp, "extensions")
      File.mkdir_p!(ext_dir)
      write_extension(ext_dir, "cmd_stopped.exs", command_extension("cmd_stopped"))

      resources = %Resources{root: tmp}
      set = Set.load(resources, self())

      Set.shutdown(set)

      assert Set.run_command(set, "hello", "test") == {:error, :no_process}
    end

    test "respects builtin_tool_names for tool dedup" do
      tmp = tmp_dir()
      ext_dir = Path.join(tmp, "extensions")
      File.mkdir_p!(ext_dir)
      write_extension(ext_dir, "ext.exs", tools_only_extension("ext", "read_file"))

      resources = %Resources{root: tmp}

      set =
        Set.load(resources, self(), %{builtin_tool_names: ["read_file", "write_file", "bash"]})

      tools = Set.tools(set)
      assert tools == []
    end

    test "detects tool name conflicts between extensions" do
      tmp = tmp_dir()
      ext_dir = Path.join(tmp, "extensions")
      File.mkdir_p!(ext_dir)
      write_extension(ext_dir, "ext_a.exs", tools_only_extension("ext_a", "shared_tool"))
      write_extension(ext_dir, "ext_b.exs", tools_only_extension("ext_b", "shared_tool"))

      resources = %Resources{root: tmp}
      set = Set.load(resources, self())

      tools = Set.tools(set)
      assert length(tools) == 1
      assert hd(tools).name == "shared_tool"

      diagnostics = Set.diagnostics(set)
      assert Enum.any?(diagnostics, &String.contains?(&1, "already registered"))
    end

    test "commands return the first registered wins" do
      tmp = tmp_dir()
      ext_dir = Path.join(tmp, "extensions")
      File.mkdir_p!(ext_dir)

      # Both register the same command name
      write_extension(ext_dir, "first_cmd.exs", ~s'''
      defmodule Eva.Extension.FirstCmd do
        use Eva.Core.Extension
        def setup(_ctx) do
          {:ok, %Eva.Core.Extension.Spec{
            commands: [%Eva.Core.Extension.Spec.Command{name: "shared", description: "first", arg_hint: ""}]
          }}
        end
        def init(_ctx), do: {:ok, nil}
        def handle_command("shared", _args, state), do: {{:text, "first"}, state}
      end
      ''')

      write_extension(ext_dir, "second_cmd.exs", ~s'''
      defmodule Eva.Extension.SecondCmd do
        use Eva.Core.Extension
        def setup(_ctx) do
          {:ok, %Eva.Core.Extension.Spec{
            commands: [%Eva.Core.Extension.Spec.Command{name: "shared", description: "second", arg_hint: ""}]
          }}
        end
        def init(_ctx), do: {:ok, nil}
        def handle_command("shared", _args, state), do: {{:text, "second"}, state}
      end
      ''')

      resources = %Resources{root: tmp}
      set = Set.load(resources, self())

      commands = Set.commands(set)
      {owner, _} = commands["shared"]
      assert owner == "first_cmd"
    end
  end

  describe "set_enabled/4" do
    test "disabling an extension removes it" do
      tmp = tmp_dir()
      ext_dir = Path.join(tmp, "extensions")
      File.mkdir_p!(ext_dir)
      write_extension(ext_dir, "removable.exs", guideline_extension("removable"))

      resources = %Resources{root: tmp}
      set = Set.load(resources, self())

      assert "removable" in set.order

      {:ok, set} = Set.set_enabled(set, "removable", false, %{})

      refute "removable" in set.order
    end

    test "re-enabling an extension brings it back" do
      tmp = tmp_dir()
      ext_dir = Path.join(tmp, "extensions")
      File.mkdir_p!(ext_dir)
      write_extension(ext_dir, "togglable.exs", guideline_extension("togglable"))

      resources = %Resources{root: tmp}
      set = Set.load(resources, self())

      {:ok, set} = Set.set_enabled(set, "togglable", false, %{})
      refute "togglable" in set.order

      {:ok, set} = Set.set_enabled(set, "togglable", true, %{resources: resources})
      assert "togglable" in set.order
    end

    test "returns error for unknown extension" do
      tmp = tmp_dir()
      resources = %Resources{root: tmp}

      set = Set.empty()
      set = %Set{set | resources: resources}

      assert {:error, :not_found} =
               Set.set_enabled(set, "notfound", true, %{resources: resources})
    end
  end

  describe "drop/2" do
    test "removes extension by name" do
      tmp = tmp_dir()
      ext_dir = Path.join(tmp, "extensions")
      File.mkdir_p!(ext_dir)
      write_extension(ext_dir, "dropped.exs", guideline_extension("dropped"))

      resources = %Resources{root: tmp}
      set = Set.load(resources, self())

      set = Set.drop(set, "dropped")

      assert set.order == []
      assert set.loaded == %{}
      assert set.specs == %{}
    end

    test "drop by non-existent name is a no-op" do
      set = Set.empty()
      set = Set.drop(set, "nonexistent")
      assert %Set{} = set
    end
  end

  describe "shutdown/1" do
    test "stops all extension processes" do
      tmp = tmp_dir()
      ext_dir = Path.join(tmp, "extensions")
      File.mkdir_p!(ext_dir)
      write_extension(ext_dir, "runner.exs", stateful_extension("runner"))

      resources = %Resources{root: tmp}
      set = Set.load(resources, self())

      before = Set.list(set) |> Enum.find(&(&1.name == "runner"))
      assert before.running?

      Set.shutdown(set)

      after_list = Set.list(set) |> Enum.find(&(&1.name == "runner"))
      refute after_list.running?
    end
  end

  describe "hook_targets/1" do
    test "returns map of hook types to listeners" do
      tmp = tmp_dir()
      ext_dir = Path.join(tmp, "extensions")
      File.mkdir_p!(ext_dir)
      write_extension(ext_dir, "hooker.exs", stateful_extension("hooker"))

      resources = %Resources{root: tmp}
      set = Set.load(resources, self())

      targets = Set.hook_targets(set)
      assert Map.has_key?(targets, :tool_call)
      assert is_list(targets[:tool_call])
      assert length(targets[:tool_call]) == 1
      {name, pid} = hd(targets[:tool_call])
      assert name == "hooker"
      assert is_pid(pid)
    end
  end

  describe "list/1" do
    test "returns metadata for all extensions" do
      tmp = tmp_dir()
      ext_dir = Path.join(tmp, "extensions")
      File.mkdir_p!(ext_dir)
      write_extension(ext_dir, "meta.exs", stateful_extension("meta"))

      resources = %Resources{root: tmp}
      set = Set.load(resources, self())

      [info] = Set.list(set)
      assert info.name == "meta"
      assert is_binary(info.path)
      assert is_atom(info.module)
      assert info.module == module_for("meta")
      assert info.running? == true
      assert info.tool_count == 0
      assert info.commands == ["ping"]
      assert info.hooks == [:tool_call]
      assert info.event_classes == [:stream]
    end
  end
end
