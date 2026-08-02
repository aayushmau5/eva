defmodule Eva.Extension.ServerTest.StateHolder do
  use Agent

  def start_link, do: Agent.start_link(fn -> nil end, name: __MODULE__)
  def put(value), do: Agent.update(__MODULE__, fn _ -> value end)
  def get, do: Agent.get(__MODULE__, & &1)
end

defmodule Eva.Extension.ServerTest.HooksTestModule do
  def setup(_ctx), do: {:ok, %Eva.Extension.Spec{}}

  def init(_ctx), do: {:ok, nil}

  def handle_hook(:tool_call, _payload, state), do: {:proceed, state}

  def handle_hook(:tool_result, {_call, result, is_error}, state),
    do: {{result, is_error}, state}

  def handle_event(_event, state), do: {:ok, state}
end

defmodule Eva.Extension.ServerTest.RewriteTestModule do
  def setup(_ctx), do: {:ok, %Eva.Extension.Spec{}}

  def init(_ctx) do
    {:ok, Eva.Extension.ServerTest.StateHolder.get() || %{}}
  end

  def handle_hook(:tool_call, _payload, state),
    do: {{:rewrite, Map.get(state, :arguments, %{})}, state}
end

defmodule Eva.Extension.ServerTest.BlockTestModule do
  def setup(_ctx), do: {:ok, %Eva.Extension.Spec{}}

  def init(_ctx) do
    {:ok, Eva.Extension.ServerTest.StateHolder.get() || %{}}
  end

  def handle_hook(:tool_call, _payload, state),
    do: {{:block, Map.get(state, :reason, "blocked")}, state}
end

defmodule Eva.Extension.ServerTest.CommandTestModule do
  def setup(_ctx),
    do:
      {:ok,
       %Eva.Extension.Spec{
         commands: [
           %Eva.Extension.Spec.Command{name: "hello", description: "greet", arg_hint: "[name]"}
         ]
       }}

  def init(_ctx) do
    {:ok, Eva.Extension.ServerTest.StateHolder.get() || %{}}
  end

  def handle_hook(_hook, _payload, state), do: {:proceed, state}

  def handle_command("hello", args, state),
    do: {{:text, "#{Map.get(state, :greeting, "hi")} #{args}"}, state}
end

defmodule Eva.Extension.ServerTest.CommandTestModuleBadReturn do
  def setup(_ctx) do
    {:ok,
     %Eva.Extension.Spec{
       commands: [
         %Eva.Extension.Spec.Command{name: "broken", description: "", arg_hint: ""}
       ]
     }}
  end

  def init(_ctx), do: {:ok, nil}

  def handle_command("broken", "", _state), do: "not a tuple"
end

defmodule Eva.Extension.ServerTest.CommandTestModuleCrash do
  def setup(_ctx) do
    {:ok,
     %Eva.Extension.Spec{
       commands: [
         %Eva.Extension.Spec.Command{name: "crash", description: "", arg_hint: ""}
       ]
     }}
  end

  def init(_ctx), do: {:ok, nil}

  def handle_command("crash", "", _state), do: raise("oops")
end

defmodule Eva.Extension.ServerTest.HandleRequestTestModule do
  def setup(_ctx), do: {:ok, %Eva.Extension.Spec{}}

  def init(_ctx) do
    {:ok, Eva.Extension.ServerTest.StateHolder.get() || %{}}
  end

  def handle_request(:get_value, state), do: {{:ok, Map.get(state, :value)}, state}
end

defmodule Eva.Extension.ServerTest.HandleRequestBadReturnTestModule do
  def setup(_ctx), do: {:ok, %Eva.Extension.Spec{}}

  def init(_ctx), do: {:ok, nil}

  def handle_request(:ping, _state), do: "bad"
end

defmodule Eva.Extension.ServerTest.HandleCastTestModule do
  def setup(_ctx), do: {:ok, %Eva.Extension.Spec{}}

  def init(_ctx) do
    {:ok, Eva.Extension.ServerTest.StateHolder.get() || %{}}
  end

  def handle_request(:increment, state),
    do: {{:ok, :incremented}, %{state | counter: state.counter + 1}}

  def handle_request(:get_counter, state), do: {{:ok, state.counter}, state}
end

defmodule Eva.Extension.ServerTest.HandleCastBadReturnTestModule do
  def setup(_ctx), do: {:ok, %Eva.Extension.Spec{}}

  def init(_ctx), do: {:ok, nil}

  def handle_request(:whatever, _state), do: "not a tuple"
end

defmodule Eva.Extension.ServerTest.EventsTestModule do
  def setup(_ctx), do: {:ok, %Eva.Extension.Spec{}}

  def init(_ctx), do: {:ok, %{}}

  def handle_event(_event, state),
    do: {:ok, Map.put(state, :received, true)}
end

defmodule Eva.Extension.ServerTest.InitFailTestModule do
  def setup(_ctx), do: {:ok, %Eva.Extension.Spec{}}

  def init(_ctx), do: {:error, :init_failed}
end

defmodule DeadSessionSimulator do
  use GenServer

  @impl true
  def init(state), do: {:ok, state}
end

defmodule Eva.Extension.ServerTest do
  use ExUnit.Case, async: false

  alias Eva.Extension.{Server, Context, Spec}
  alias Eva.Agent.{Messages, Tools}
  alias Eva.Agent.Events, as: AgentEvents

  setup do
    Eva.Extension.ServerTest.StateHolder.start_link()
    :ok
  end

  defp build_context(attrs \\ []) do
    %Context{
      name: Keyword.get(attrs, :name, "test_ext"),
      cwd: Keyword.get(attrs, :cwd, "/tmp"),
      model: Keyword.get(attrs, :model, "gpt-4"),
      provider_config:
        Keyword.get(attrs, :provider_config) ||
          %Eva.AI.Config.OpenAICompatible{
            base_url: "http://localhost:1/v1",
            provider_name: "test"
          },
      session_pid: Keyword.get(attrs, :session_pid, self()),
      resources: Keyword.get(attrs, :resources) || %Eva.Coding.Resources{root: "/tmp/eva"},
      extension_dir: Keyword.get(attrs, :extension_dir, "/tmp/ext")
    }
  end

  defp start_server(module, context \\ nil, event_classes \\ []) do
    ctx = context || build_context()

    {:ok, pid} =
      GenServer.start_link(Server,
        module: module,
        context: ctx,
        spec: %Spec{event_classes: event_classes},
        event_classes: event_classes
      )

    pid
  end

  describe "init/1" do
    test "starts successfully with a stateful extension" do
      pid = start_server(Eva.Extension.ServerTest.HooksTestModule)

      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "subscribes to specified event classes" do
      pid =
        start_server(Eva.Extension.ServerTest.EventsTestModule, nil, [:lifecycle])

      event = %AgentEvents.AgentStart{}

      Eva.Bus.publish(self(), event)
      Process.sleep(50)

      state = :sys.get_state(pid)
      assert Map.get(state, :extension_state) == %{received: true}
    end
  end

  describe "handle_call hook" do
    test "handles :tool_call hook returning :proceed" do
      pid = start_server(Eva.Extension.ServerTest.HooksTestModule)

      tool_call = %Messages.ToolCall{id: "tc1", name: "echo", arguments: %{}}

      result = GenServer.call(pid, {:hook, :tool_call, tool_call})

      assert result == :proceed
    end

    test "handles :tool_call hook returning :rewrite" do
      Eva.Extension.ServerTest.StateHolder.put(%{arguments: %{"msg" => "rewritten"}})

      pid = start_server(Eva.Extension.ServerTest.RewriteTestModule)

      tool_call = %Messages.ToolCall{id: "tc1", name: "echo", arguments: %{"msg" => "original"}}

      result = GenServer.call(pid, {:hook, :tool_call, tool_call})

      assert result == {:rewrite, %{"msg" => "rewritten"}}
    end

    test "handles :tool_call hook returning :block" do
      Eva.Extension.ServerTest.StateHolder.put(%{reason: "not allowed"})

      pid = start_server(Eva.Extension.ServerTest.BlockTestModule)

      tool_call = %Messages.ToolCall{id: "tc1", name: "rm", arguments: %{}}

      result = GenServer.call(pid, {:hook, :tool_call, tool_call})

      assert {:block, "not allowed"} = result
    end

    test "tool_call failure catches in hook_failure callback" do
      pid = start_server(Eva.Extension.ServerTest.HooksTestModule)

      tool_call = %Messages.ToolCall{id: "tc1", name: "echo", arguments: %{}}

      result = GenServer.call(pid, {:hook, :nothing_matched, tool_call})

      assert result == :continue
    end

    test "handles :tool_result hook" do
      pid = start_server(Eva.Extension.ServerTest.HooksTestModule)

      tool_call = %Messages.ToolCall{id: "tc1", name: "echo", arguments: %{}}

      result = %Tools.AgentToolResult{
        content: [%Messages.TextContent{text: "done"}]
      }

      reply = GenServer.call(pid, {:hook, :tool_result, {tool_call, result, false}})

      assert reply == {result, false}
    end
  end

  describe "handle_call command" do
    test "dispatches commands to extension" do
      Eva.Extension.ServerTest.StateHolder.put(%{greeting: "hi"})

      pid = start_server(Eva.Extension.ServerTest.CommandTestModule)

      reply = GenServer.call(pid, {:command, "hello", "world"})

      assert reply == {:text, "hi world"}
    end

    test "returns error for bad command return" do
      pid = start_server(Eva.Extension.ServerTest.CommandTestModuleBadReturn)

      reply = GenServer.call(pid, {:command, "broken", ""})

      assert reply == {:error, :bad_return}
    end

    test "returns error when command crashes" do
      pid = start_server(Eva.Extension.ServerTest.CommandTestModuleCrash)

      reply = GenServer.call(pid, {:command, "crash", ""})

      assert {:error, reason} = reply
      assert String.contains?(reason, "oops")
    end
  end

  describe "handle_call extension_request" do
    test "forwards request to extension" do
      Eva.Extension.ServerTest.StateHolder.put(%{value: 42})

      pid = start_server(Eva.Extension.ServerTest.HandleRequestTestModule)

      reply = GenServer.call(pid, {:extension_request, :get_value})

      assert reply == {:ok, 42}
    end

    test "returns error for bad return" do
      pid = start_server(Eva.Extension.ServerTest.HandleRequestBadReturnTestModule)

      reply = GenServer.call(pid, {:extension_request, :ping})

      assert reply == {:error, :bad_return}
    end
  end

  describe "handle_cast extension_cast" do
    test "applies cast and updates state" do
      Eva.Extension.ServerTest.StateHolder.put(%{counter: 0})

      pid = start_server(Eva.Extension.ServerTest.HandleCastTestModule)

      GenServer.cast(pid, {:extension_cast, :increment})

      Process.sleep(50)
      reply = GenServer.call(pid, {:extension_request, :get_counter})
      assert reply == {:ok, 1}
    end

    test "silently ignores bad cast return" do
      pid = start_server(Eva.Extension.ServerTest.HandleCastBadReturnTestModule)

      GenServer.cast(pid, {:extension_cast, :whatever})

      Process.sleep(50)
      assert Process.alive?(pid)
    end
  end

  describe "handle_info events" do
    test "forwards struct events to handle_event" do
      pid = start_server(Eva.Extension.ServerTest.EventsTestModule)

      event = %AgentEvents.AgentStart{}
      send(pid, event)
      Process.sleep(50)

      state = :sys.get_state(pid)
      assert Map.get(state, :extension_state) == %{received: true}
    end

    test "silently ignores non-struct messages" do
      pid = start_server(Eva.Extension.ServerTest.EventsTestModule)

      send(pid, :some_random_message)
      Process.sleep(50)

      assert Process.alive?(pid)
    end
  end

  describe "session DOWN" do
    test "stops when the monitored session dies" do
      {:ok, session_pid} = GenServer.start(DeadSessionSimulator, %{})

      ctx = build_context(session_pid: session_pid)

      {:ok, pid} =
        GenServer.start(Server,
          module: Eva.Extension.ServerTest.HooksTestModule,
          context: ctx,
          spec: %Spec{},
          event_classes: []
        )

      assert Process.alive?(pid)

      GenServer.stop(session_pid, :normal)
      Process.sleep(50)

      refute Process.alive?(pid)
    end
  end

  describe "init failure" do
    test "stops when init returns {:error, reason}" do
      result =
        GenServer.start(Server,
          module: Eva.Extension.ServerTest.InitFailTestModule,
          context: build_context(),
          spec: %Spec{},
          event_classes: []
        )

      assert {:error, :init_failed} = result
    end
  end
end
