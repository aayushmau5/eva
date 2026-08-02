defmodule Eva.Extension.HooksTest.ProceedExt do
  use GenServer

  @impl true
  def init(_), do: {:ok, nil}

  @impl true
  def handle_call({:hook, :tool_call, _payload}, _from, state), do: {:reply, :proceed, state}

  @impl true
  def handle_call({:hook, :tool_result, payload}, _from, state) do
    {_tool_call, result, is_error} = payload
    {:reply, {result, is_error}, state}
  end
end

defmodule Eva.Extension.HooksTest.RewriteExt do
  use GenServer

  @impl true
  def init(_), do: {:ok, nil}

  @impl true
  def handle_call({:hook, :tool_call, _payload}, _from, state) do
    {:reply, {:rewrite, %{"msg" => "rewritten"}}, state}
  end
end

defmodule Eva.Extension.HooksTest.BlockExt do
  use GenServer

  @impl true
  def init(reason), do: {:ok, reason}

  @impl true
  def handle_call({:hook, :tool_call, _payload}, _from, state),
    do: {:reply, {:block, state}, state}
end

defmodule Eva.Extension.HooksTest.BlockOnRewriteExt do
  use GenServer

  @impl true
  def init(_), do: {:ok, nil}

  @impl true
  def handle_call({:hook, :tool_call, payload}, _from, state) do
    if payload.arguments["msg"] == "rewritten" do
      {:reply, {:block, "blocked on rewritten"}, state}
    else
      {:reply, :proceed, state}
    end
  end
end

defmodule Eva.Extension.HooksTest.ResultAppendExt do
  use GenServer

  @impl true
  def init(suffix), do: {:ok, suffix}

  @impl true
  def handle_call({:hook, :tool_result, {_tool_call, result, is_error}}, _from, state) do
    alias Eva.Agent.{Messages, Tools}

    [%Messages.TextContent{text: existing}] = result.content

    new_result = %Tools.AgentToolResult{
      content: [%Messages.TextContent{text: existing <> state}]
    }

    {:reply, {new_result, is_error}, state}
  end
end

defmodule Eva.Extension.HooksTest.InputTransformExt do
  use GenServer

  @impl true
  def init(text), do: {:ok, text}

  @impl true
  def handle_call({:hook, :input, _text}, _from, state),
    do: {:reply, {:transform, state}, state}
end

defmodule Eva.Extension.HooksTest.InputHandleExt do
  use GenServer

  @impl true
  def init(message), do: {:ok, message}

  @impl true
  def handle_call({:hook, :input, _text}, _from, state),
    do: {:reply, {:handled, state}, state}
end

defmodule Eva.Extension.HooksTest.HangingExt do
  use GenServer

  @impl true
  def init(_), do: {:ok, nil}

  @impl true
  def handle_call({:hook, :tool_call, _payload}, _from, state) do
    Process.sleep(:infinity)
    {:reply, :proceed, state}
  end
end

defmodule Eva.Extension.HooksTest do
  use ExUnit.Case, async: true

  alias Eva.Extension.Hooks
  alias Eva.Agent.{Messages, Tools}

  defp tool_call do
    %Messages.ToolCall{id: "tc1", name: "echo", arguments: %{"msg" => "hello"}}
  end

  defp tool_result do
    %Tools.AgentToolResult{
      content: [%Messages.TextContent{text: "echo: hello"}]
    }
  end

  describe "before_tool_call_fun/1" do
    test "returns :proceed when no listeners" do
      fun = Hooks.before_tool_call_fun(%{})
      assert fun.(tool_call()) == :proceed
    end

    test "returns :proceed from a listener that says proceed" do
      {:ok, pid} = GenServer.start_link(Eva.Extension.HooksTest.ProceedExt, nil)

      targets = %{tool_call: [{"test_ext", pid}]}
      fun = Hooks.before_tool_call_fun(targets)

      assert fun.(tool_call()) == :proceed
    end

    test "rewrites arguments from a listener" do
      {:ok, pid} = GenServer.start_link(Eva.Extension.HooksTest.RewriteExt, nil)

      targets = %{tool_call: [{"test_ext", pid}]}
      fun = Hooks.before_tool_call_fun(targets)

      assert {:proceed, rewritten} = fun.(tool_call())
      assert rewritten.arguments == %{"msg" => "rewritten"}
    end

    test "blocks from a listener" do
      {:ok, pid} = GenServer.start_link(Eva.Extension.HooksTest.BlockExt, "not allowed")

      targets = %{tool_call: [{"test_ext", pid}]}
      fun = Hooks.before_tool_call_fun(targets)

      assert {:block, "test_ext: not allowed"} = fun.(tool_call())
    end

    test "first blocker wins in chain" do
      {:ok, block_pid} = GenServer.start_link(Eva.Extension.HooksTest.BlockExt, "first block")
      {:ok, proceed_pid} = GenServer.start_link(Eva.Extension.HooksTest.ProceedExt, nil)

      targets = %{
        tool_call: [{"block_ext", block_pid}, {"proceed_ext", proceed_pid}]
      }

      fun = Hooks.before_tool_call_fun(targets)

      assert {:block, "block_ext: first block"} = fun.(tool_call())
    end

    test "chain rewrites propagate to next listener" do
      {:ok, rewrite_pid} = GenServer.start_link(Eva.Extension.HooksTest.RewriteExt, nil)

      {:ok, block_pid} =
        GenServer.start_link(Eva.Extension.HooksTest.BlockOnRewriteExt, nil)

      targets = %{
        tool_call: [{"rewrite_ext", rewrite_pid}, {"block_ext", block_pid}]
      }

      fun = Hooks.before_tool_call_fun(targets)

      assert {:block, "block_ext: blocked on rewritten"} = fun.(tool_call())
    end
  end

  describe "after_tool_call_fun/1" do
    test "returns original result when no listeners" do
      fun = Hooks.after_tool_call_fun(%{})

      assert fun.(tool_call(), tool_result(), false) == {tool_result(), false}
    end

    test "transforms result through all listeners" do
      {:ok, append_pid} = GenServer.start_link(Eva.Extension.HooksTest.ResultAppendExt, "-a")

      {:ok, append2_pid} =
        GenServer.start_link(Eva.Extension.HooksTest.ResultAppendExt, "-b")

      targets = %{
        tool_result: [{"ext1", append_pid}, {"ext2", append2_pid}]
      }

      fun = Hooks.after_tool_call_fun(targets)

      {result, _is_error} = fun.(tool_call(), tool_result(), false)

      assert [%Messages.TextContent{text: text}] = result.content
      assert text == "echo: hello-a-b"
    end
  end

  describe "run_input/2" do
    test "returns :continue with original text when no listeners" do
      assert Hooks.run_input(%{}, "hello world") == {:continue, "hello world"}
    end

    test "transforms text through listener" do
      {:ok, pid} =
        GenServer.start_link(Eva.Extension.HooksTest.InputTransformExt, "transformed!")

      targets = %{input: [{"input_ext", pid}]}
      assert Hooks.run_input(targets, "original") == {:continue, "transformed!"}
    end

    test "first handled response stops the chain" do
      {:ok, handle_pid} =
        GenServer.start_link(Eva.Extension.HooksTest.InputHandleExt, "handled first")

      targets = %{
        input: [{"handle_ext", handle_pid}]
      }

      assert Hooks.run_input(targets, "original") == {:handled, "handled first"}
    end
  end

  describe "safe_call/2" do
    test "returns the GenServer reply" do
      {:ok, pid} = GenServer.start_link(Eva.Extension.HooksTest.ProceedExt, nil)

      assert Hooks.safe_call(pid, {:hook, :tool_call, tool_call()}) == :proceed
    end

    test "returns error tuple on dead process" do
      Process.flag(:trap_exit, true)
      {:ok, pid} = GenServer.start_link(Eva.Extension.HooksTest.ProceedExt, nil)
      Process.exit(pid, :kill)
      Process.sleep(10)

      assert {:error, _} = Hooks.safe_call(pid, {:hook, :tool_call, tool_call()})
    end

    test "returns error tuple on timeout" do
      {:ok, pid} = GenServer.start_link(Eva.Extension.HooksTest.HangingExt, nil)

      assert {:error, _} = Hooks.safe_call(pid, {:hook, :tool_call, tool_call()})
    end
  end
end
