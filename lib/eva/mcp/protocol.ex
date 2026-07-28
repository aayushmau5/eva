defmodule Eva.MCP.Protocol do
  @moduledoc """
  To parse JSON-rpc messages.
  Bread & butter of MCP.
  """

  @jsonrpc_version "2.0"
  @protocol_version "2025-06-18"
  @supported_versions ["2025-06-18", "2025-03-26"]
  @client_info %{name: "eva", version: "0.1.0"}

  alias Eva.MCP.Events

  @type frame ::
          {:response, id :: integer(), result :: {:ok, map()} | {:error, map()}}
          | {:notification, method :: String.t(), params :: list() | map()}
          | {:request, id :: integer(), method :: String.t(), params :: list() | map()}

  @typedoc """
  What the server said it can do. A capability the server omits is reported as
  `supported: false` — the client must not send requests for it.
  """
  @type capabilities :: %{
          tools: %{supported: boolean(), list_changed: boolean()},
          resources: %{supported: boolean(), subscribe: boolean(), list_changed: boolean()},
          prompts: %{supported: boolean(), list_changed: boolean()},
          logging: %{supported: boolean()}
        }

  @type initialize_result :: %{
          protocol_version: String.t(),
          server_name: String.t() | nil,
          server_version: String.t() | nil,
          capabilities: capabilities(),
          instructions: String.t() | nil
        }

  def initialize_params() do
    %{protocolVersion: @protocol_version, capabilities: %{}, clientInfo: @client_info}
  end

  def tools_list_params(cursor \\ nil)

  def tools_list_params(cursor) when is_nil(cursor) do
  end

  def tools_list_params(cursor) do
    %{cursor: cursor}
  end

  def tools_call_params(name, arguments) do
    %{name: name, arguments: arguments || %{}}
  end

  # -- Result parsing --
  # Server -> Client

  @doc """
  Parses the `initialize` response.

  The server picks the protocol version, not us — it may answer with something
  other than what we proposed. An unsupported answer is fatal for the connection.
  """
  @spec parse_initialize_result(map()) ::
          {:ok, initialize_result()} | {:error, {:unsupported_version, term()}}
  def parse_initialize_result(%{"protocolVersion" => version} = result)
      when version in @supported_versions do
    server_info = Map.get(result, "serverInfo", %{})

    {:ok,
     %{
       protocol_version: version,
       server_name: Map.get(server_info, "name"),
       server_version: Map.get(server_info, "version"),
       capabilities: parse_capabilities(Map.get(result, "capabilities", %{})),
       instructions: Map.get(result, "instructions")
     }}
  end

  def parse_initialize_result(result) do
    {:error, {:unsupported_version, Map.get(result, "protocolVersion")}}
  end

  @doc """
  Parses a `tools/list` response into tools plus the pagination cursor.

  A non-nil cursor means the server has more tools to hand over — the caller
  must keep requesting with it until it comes back `nil`.
  """
  @spec parse_tools(map()) :: {[Events.tool()], String.t() | nil}
  def parse_tools(result) do
    tools =
      result
      |> Map.get("tools", [])
      |> Enum.flat_map(&parse_tool/1)

    {tools, Map.get(result, "nextCursor")}
  end

  # -- Encoding --
  # Client -> Server
  def encode_request(id, method, params \\ nil) do
    %{jsonrpc: @jsonrpc_version, id: id, method: method, params: params}
    |> encode()
  end

  def encode_notification(method, params \\ nil) do
    %{jsonrpc: @jsonrpc_version, method: method, params: params}
    |> encode()
  end

  def encode_response(id, result) do
    %{jsonrpc: @jsonrpc_version, id: id, result: result}
    |> encode()
  end

  def encode_error(id, code, message) do
    %{jsonrpc: @jsonrpc_version, id: id, error: %{code: code, message: message}}
    |> encode()
  end

  # -- Classification --
  # Server -> Client
  @spec decode(binary()) :: {:ok, frame()} | {:error, term()}
  def decode(binary) do
    case JSON.decode(binary) do
      {:ok, json_map} ->
        get_message_type(json_map)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp encode(%{params: params} = map) do
    case params do
      %{} ->
        if map_size(params) == 0 do
          Map.pop(map, :params) |> elem(1)
        else
          map
        end

      nil ->
        Map.pop(map, :params) |> elem(1)
    end
    |> JSON.encode_to_iodata!()
  end

  defp encode(map) do
    JSON.encode_to_iodata!(map)
  end

  defp parse_capabilities(capabilities) do
    %{
      tools: %{
        supported: Map.has_key?(capabilities, "tools"),
        list_changed: sub_capability?(capabilities, "tools", "listChanged")
      },
      resources: %{
        supported: Map.has_key?(capabilities, "resources"),
        subscribe: sub_capability?(capabilities, "resources", "subscribe"),
        list_changed: sub_capability?(capabilities, "resources", "listChanged")
      },
      prompts: %{
        supported: Map.has_key?(capabilities, "prompts"),
        list_changed: sub_capability?(capabilities, "prompts", "listChanged")
      },
      logging: %{supported: Map.has_key?(capabilities, "logging")}
    }
  end

  defp sub_capability?(capabilities, key, sub_key) do
    case Map.get(capabilities, key) do
      value when is_map(value) -> Map.get(value, sub_key) == true
      _ -> false
    end
  end

  defp parse_tool(%{"name" => name} = tool) when is_binary(name) do
    [
      %{
        name: name,
        description: Map.get(tool, "description"),
        input_schema: Map.get(tool, "inputSchema") || %{"type" => "object", "properties" => %{}}
      }
    ]
  end

  # A tool with no name can never be called — drop it instead of failing the
  # whole discovery over one bad entry.
  defp parse_tool(_tool), do: []

  defp get_message_type(json_map) do
    case json_map do
      # Response
      %{"result" => result, "id" => id} ->
        {:ok, {:response, id, {:ok, result}}}

      # Response
      %{"error" => error, "id" => id} ->
        {:ok, {:response, id, {:error, error}}}

      # Request
      %{"method" => method, "id" => id} ->
        {:ok, {:request, id, method, Map.get(json_map, "params", %{})}}

      # Notification
      %{"method" => method} ->
        {:ok, {:notification, method, Map.get(json_map, "params", %{})}}

      _ ->
        {:error, {:invalid_frame, json_map}}
    end
  end
end
