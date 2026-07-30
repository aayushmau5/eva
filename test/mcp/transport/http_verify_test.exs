defmodule Eva.MCP.Transport.HttpVerifyTest do
  use ExUnit.Case, async: false

  alias Eva.MCP.{Config, Protocol, Transport}
  alias Eva.MCP.Transport.Http
  alias Eva.Test.SseServer

  defp config(server) do
    %Config{
      scope_dir: :global,
      name: "verify",
      type: :http,
      config: %Config.Http{url: SseServer.base_url(server), headers: %{"X-Extra" => "yes"}},
      enabled: true
    }
  end

  defp wait_for_get(_server, 0), do: flunk("no GET request observed in time")

  defp wait_for_get(server, attempts) do
    case SseServer.last_request(server) do
      {req_line, _headers, _body} = req ->
        if String.starts_with?(req_line, "GET"),
          do: req,
          else: retry_wait_for_get(server, attempts)

      nil ->
        retry_wait_for_get(server, attempts)
    end
  end

  defp retry_wait_for_get(server, attempts) do
    Process.sleep(20)
    wait_for_get(server, attempts - 1)
  end

  defp drain(transport, timeout \\ 1_000) do
    receive do
      msg ->
        case Transport.handle_message(transport, msg) do
          {:frames, frames, transport} -> {:frames, frames, transport}
          {:ignore, transport} -> drain(transport, timeout)
          :ignore -> drain(transport, timeout)
        end
    after
      timeout -> :timeout
    end
  end

  test "application/json response decodes to a single frame" do
    {:ok, server} = SseServer.start_link()
    {:ok, transport} = Http.connect(config(server))

    body = JSON.encode!(%{jsonrpc: "2.0", id: 1, result: %{ok: true}})

    SseServer.set_response(server, """
    HTTP/1.1 200 OK\r
    Content-Type: application/json\r
    Content-Length: #{byte_size(body)}\r
    \r
    #{body}\
    """)

    :ok = Transport.send_message(transport, Protocol.encode_request(1, "initialize", %{}))

    assert {:frames, [line], _transport} = drain(transport)
    assert {:ok, decoded} = JSON.decode(line)
    assert decoded["result"] == %{"ok" => true}

    {req_line, headers, req_body} = SseServer.last_request(server)
    assert req_line =~ "POST"
    assert Enum.any?(headers, fn {k, v} -> k == "x-extra" and v == "yes" end)
    assert req_body =~ "initialize"

    SseServer.stop(server)
  end

  test "text/event-stream response yields one frame per event" do
    {:ok, server} = SseServer.start_link()
    {:ok, transport} = Http.connect(config(server))

    progress =
      JSON.encode!(%{jsonrpc: "2.0", method: "notifications/progress", params: %{progress: 1}})

    result = JSON.encode!(%{jsonrpc: "2.0", id: 2, result: %{done: true}})

    sse_body = "data: #{progress}\n\ndata: #{result}\n\n"

    SseServer.set_response(server, """
    HTTP/1.1 200 OK\r
    Content-Type: text/event-stream\r
    Mcp-Session-Id: sess-123\r
    Transfer-Encoding: chunked\r
    \r
    #{Integer.to_string(byte_size(sse_body), 16)}\r
    #{sse_body}\r
    0\r
    \r
    """)

    :ok = Transport.send_message(transport, Protocol.encode_request(2, "tools/call", %{}))

    assert {:frames, [line1], transport} = drain(transport)
    assert {:ok, %{"method" => "notifications/progress"}} = JSON.decode(line1)
    assert transport.session_id == "sess-123"

    assert {:frames, [line2], _transport} = drain(transport)
    assert {:ok, %{"id" => 2, "result" => %{"done" => true}}} = JSON.decode(line2)

    SseServer.stop(server)
  end

  test "non-2xx status synthesizes a JSON-RPC error frame for the request id" do
    {:ok, server} = SseServer.start_link()
    {:ok, transport} = Http.connect(config(server))

    SseServer.set_response(server, """
    HTTP/1.1 500 Internal Server Error\r
    Content-Type: text/plain\r
    Content-Length: 4\r
    \r
    oops\
    """)

    :ok = Transport.send_message(transport, Protocol.encode_request(3, "tools/call", %{}))

    assert {:frames, [line], _transport} = drain(transport)

    assert {:ok, %{"id" => 3, "error" => %{"code" => -32000, "message" => message}}} =
             JSON.decode(line)

    assert message =~ "HTTP 500"
    assert message =~ "oops"

    SseServer.stop(server)
  end

  test "a failed notification (no id) is dropped, not synthesized" do
    {:ok, server} = SseServer.start_link()
    {:ok, transport} = Http.connect(config(server))

    SseServer.set_response(server, """
    HTTP/1.1 500 Internal Server Error\r
    Content-Type: text/plain\r
    Content-Length: 0\r
    \r
    """)

    :ok =
      Transport.send_message(
        transport,
        Protocol.encode_notification("notifications/initialized", nil)
      )

    assert drain(transport, 300) == :timeout

    SseServer.stop(server)
  end

  test "listening stream starts after the first response, carrying session id + accept header" do
    {:ok, server} = SseServer.start_link()
    {:ok, transport} = Http.connect(config(server))

    body = JSON.encode!(%{jsonrpc: "2.0", id: 1, result: %{}})

    SseServer.set_response(server, """
    HTTP/1.1 200 OK\r
    Content-Type: application/json\r
    Mcp-Session-Id: sess-listen\r
    Content-Length: #{byte_size(body)}\r
    \r
    #{body}\
    """)

    :ok = Transport.send_message(transport, Protocol.encode_request(1, "initialize", %{}))

    assert {:frames, [_line], transport} = drain(transport)
    assert transport.session_id == "sess-listen"

    # The listening GET is spawned right after headers land, independent of
    # this process draining the POST's own frame — poll briefly for it.
    {req_line, headers, _body} = wait_for_get(server, 50)
    assert req_line =~ "GET"
    assert Enum.any?(headers, fn {k, v} -> k == "accept" and v == "text/event-stream" end)
    assert Enum.any?(headers, fn {k, v} -> k == "mcp-session-id" and v == "sess-listen" end)

    :ok = Transport.close(transport)
    SseServer.stop(server)
  end
end
