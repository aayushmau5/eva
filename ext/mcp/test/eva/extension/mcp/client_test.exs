defmodule Eva.Extension.MCP.ClientTest do
  use ExUnit.Case, async: true

  alias Eva.Extension.MCP.Client
  alias Eva.Extension.MCP.Client.State
  alias Eva.Extension.MCP.Config
  alias Eva.Extension.MCP.Events
  alias Eva.Extension.MCP.MockTransport

  defp unique_name, do: "test_#{System.unique_integer([:positive])}"

  defp build_config(name \\ nil) do
    %Config{
      scope_dir: :global,
      name: name || unique_name(),
      type: :stdio,
      config: %Config.Stdio{command: "nonexistent_command_testing_xyz"},
      enabled: true
    }
  end

  defp build_state(opts \\ []) do
    config = Keyword.get(opts, :config, build_config())

    %State{
      config: config,
      transport: Keyword.get(opts, :transport),
      status: Keyword.get(opts, :status, :connecting),
      pending: Keyword.get(opts, :pending, %{}),
      next_id: Keyword.get(opts, :next_id, 1),
      tools: Keyword.get(opts, :tools, []),
      server_info: Keyword.get(opts, :server_info),
      attempt: Keyword.get(opts, :attempt, 0)
    }
  end

  defp server_info_fixture do
    %{
      protocol_version: "2025-06-18",
      server_name: "test-server",
      server_version: "1.0.0",
      capabilities: %{tools: %{supported: true, list_changed: false}},
      instructions: nil
    }
  end

  defp decode_iodata(iodata) do
    iodata |> IO.iodata_to_binary() |> JSON.decode()
  end

  describe "start_link/1" do
    test "starts and registers via Registry" do
      name = unique_name()
      config = build_config(name)
      {:ok, pid} = Client.start_link(config)
      assert Process.alive?(pid)
      assert Client.whereis(config) == pid
    end
  end

  describe "whereis/1" do
    test "returns pid for registered client" do
      name = unique_name()
      config = build_config(name)
      {:ok, pid} = Client.start_link(config)
      assert Client.whereis(config) == pid
    end

    test "returns nil for unknown config" do
      config = build_config("nonexistent_#{unique_name()}")
      assert Client.whereis(config) == nil
    end
  end

  describe "handle_call :list_tools" do
    test "returns tools from state" do
      tools = [
        %{name: "tool1", description: "A tool", input_schema: %{"type" => "object"}},
        %{
          name: "tool2",
          description: nil,
          input_schema: %{"type" => "object", "properties" => %{}}
        }
      ]

      state = build_state(tools: tools)
      assert {:reply, ^tools, _state} = Client.handle_call(:list_tools, nil, state)
    end

    test "returns empty list when no tools discovered" do
      state = build_state()
      assert {:reply, [], _state} = Client.handle_call(:list_tools, nil, state)
    end
  end

  describe "handle_call :snapshot" do
    test "reflects failed state with nil server_info" do
      config = build_config("failed-server")
      state = build_state(config: config, status: :failed)
      {:reply, snapshot, _state} = Client.handle_call(:snapshot, nil, state)

      assert snapshot.server_name == "failed-server"
      assert snapshot.scope_dir == :global
      assert snapshot.status == :failed
      assert snapshot.tools == []
      assert snapshot.server_version == nil
      assert snapshot.protocol_version == nil
      assert snapshot.capabilities == %{}
    end

    test "reflects connecting state" do
      config = build_config("connecting-server")
      state = build_state(config: config, status: :connecting)
      {:reply, snapshot, _state} = Client.handle_call(:snapshot, nil, state)

      assert snapshot.status == :connecting
      assert snapshot.server_name == "connecting-server"
    end

    test "reflects connected state with server_info" do
      config = build_config("connected-server")
      info = server_info_fixture()
      state = build_state(config: config, status: :connected, server_info: info)

      {:reply, snapshot, _state} = Client.handle_call(:snapshot, nil, state)

      assert snapshot.server_name == "connected-server"
      assert snapshot.status == :connected
      assert snapshot.server_version == "1.0.0"
      assert snapshot.protocol_version == "2025-06-18"
      assert snapshot.capabilities == %{tools: %{supported: true, list_changed: false}}
    end

    test "includes tools in snapshot" do
      tools = [%{name: "t1", description: "d1", input_schema: %{}}]
      state = build_state(tools: tools)
      {:reply, snapshot, _state} = Client.handle_call(:snapshot, nil, state)

      assert snapshot.tools == tools
    end
  end

  describe "handle_call {:call_tool, name, args}" do
    test "sends request through mock transport and records pending" do
      mock = %MockTransport{test_pid: self()}
      state = build_state(transport: mock, status: :connected)

      {:noreply, new_state} =
        Client.handle_call({:call_tool, "my_tool", %{arg: 1}}, {self(), make_ref()}, state)

      assert_receive {:mcp_sent, request_data}

      {:ok, decoded} = decode_iodata(request_data)
      assert decoded["method"] == "tools/call"
      assert decoded["params"]["name"] == "my_tool"
      assert decoded["params"]["arguments"] == %{"arg" => 1}

      assert new_state.next_id == 2
      assert map_size(new_state.pending) == 1
    end

    test "returns error when transport send fails" do
      mock = %MockTransport{test_pid: self(), fail_send?: true}
      state = build_state(transport: mock, status: :connected)

      assert {:reply, {:error, :mock_failure}, _state} =
               Client.handle_call({:call_tool, "bad_tool", %{}}, {self(), make_ref()}, state)
    end

    test "handles nil arguments" do
      mock = %MockTransport{test_pid: self()}
      state = build_state(transport: mock, status: :connected)

      Client.handle_call({:call_tool, "no_args", nil}, {self(), make_ref()}, state)

      assert_receive {:mcp_sent, request_data}
      {:ok, decoded} = decode_iodata(request_data)
      assert decoded["params"]["arguments"] == %{}
    end
  end

  describe "handle_call {:call_tool_async, name, args, receiver}" do
    test "sends request and returns a reference" do
      mock = %MockTransport{test_pid: self()}
      state = build_state(transport: mock, status: :connected)
      receiver = self()

      {:reply, {:ok, ref}, new_state} =
        Client.handle_call({:call_tool_async, "async_tool", %{x: 1}, receiver}, nil, state)

      assert is_reference(ref)
      assert_receive {:mcp_sent, _}

      assert new_state.pending[1] == {:async, receiver, ref}
      assert new_state.next_id == 2
    end

    test "returns error when transport send fails" do
      mock = %MockTransport{test_pid: self(), fail_send?: true}
      state = build_state(transport: mock, status: :connected)

      assert {:reply, {:error, :mock_failure}, _state} =
               Client.handle_call({:call_tool_async, "bad", %{}, self()}, nil, state)
    end
  end

  describe "handle_info: response routing" do
    test "routes successful response to pending caller" do
      mock = %MockTransport{test_pid: self()}
      ref = make_ref()
      from = {self(), ref}

      state =
        build_state(
          transport: mock,
          status: :connected,
          pending: %{7 => {:caller, from}}
        )

      response_line =
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 7,
          "result" => %{"content" => [%{"type" => "text", "text" => "ok"}]}
        })

      {result, new_state} =
        Client.handle_info({:frame, response_line}, state)

      assert result == :noreply
      assert map_size(new_state.pending) == 0
      assert_receive {^ref, {:ok, %{"content" => [%{"type" => "text", "text" => "ok"}]}}}
    end

    test "routes error response to pending caller" do
      mock = %MockTransport{test_pid: self()}
      ref = make_ref()
      from = {self(), ref}

      state =
        build_state(
          transport: mock,
          status: :connected,
          pending: %{3 => {:caller, from}}
        )

      response_line =
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 3,
          "error" => %{"code" => -1, "message" => "bad"}
        })

      {result, new_state} =
        Client.handle_info({:frame, response_line}, state)

      assert result == :noreply
      assert map_size(new_state.pending) == 0
      assert_receive {^ref, {:error, %{"code" => -1, "message" => "bad"}}}
    end

    test "routes successful response to async caller" do
      mock = %MockTransport{test_pid: self()}
      ref = make_ref()
      receiver = self()

      state =
        build_state(
          transport: mock,
          status: :connected,
          pending: %{5 => {:async, receiver, ref}}
        )

      response_line =
        JSON.encode!(%{"jsonrpc" => "2.0", "id" => 5, "result" => %{"data" => "async-ok"}})

      {result, new_state} =
        Client.handle_info({:frame, response_line}, state)

      assert result == :noreply
      assert map_size(new_state.pending) == 0
      assert_receive {:mcp_result, ^ref, %{"data" => "async-ok"}}
    end

    test "routes error response to async caller" do
      mock = %MockTransport{test_pid: self()}
      ref = make_ref()
      receiver = self()

      state =
        build_state(
          transport: mock,
          status: :connected,
          pending: %{9 => {:async, receiver, ref}}
        )

      response_line =
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 9,
          "error" => %{"code" => -2, "message" => "err"}
        })

      {result, new_state} =
        Client.handle_info({:frame, response_line}, state)

      assert result == :noreply
      assert map_size(new_state.pending) == 0
      assert_receive {:mcp_error, ^ref, %{"code" => -2, "message" => "err"}}
    end

    test "ignores response for unknown id" do
      mock = %MockTransport{test_pid: self()}
      state = build_state(transport: mock, status: :connected, pending: %{})

      response_line =
        JSON.encode!(%{"jsonrpc" => "2.0", "id" => 99, "result" => %{}})

      {result, new_state} =
        Client.handle_info({:frame, response_line}, state)

      assert result == :noreply
      assert new_state.pending == %{}
    end
  end

  describe "handle_info: notifications" do
    test "handles notifications/message and publishes ServerLog" do
      name = unique_name()
      config = build_config(name)
      :pg.join(Eva.PG, {:mcp, :global, name}, self())

      mock = %MockTransport{test_pid: self()}
      state = build_state(transport: mock, status: :connected, config: config)

      notification =
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "notifications/message",
          "params" => %{
            "level" => "warning",
            "logger" => "server-logger",
            "data" => "something happened"
          }
        })

      Client.handle_info({:frame, notification}, state)

      assert_receive %Events.ServerLog{
        server_name: ^name,
        scope_dir: :global,
        level: :warning,
        logger: "server-logger",
        message: "something happened"
      }
    end

    test "unknown notifications are silently ignored" do
      mock = %MockTransport{test_pid: self()}
      state = build_state(transport: mock, status: :connected)

      notification =
        JSON.encode!(%{"jsonrpc" => "2.0", "method" => "some/unknown/notification"})

      {result, ^state} = Client.handle_info({:frame, notification}, state)
      assert result == :noreply
    end
  end

  describe "handle_info: stderr" do
    test "publishes stderr lines as ServerLog" do
      name = unique_name()
      config = build_config(name)
      :pg.join(Eva.PG, {:mcp, :global, name}, self())

      mock = %MockTransport{test_pid: self()}
      state = build_state(transport: mock, status: :connected, config: config)

      Client.handle_info({:stderr, "error output line"}, state)

      assert_receive %Events.ServerLog{
        server_name: ^name,
        scope_dir: :global,
        level: :info,
        logger: "stderr",
        message: "error output line"
      }
    end
  end

  describe "handle_info: transport close / disconnect" do
    test "publishes ServerDisconnected on transport close" do
      name = unique_name()
      config = build_config(name)
      :pg.join(Eva.PG, {:mcp, :global, name}, self())

      mock = %MockTransport{test_pid: self()}
      state = build_state(transport: mock, status: :connected, config: config)

      Client.handle_info({:closed, :process_exit}, state)

      assert_receive %Events.ServerDisconnected{
        server_name: ^name,
        scope_dir: :global,
        reason: :process_exit
      }
    end

    test "fails all pending requests on disconnect" do
      ref1 = make_ref()
      ref2 = make_ref()
      from1 = {self(), ref1}
      from2 = {self(), ref2}

      mock = %MockTransport{test_pid: self()}

      state =
        build_state(
          transport: mock,
          status: :connected,
          pending: %{1 => {:caller, from1}, 2 => {:caller, from2}}
        )

      Client.handle_info({:closed, :process_exit}, state)

      assert_receive {^ref1, {:error, :disconnected}}
      assert_receive {^ref2, {:error, :disconnected}}
    end

    test "fails pending async callers on disconnect" do
      ref = make_ref()
      receiver = self()

      mock = %MockTransport{test_pid: self()}

      state =
        build_state(
          transport: mock,
          status: :connected,
          pending: %{1 => {:async, receiver, ref}}
        )

      Client.handle_info({:closed, :process_exit}, state)

      assert_receive {:mcp_error, ^ref, :disconnected}
    end

    test "sets status to failed after disconnect" do
      mock = %MockTransport{test_pid: self()}
      state = build_state(transport: mock, status: :connected)

      {:noreply, new_state} = Client.handle_info({:closed, :process_exit}, state)

      assert new_state.status == :failed
      assert new_state.transport == nil
      assert new_state.pending == %{}
    end
  end

  describe "handle_info: request from server" do
    test "replies with method_not_found for incoming requests" do
      mock = %MockTransport{test_pid: self()}
      state = build_state(transport: mock, status: :connected)

      request_line =
        JSON.encode!(%{"jsonrpc" => "2.0", "id" => 42, "method" => "some/method"})

      {:noreply, _state} = Client.handle_info({:frame, request_line}, state)

      assert_receive {:mcp_sent, response}
      {:ok, decoded} = decode_iodata(response)
      assert decoded["id"] == 42
      assert decoded["error"]["code"] == -32_601
      assert decoded["error"]["message"] == "Method not found"
    end
  end

  describe "handle_info: malformed frames" do
    test "does not crash on malformed JSON" do
      mock = %MockTransport{test_pid: self()}
      state = build_state(transport: mock, status: :connected)

      {:noreply, ^state} = Client.handle_info({:frame, "not json"}, state)
    end

    test "processes valid frames alongside malformed ones" do
      mock = %MockTransport{test_pid: self()}
      ref = make_ref()
      from = {self(), ref}

      state =
        build_state(
          transport: mock,
          status: :connected,
          pending: %{10 => {:caller, from}}
        )

      valid = JSON.encode!(%{"jsonrpc" => "2.0", "id" => 10, "result" => %{}})
      invalid = "not json at all"

      {:noreply, new_state} =
        Client.handle_info({:frames, [invalid, valid]}, state)

      assert map_size(new_state.pending) == 0
      assert_receive {^ref, {:ok, %{}}}
    end
  end

  describe "integration: connect failure" do
    test "enters failed state and publishes ServerError" do
      name = unique_name()
      config = build_config(name)
      :pg.join(Eva.PG, {:mcp, :global, name}, self())

      {:ok, pid} = Client.start_link(config)

      assert_receive %Events.ServerError{
                       server_name: ^name,
                       scope_dir: :global,
                       phase: :spawn
                     },
                     500

      snapshot = Client.snapshot(pid)
      assert snapshot.status == :failed
      assert snapshot.server_name == name
    end
  end

  describe "integration: full call_tool round-trip" do
    test "sends request, receives response, returns result to caller" do
      name = unique_name()
      config = build_config(name)
      {:ok, pid} = Client.start_link(config)

      Process.sleep(50)

      mock = %MockTransport{test_pid: self()}

      :sys.replace_state(pid, fn state ->
        %{
          state
          | transport: mock,
            status: :connected,
            server_info: server_info_fixture(),
            pending: %{},
            next_id: 1
        }
      end)

      task =
        Task.async(fn ->
          Client.call_tool(pid, "echo", %{text: "hello"})
        end)

      assert_receive {:mcp_sent, request_data}, 500
      {:ok, decoded} = decode_iodata(request_data)
      request_id = decoded["id"]

      response =
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => request_id,
          "result" => %{"content" => [%{"type" => "text", "text" => "world"}]}
        })

      send(pid, {:frame, response})

      result = Task.await(task, 500)
      assert {:ok, %{"content" => [%{"type" => "text", "text" => "world"}]}} = result

      GenServer.stop(pid)
    end

    test "routes tool call error back to caller" do
      name = unique_name()
      config = build_config(name)
      {:ok, pid} = Client.start_link(config)

      Process.sleep(50)

      mock = %MockTransport{test_pid: self()}

      :sys.replace_state(pid, fn state ->
        %{
          state
          | transport: mock,
            status: :connected,
            server_info: server_info_fixture(),
            pending: %{},
            next_id: 1
        }
      end)

      task =
        Task.async(fn ->
          Client.call_tool(pid, "failing_tool", %{})
        end)

      assert_receive {:mcp_sent, request_data}, 500
      {:ok, decoded} = decode_iodata(request_data)
      request_id = decoded["id"]

      response =
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => request_id,
          "error" => %{"code" => -32_000, "message" => "Tool not found"}
        })

      send(pid, {:frame, response})

      result = Task.await(task, 500)
      assert {:error, %{"code" => -32_000, "message" => "Tool not found"}} = result

      GenServer.stop(pid)
    end

    test "async call_tool sends result to receiver" do
      name = unique_name()
      config = build_config(name)
      {:ok, pid} = Client.start_link(config)

      Process.sleep(50)

      mock = %MockTransport{test_pid: self()}

      :sys.replace_state(pid, fn state ->
        %{
          state
          | transport: mock,
            status: :connected,
            server_info: server_info_fixture(),
            pending: %{},
            next_id: 1
        }
      end)

      {:ok, ref} = Client.call_tool_async(pid, "async_echo", %{x: 1}, self())

      assert_receive {:mcp_sent, request_data}, 500
      {:ok, decoded} = decode_iodata(request_data)
      request_id = decoded["id"]

      response =
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => request_id,
          "result" => %{"content" => [%{"type" => "text", "text" => "async-result"}]}
        })

      send(pid, {:frame, response})

      assert_receive {:mcp_result, ^ref,
                      %{"content" => [%{"type" => "text", "text" => "async-result"}]}},
                     500

      GenServer.stop(pid)
    end
  end
end
