defmodule Eva.MCP.ToolAdapter do
  @moduledoc """
  Turns an MCP tool descriptor into an `Eva.Agent.Tools.AgentTool`.

  Names are prefixed `mcp__<server>__<tool>` so they can never collide with a
  built-in, and so a persisted transcript identifies an MCP-origin tool call
  from the name alone with no config lookup. The executor keeps the server's own
  name for the `tools/call` — nothing needs to un-mangle.
  """

  alias Eva.Agent.Messages
  alias Eva.Agent.Tools
  alias Eva.MCP.{Client, Config, Events}

  @max_name_length 64
  @hash_length 6

  @spec to_agent_tools(Config.t(), [Events.tool()]) :: [Tools.AgentTool.t()]
  def to_agent_tools(%Config{} = config, tools) do
    Enum.map(tools, &to_agent_tool(config, &1))
  end

  @spec to_agent_tool(Config.t(), Events.tool()) :: Tools.AgentTool.t()
  def to_agent_tool(%Config{} = config, %{name: name} = tool) do
    %Tools.AgentTool{
      name: tool_name(config.name, name),
      description: Map.get(tool, :description),
      input_schema: tool.input_schema,
      prompt_snippet: nil,
      executor: fn arguments ->
        case Client.whereis(config) do
          nil ->
            raise "MCP server #{config.name} is not running"

          pid ->
            Client.call_tool(pid, name, arguments)
            |> to_tool_result()
        end
      end
    }
  end

  @doc """
  Builds the model-facing name for an MCP tool.

  Sanitizes both halves and, when the result would exceed the provider limit,
  truncates and appends a hash of the full name so two long tools on the same
  server stay distinguishable.
  """
  @spec tool_name(String.t(), String.t()) :: String.t()
  def tool_name(server_name, tool_name) do
    full = "mcp__#{sanitize(server_name)}__#{sanitize(tool_name)}"

    if String.length(full) <= @max_name_length do
      full
    else
      hash =
        :sha256
        |> :crypto.hash(full)
        |> Base.encode16(case: :lower)
        |> binary_part(0, @hash_length)

      String.slice(full, 0, @max_name_length - @hash_length - 1) <> "_" <> hash
    end
  end

  defp sanitize(name), do: String.replace(name, ~r/[^a-zA-Z0-9_-]/, "_")

  # `AgentToolResult` carries no error flag — `Loop.execute_tool/2` derives it
  # by rescuing (`loop.ex:314`). So raising is the only way to mark a call as
  # failed, and both of MCP's failure modes go through it:
  #
  #   * a JSON-RPC `error` — the call itself was rejected
  #   * `isError: true` on an ordinary result — the tool ran and failed, and its
  #     content is the explanation meant for the model
  defp to_tool_result({:ok, %{"isError" => true} = result}), do: raise(error_text(result))

  defp to_tool_result({:ok, result}) do
    %Tools.AgentToolResult{content: to_content(Map.get(result, "content", []))}
  end

  defp to_tool_result({:error, %{"message" => message}}), do: raise(message)
  defp to_tool_result({:error, reason}), do: raise(inspect(reason))

  defp error_text(result) do
    case to_content(Map.get(result, "content", [])) do
      [] -> "Tool call failed"
      content -> content |> Enum.map_join("\n", &content_text/1) |> String.trim()
    end
  end

  defp content_text(%Messages.TextContent{text: text}), do: text
  defp content_text(%Messages.ImageContent{mime_type: mime_type}), do: "[image #{mime_type}]"

  defp to_content(blocks) when is_list(blocks), do: Enum.map(blocks, &to_content_block/1)
  defp to_content(_blocks), do: []

  defp to_content_block(%{"type" => "text", "text" => text}) do
    %Messages.TextContent{text: text}
  end

  defp to_content_block(%{"type" => "image", "data" => data, "mimeType" => mime_type}) do
    %Messages.ImageContent{data: data, mime_type: mime_type}
  end

  # Audio, resource, and resource_link blocks have no transcript representation
  # yet. Stringify rather than dropping them, so the model at least sees that
  # something came back.
  defp to_content_block(block), do: %Messages.TextContent{text: JSON.encode!(block)}
end
