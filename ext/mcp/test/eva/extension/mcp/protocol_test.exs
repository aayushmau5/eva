defmodule Eva.Extension.MCP.ProtocolTest do
  use ExUnit.Case

  alias Eva.Extension.MCP.Protocol

  describe "initialize_params/0" do
    test "returns params with protocol version, empty capabilities, and client info" do
      params = Protocol.initialize_params()

      assert %{
               protocolVersion: "2025-06-18",
               capabilities: %{},
               clientInfo: %{name: "eva", version: "0.1.0"}
             } = params
    end
  end

  describe "tools_list_params/0" do
    test "returns nil when no cursor given" do
      assert Protocol.tools_list_params() == nil
    end

    test "returns nil for explicit nil cursor" do
      assert Protocol.tools_list_params(nil) == nil
    end
  end

  describe "tools_list_params/1" do
    test "returns map with cursor when cursor is provided" do
      assert Protocol.tools_list_params("next-page") == %{cursor: "next-page"}
    end
  end

  describe "tools_call_params/2" do
    test "returns map with name and arguments" do
      assert Protocol.tools_call_params("search", %{query: "hello"}) == %{
               name: "search",
               arguments: %{query: "hello"}
             }
    end

    test "defaults arguments to empty map when nil" do
      assert Protocol.tools_call_params("echo", nil) == %{
               name: "echo",
               arguments: %{}
             }
    end
  end

  # -- parse_initialize_result/1 --

  describe "parse_initialize_result/1" do
    test "parses a valid 2025-06-18 result with all fields present" do
      result = %{
        "protocolVersion" => "2025-06-18",
        "serverInfo" => %{
          "name" => "test-server",
          "version" => "1.0.0"
        },
        "capabilities" => %{
          "tools" => %{"listChanged" => true},
          "resources" => %{"subscribe" => true, "listChanged" => false},
          "prompts" => %{"listChanged" => false}
        },
        "instructions" => "Use this server wisely"
      }

      assert {:ok, parsed} = Protocol.parse_initialize_result(result)

      assert parsed.protocol_version == "2025-06-18"
      assert parsed.server_name == "test-server"
      assert parsed.server_version == "1.0.0"
      assert parsed.instructions == "Use this server wisely"

      assert parsed.capabilities.tools == %{supported: true, list_changed: true}

      assert parsed.capabilities.resources == %{
               supported: true,
               subscribe: true,
               list_changed: false
             }

      assert parsed.capabilities.prompts == %{supported: true, list_changed: false}
      assert parsed.capabilities.logging == %{supported: false}
    end

    test "parses a valid 2025-03-26 result" do
      result = %{
        "protocolVersion" => "2025-03-26",
        "capabilities" => %{}
      }

      assert {:ok, parsed} = Protocol.parse_initialize_result(result)
      assert parsed.protocol_version == "2025-03-26"
    end

    test "returns error for unsupported protocol version" do
      result = %{"protocolVersion" => "2024-11-05"}

      assert {:error, {:unsupported_version, "2024-11-05"}} =
               Protocol.parse_initialize_result(result)
    end

    test "returns error when protocolVersion is missing" do
      result = %{"capabilities" => %{}}

      assert {:error, {:unsupported_version, nil}} =
               Protocol.parse_initialize_result(result)
    end

    test "defaults server name, version, and instructions when absent" do
      result = %{
        "protocolVersion" => "2025-06-18",
        "capabilities" => %{"logging" => %{}}
      }

      assert {:ok, parsed} = Protocol.parse_initialize_result(result)
      assert parsed.server_name == nil
      assert parsed.server_version == nil
      assert parsed.instructions == nil
      assert parsed.capabilities.logging == %{supported: true}
    end

    test "handles missing capabilities map" do
      result = %{"protocolVersion" => "2025-06-18"}

      assert {:ok, parsed} = Protocol.parse_initialize_result(result)

      assert parsed.capabilities.tools == %{supported: false, list_changed: false}

      assert parsed.capabilities.resources == %{
               supported: false,
               subscribe: false,
               list_changed: false
             }

      assert parsed.capabilities.prompts == %{supported: false, list_changed: false}
      assert parsed.capabilities.logging == %{supported: false}
    end
  end

  # -- parse_tools/1 --

  describe "parse_tools/1" do
    test "parses a list of tools" do
      result = %{
        "tools" => [
          %{
            "name" => "read_file",
            "description" => "Reads a file",
            "inputSchema" => %{
              "type" => "object",
              "properties" => %{"path" => %{"type" => "string"}}
            }
          },
          %{
            "name" => "write_file",
            "inputSchema" => %{"type" => "object", "properties" => %{}}
          }
        ]
      }

      {tools, cursor} = Protocol.parse_tools(result)

      assert cursor == nil
      assert length(tools) == 2

      [read_tool, write_tool] = tools

      assert read_tool.name == "read_file"
      assert read_tool.description == "Reads a file"
      assert read_tool.input_schema["properties"]["path"]["type"] == "string"

      assert write_tool.name == "write_file"
      assert write_tool.description == nil
      assert write_tool.input_schema["type"] == "object"
    end

    test "returns empty list when tools field is absent" do
      result = %{}

      {tools, cursor} = Protocol.parse_tools(result)

      assert tools == []
      assert cursor == nil
    end

    test "returns nextCursor for pagination" do
      result = %{
        "tools" => [%{"name" => "tool_a"}],
        "nextCursor" => "page-2"
      }

      {tools, cursor} = Protocol.parse_tools(result)

      assert length(tools) == 1
      assert cursor == "page-2"
    end

    test "skips tools with no name" do
      result = %{
        "tools" => [
          %{"description" => "no name here"},
          %{"name" => "valid_tool"},
          %{}
        ]
      }

      {tools, _cursor} = Protocol.parse_tools(result)

      assert length(tools) == 1
      assert hd(tools).name == "valid_tool"
    end

    test "defaults inputSchema to minimal object schema" do
      result = %{
        "tools" => [%{"name" => "bare_tool"}]
      }

      {tools, _cursor} = Protocol.parse_tools(result)

      assert hd(tools).input_schema == %{"type" => "object", "properties" => %{}}
    end
  end

  # -- encode_* / decode --

  describe "encode_request/3" do
    test "encodes a request with params" do
      json = Protocol.encode_request(1, "tools/call", %{name: "echo"}) |> IO.iodata_to_binary()
      assert {:ok, decoded} = JSON.decode(json)

      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == 1
      assert decoded["method"] == "tools/call"
      assert decoded["params"] == %{"name" => "echo"}
    end

    test "strips nil params from encoded request" do
      json = Protocol.encode_request(1, "tools/list") |> IO.iodata_to_binary()
      assert {:ok, decoded} = JSON.decode(json)

      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == 1
      assert decoded["method"] == "tools/list"
      refute Map.has_key?(decoded, "params")
    end
  end

  describe "encode_notification/2" do
    test "encodes a notification with params" do
      json =
        Protocol.encode_notification("notifications/initialized", %{}) |> IO.iodata_to_binary()

      assert {:ok, decoded} = JSON.decode(json)

      assert decoded["jsonrpc"] == "2.0"
      assert decoded["method"] == "notifications/initialized"
      refute Map.has_key?(decoded, "id")
      refute Map.has_key?(decoded, "params")
    end

    test "strips nil params from encoded notification" do
      json = Protocol.encode_notification("ping") |> IO.iodata_to_binary()
      assert {:ok, decoded} = JSON.decode(json)

      assert decoded["jsonrpc"] == "2.0"
      assert decoded["method"] == "ping"
      refute Map.has_key?(decoded, "id")
      refute Map.has_key?(decoded, "params")
    end
  end

  describe "encode_response/2" do
    test "encodes a success response" do
      json = Protocol.encode_response(42, %{status: "ok"}) |> IO.iodata_to_binary()
      assert {:ok, decoded} = JSON.decode(json)

      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == 42
      assert decoded["result"] == %{"status" => "ok"}
    end
  end

  describe "encode_error/4" do
    test "encodes an error response" do
      json = Protocol.encode_error(7, -32601, "Method not found") |> IO.iodata_to_binary()
      assert {:ok, decoded} = JSON.decode(json)

      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == 7
      assert decoded["error"] == %{"code" => -32601, "message" => "Method not found"}
    end
  end

  # -- decode/1 --

  describe "decode/1" do
    test "decodes a success response" do
      json = ~s({"jsonrpc":"2.0","id":1,"result":{"status":"ok"}})

      assert {:ok, {:response, 1, {:ok, %{"status" => "ok"}}}} = Protocol.decode(json)
    end

    test "decodes an error response" do
      json = ~s({"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"boom"}})

      assert {:ok, {:response, 2, {:error, %{"code" => -32000, "message" => "boom"}}}} =
               Protocol.decode(json)
    end

    test "decodes a request" do
      json = ~s({"jsonrpc":"2.0","id":3,"method":"tools/list"})

      assert {:ok, {:request, 3, "tools/list", %{}}} = Protocol.decode(json)
    end

    test "decodes a request with params" do
      json = ~s({"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"echo"}})

      assert {:ok, {:request, 4, "tools/call", %{"name" => "echo"}}} = Protocol.decode(json)
    end

    test "decodes a notification" do
      json = ~s({"jsonrpc":"2.0","method":"notifications/initialized"})

      assert {:ok, {:notification, "notifications/initialized", %{}}} = Protocol.decode(json)
    end

    test "decodes a notification with params" do
      json = ~s({"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info"}})

      assert {:ok, {:notification, "notifications/message", %{"level" => "info"}}} =
               Protocol.decode(json)
    end

    test "returns error for garbage JSON" do
      assert {:error, _reason} = Protocol.decode("not json at all")
    end

    test "returns error for unknown frame type" do
      json = ~s({"jsonrpc":"2.0"})

      assert {:error, {:invalid_frame, %{"jsonrpc" => "2.0"}}} = Protocol.decode(json)
    end

    test "returns error for completely empty object" do
      json = ~s({})

      assert {:error, {:invalid_frame, %{}}} = Protocol.decode(json)
    end

    test "roundtrip: encode_request -> decode gives a request" do
      encoded = Protocol.encode_request(99, "tools/list") |> IO.iodata_to_binary()
      {:ok, decoded} = Protocol.decode(encoded)

      assert {:ok, {:request, 99, "tools/list", _}} = {:ok, decoded}
    end

    test "roundtrip: encode_response -> decode gives a response" do
      encoded = Protocol.encode_response(10, %{hello: "world"}) |> IO.iodata_to_binary()
      {:ok, decoded} = Protocol.decode(encoded)

      assert {:ok, {:response, 10, {:ok, %{"hello" => "world"}}}} = {:ok, decoded}
    end

    test "roundtrip: encode_error -> decode gives an error response" do
      encoded = Protocol.encode_error(5, -1, "fail") |> IO.iodata_to_binary()
      {:ok, decoded} = Protocol.decode(encoded)

      assert {:ok, {:response, 5, {:error, %{"code" => -1, "message" => "fail"}}}} =
               {:ok, decoded}
    end

    test "roundtrip: encode_notification -> decode gives a notification" do
      encoded = Protocol.encode_notification("ping") |> IO.iodata_to_binary()
      {:ok, decoded} = Protocol.decode(encoded)

      assert {:ok, {:notification, "ping", _}} = {:ok, decoded}
    end
  end
end
