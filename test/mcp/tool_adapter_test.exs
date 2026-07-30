defmodule Eva.MCP.ToolAdapterTest do
  use ExUnit.Case, async: true

  alias Eva.Agent.Messages
  alias Eva.Agent.Tools
  alias Eva.MCP.{Config, ToolAdapter}

  defmodule MockServer do
    use GenServer

    def start_link(args) do
      GenServer.start_link(__MODULE__, args)
    end

    @impl true
    def init({config, reply}) do
      Registry.register(Eva.MCP.Registry, {config.scope_dir, config.name}, nil)
      {:ok, reply}
    end

    @impl true
    def handle_call({:call_tool_async, _name, _args, receiver_pid}, _from, {:ok, _result} = reply) do
      ref = make_ref()
      send(receiver_pid, {:mcp_result, ref, elem(reply, 1)})
      {:reply, {:ok, ref}, reply}
    end

    def handle_call(
          {:call_tool_async, _name, _args, receiver_pid},
          _from,
          {:error, _reason} = reply
        ) do
      ref = make_ref()
      send(receiver_pid, {:mcp_error, ref, elem(reply, 1)})
      {:reply, {:ok, ref}, reply}
    end
  end

  defp build_config(attrs \\ []) do
    struct!(
      Config,
      Keyword.merge(
        [
          name: unique_name(),
          type: :stdio,
          enabled: true,
          config: %Config.Stdio{command: "echo", args: []}
        ],
        attrs
      )
    )
  end

  defp unique_name, do: "test_adapter_#{System.unique_integer([:positive])}"

  defp register_mock(config, reply) do
    {:ok, pid} = MockServer.start_link({config, reply})
    pid
  end

  defp build_tool(attrs \\ []) do
    Map.merge(
      %{name: "my_tool", description: "does stuff", input_schema: %{}},
      Map.new(attrs)
    )
  end

  describe "tool_name/2" do
    test "prefixes with mcp__ and joins server and tool with __" do
      assert ToolAdapter.tool_name("server", "tool") == "mcp__server__tool"
    end

    test "sanitizes special characters in server and tool name" do
      assert ToolAdapter.tool_name("my server!", "foo@bar:baz") == "mcp__my_server___foo_bar_baz"
    end

    test "preserves alphanumeric, underscores, and hyphens" do
      assert ToolAdapter.tool_name("abc-123_XYZ", "foo_bar-baz") ==
               "mcp__abc-123_XYZ__foo_bar-baz"
    end

    test "keeps the full name when under max length" do
      name = String.duplicate("a", 28)
      result = ToolAdapter.tool_name(name, name)
      assert result == "mcp__#{name}__#{name}"
      assert String.length(result) < 64
    end

    test "keeps the full name when exactly at max length" do
      s = String.duplicate("a", 30)
      t = String.duplicate("b", 27)
      result = ToolAdapter.tool_name(s, t)
      assert String.length(result) == 64
      assert result == "mcp__#{s}__#{t}"
    end

    test "truncates and appends hash when name exceeds max length" do
      long = String.duplicate("a", 100)
      result = ToolAdapter.tool_name(long, long)
      assert String.length(result) == 64
      assert String.starts_with?(result, "mcp__")
      assert result =~ ~r/_[a-f0-9]{6}$/
    end

    test "truncated names for different tools on the same server differ" do
      name1 = ToolAdapter.tool_name("server", String.duplicate("a", 100))
      name2 = ToolAdapter.tool_name("server", String.duplicate("b", 100))
      assert name1 != name2
    end
  end

  describe "to_agent_tool/2" do
    setup do
      config = build_config()
      %{config: config}
    end

    test "builds an AgentTool with the mangled name", %{config: config} do
      agent_tool = ToolAdapter.to_agent_tool(config, build_tool())
      assert agent_tool.name == "mcp__#{config.name}__my_tool"
    end

    test "copies description and input_schema", %{config: config} do
      tool = build_tool(description: "does X", input_schema: %{"type" => "object"})
      agent_tool = ToolAdapter.to_agent_tool(config, tool)
      assert agent_tool.description == "does X"
      assert agent_tool.input_schema == %{"type" => "object"}
    end

    test "handles nil description", %{config: config} do
      tool = build_tool(description: nil)
      agent_tool = ToolAdapter.to_agent_tool(config, tool)
      assert agent_tool.description == nil
    end

    test "sets prompt_snippet to nil", %{config: config} do
      agent_tool = ToolAdapter.to_agent_tool(config, build_tool())
      assert agent_tool.prompt_snippet == nil
    end

    test "executor is a callable function", %{config: config} do
      agent_tool = ToolAdapter.to_agent_tool(config, build_tool())
      assert is_function(agent_tool.executor)
    end
  end

  describe "to_agent_tools/2" do
    test "returns empty list for empty tools" do
      assert ToolAdapter.to_agent_tools(build_config(), []) == []
    end

    test "transforms multiple tools" do
      config = build_config()

      tools = [
        build_tool(name: "tool_a", description: "a"),
        build_tool(name: "tool_b", description: "b")
      ]

      result = ToolAdapter.to_agent_tools(config, tools)
      assert length(result) == 2

      assert Enum.map(result, & &1.name) == [
               "mcp__#{config.name}__tool_a",
               "mcp__#{config.name}__tool_b"
             ]
    end
  end

  describe "executor" do
    setup do
      config = build_config()
      %{config: config}
    end

    test "raises when server is not running", %{config: config} do
      agent_tool = ToolAdapter.to_agent_tool(config, build_tool())

      assert_raise RuntimeError, "MCP server #{config.name} is not running", fn ->
        agent_tool.executor.(%{}, nil)
      end
    end

    test "returns AgentToolResult with text content on success", %{config: config} do
      register_mock(config, {:ok, %{"content" => [%{"type" => "text", "text" => "hello"}]}})
      agent_tool = ToolAdapter.to_agent_tool(config, build_tool())

      result = agent_tool.executor.(%{}, nil)

      assert %Tools.AgentToolResult{} = result
      assert result.content == [%Messages.TextContent{text: "hello"}]
    end

    test "raises when result has isError true with content text", %{config: config} do
      register_mock(
        config,
        {:ok,
         %{"isError" => true, "content" => [%{"type" => "text", "text" => "something broke"}]}}
      )

      agent_tool = ToolAdapter.to_agent_tool(config, build_tool())

      assert_raise RuntimeError, "something broke", fn ->
        agent_tool.executor.(%{}, nil)
      end
    end

    test "raises when result has isError true with multiple content blocks", %{config: config} do
      register_mock(
        config,
        {:ok,
         %{
           "isError" => true,
           "content" => [
             %{"type" => "text", "text" => "line one"},
             %{"type" => "text", "text" => "line two"}
           ]
         }}
      )

      agent_tool = ToolAdapter.to_agent_tool(config, build_tool())

      assert_raise RuntimeError, "line one\nline two", fn ->
        agent_tool.executor.(%{}, nil)
      end
    end

    test "raises with fallback message when isError has no content", %{config: config} do
      register_mock(config, {:ok, %{"isError" => true}})
      agent_tool = ToolAdapter.to_agent_tool(config, build_tool())

      assert_raise RuntimeError, "Tool call failed", fn ->
        agent_tool.executor.(%{}, nil)
      end
    end

    test "raises on error tuple with message key", %{config: config} do
      register_mock(config, {:error, %{"message" => "connection refused"}})
      agent_tool = ToolAdapter.to_agent_tool(config, build_tool())

      assert_raise RuntimeError, "connection refused", fn ->
        agent_tool.executor.(%{}, nil)
      end
    end

    test "raises on error tuple with arbitrary reason", %{config: config} do
      register_mock(config, {:error, :timeout})
      agent_tool = ToolAdapter.to_agent_tool(config, build_tool())

      assert_raise RuntimeError, ":timeout", fn ->
        agent_tool.executor.(%{}, nil)
      end
    end

    test "converts image content blocks", %{config: config} do
      register_mock(
        config,
        {:ok,
         %{
           "content" => [%{"type" => "image", "data" => "base64stuff", "mimeType" => "image/png"}]
         }}
      )

      agent_tool = ToolAdapter.to_agent_tool(config, build_tool())

      result = agent_tool.executor.(%{}, nil)

      assert result.content == [
               %Messages.ImageContent{data: "base64stuff", mime_type: "image/png"}
             ]
    end

    test "converts mixed text and image content", %{config: config} do
      register_mock(
        config,
        {:ok,
         %{
           "content" => [
             %{"type" => "text", "text" => "intro"},
             %{"type" => "image", "data" => "abc", "mimeType" => "image/jpeg"},
             %{"type" => "text", "text" => "outro"}
           ]
         }}
      )

      agent_tool = ToolAdapter.to_agent_tool(config, build_tool())

      result = agent_tool.executor.(%{}, nil)

      assert length(result.content) == 3
      assert Enum.at(result.content, 0) == %Messages.TextContent{text: "intro"}

      assert Enum.at(result.content, 1) == %Messages.ImageContent{
               data: "abc",
               mime_type: "image/jpeg"
             }

      assert Enum.at(result.content, 2) == %Messages.TextContent{text: "outro"}
    end

    test "stringifies unknown content blocks as JSON", %{config: config} do
      register_mock(
        config,
        {:ok, %{"content" => [%{"type" => "resource", "uri" => "file:///data.txt"}]}}
      )

      agent_tool = ToolAdapter.to_agent_tool(config, build_tool())

      result = agent_tool.executor.(%{}, nil)

      assert result.content == [
               %Messages.TextContent{
                 text: "{\"type\":\"resource\",\"uri\":\"file:///data.txt\"}"
               }
             ]
    end

    test "returns empty content when result has no content key", %{config: config} do
      register_mock(config, {:ok, %{}})
      agent_tool = ToolAdapter.to_agent_tool(config, build_tool())

      result = agent_tool.executor.(%{}, nil)

      assert result.content == []
    end
  end
end
