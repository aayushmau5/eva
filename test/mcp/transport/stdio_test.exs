defmodule Eva.MCP.Transport.StdioTest do
  use ExUnit.Case, async: true

  alias Eva.MCP.Config
  alias Eva.MCP.Transport.Stdio

  @echo_cmd "bash"
  @echo_script "while IFS= read -r line; do printf '%s\\n' \"$line\"; done"

  @stderr_echo_cmd "bash"
  @stderr_echo_script "while IFS= read -r line; do echo log >&2; printf '%s\\n' \"$line\"; done"

  # ---------------------------------------------------------------------------
  # split_lines/2
  # ---------------------------------------------------------------------------

  describe "split_lines/2" do
    test "splits data on newlines" do
      assert {["hello", "world"], ""} =
               Stdio.split_lines("", "hello\nworld\n")
    end

    test "prepends existing buffer to incoming data" do
      assert {["hello"], "wor"} = Stdio.split_lines("hel", "lo\nwor")
    end

    test "returns empty lines and empty remainder when data is empty" do
      assert {[], ""} = Stdio.split_lines("", "")
      assert {[], "buf"} = Stdio.split_lines("", "buf")
    end

    test "carries partial line as remainder" do
      assert {[], "incomplete"} = Stdio.split_lines("", "incomplete")

      assert {["complete"], "incomplete"} =
               Stdio.split_lines("", "complete\nincomplete")
    end

    test "splits multiple lines from a single chunk" do
      assert {["a", "b", "c"], ""} =
               Stdio.split_lines("", "a\nb\nc\n")
    end

    test "drops blank lines" do
      assert {["a", "b"], ""} = Stdio.split_lines("", "a\n\nb\n")
    end

    test "carries state across calls via remainder" do
      {lines1, buf1} = Stdio.split_lines("", "hello\nwor")
      assert lines1 == ["hello"]
      assert buf1 == "wor"

      {lines2, buf2} = Stdio.split_lines(buf1, "ld\n!")
      assert lines2 == ["world"]
      assert buf2 == "!"

      {lines3, _buf3} = Stdio.split_lines(buf2, "\n")
      assert lines3 == ["!"]
    end

    test "handles trailing newline without producing blank line count" do
      assert {["content"], ""} = Stdio.split_lines("", "content\n")
    end
  end

  # ---------------------------------------------------------------------------
  # handle_message/2
  # ---------------------------------------------------------------------------

  describe "handle_message/2 :stdout" do
    test "returns frames with split lines and updated buffer" do
      transport = %Stdio{os_pid: 1, buffer: ""}

      assert {:frames, ["hello"], updated} =
               Eva.MCP.Transport.handle_message(transport, {:stdout, 1, "hello\n"})

      assert updated.buffer == ""
    end

    test "accumulates partial data in buffer" do
      transport = %Stdio{os_pid: 1, buffer: "hel"}

      assert {:frames, ["hello"], updated} =
               Eva.MCP.Transport.handle_message(transport, {:stdout, 1, "lo\n"})

      assert updated.buffer == ""
    end
  end

  describe "handle_message/2 :stderr" do
    test "returns log with split lines and updated stderr buffer" do
      transport = %Stdio{os_pid: 1, stderr_buffer: ""}

      assert {:log, ["error line"], updated} =
               Eva.MCP.Transport.handle_message(transport, {:stderr, 1, "error line\n"})

      assert updated.stderr_buffer == ""
    end

    test "accumulates partial stderr data" do
      transport = %Stdio{os_pid: 1, stderr_buffer: "err"}

      assert {:log, ["error"], updated} =
               Eva.MCP.Transport.handle_message(transport, {:stderr, 1, "or\n"})

      assert updated.stderr_buffer == ""
    end
  end

  describe "handle_message/2 :DOWN" do
    test "returns closed with reason on matching pids" do
      exec_pid = self()
      transport = %Stdio{os_pid: 1, exec_pid: exec_pid}

      assert {:closed, :normal} =
               Eva.MCP.Transport.handle_message(
                 transport,
                 {:DOWN, 1, :process, exec_pid, :normal}
               )
    end
  end

  describe "handle_message/2 filtering" do
    test "ignores stdout from wrong os_pid" do
      transport = %Stdio{os_pid: 1}

      assert :ignore =
               Eva.MCP.Transport.handle_message(transport, {:stdout, 99, "data\n"})
    end

    test "ignores stderr from wrong os_pid" do
      transport = %Stdio{os_pid: 1}

      assert :ignore =
               Eva.MCP.Transport.handle_message(transport, {:stderr, 99, "data\n"})
    end

    test "ignores DOWN with wrong os_pid" do
      transport = %Stdio{os_pid: 1, exec_pid: self()}

      assert :ignore =
               Eva.MCP.Transport.handle_message(
                 transport,
                 {:DOWN, 99, :process, self(), :normal}
               )
    end

    test "ignores DOWN with wrong exec_pid" do
      other_pid = spawn(fn -> :ok end)
      transport = %Stdio{os_pid: 1, exec_pid: self()}

      assert :ignore =
               Eva.MCP.Transport.handle_message(
                 transport,
                 {:DOWN, 1, :process, other_pid, :normal}
               )
    end

    test "ignores unknown message types" do
      transport = %Stdio{os_pid: 1}

      assert :ignore = Eva.MCP.Transport.handle_message(transport, {:exit, 1, 0})
      assert :ignore = Eva.MCP.Transport.handle_message(transport, :garbage)
    end
  end

  # ---------------------------------------------------------------------------
  # send_message/2
  # ---------------------------------------------------------------------------

  describe "send_message/2" do
    test "returns error when not connected" do
      assert {:error, :not_connected} =
               Eva.MCP.Transport.send_message(%Stdio{os_pid: nil}, "irrelevant")
    end
  end

  # ---------------------------------------------------------------------------
  # close/1
  # ---------------------------------------------------------------------------

  describe "close/1" do
    test "returns :ok when already closed" do
      assert :ok = Eva.MCP.Transport.close(%Stdio{os_pid: nil})
    end
  end

  # ---------------------------------------------------------------------------
  # connect/1 — error paths
  # ---------------------------------------------------------------------------

  describe "connect/1 errors" do
    test "returns :missing_command for nil command" do
      config = build_config(nil)

      assert {:error, :missing_command} = Stdio.connect(config)
    end

    test "returns {:executable_not_found, name} for nonexistent command" do
      config = build_config("nonexistent_cmd_xyz_123")

      assert {:error, {:executable_not_found, "nonexistent_cmd_xyz_123"}} =
               Stdio.connect(config)
    end
  end

  # ---------------------------------------------------------------------------
  # connect/1 — integration with a real echo process
  # ---------------------------------------------------------------------------

  describe "connect/1 with echo process" do
    test "connects and returns a transport struct" do
      config = build_config(@echo_cmd, ["-c", @echo_script])
      {:ok, transport} = Stdio.connect(config)

      assert transport.os_pid > 0
      assert is_pid(transport.exec_pid)
      assert transport.config == config
      assert transport.buffer == ""

      Eva.MCP.Transport.close(transport)
    end

    test "send_message writes to child stdin, stdout arrives as message" do
      config = build_config(@echo_cmd, ["-c", @echo_script])
      {:ok, transport} = Stdio.connect(config)
      os_pid = transport.os_pid
      msg = ~s({"jsonrpc":"2.0","id":1,"result":"ok"})

      try do
        Eva.MCP.Transport.send_message(transport, msg)

        assert_receive {:stdout, ^os_pid, data}, 2000

        {:frames, lines, _t} =
          Eva.MCP.Transport.handle_message(transport, {:stdout, os_pid, data})

        assert [msg] == lines
      after
        Eva.MCP.Transport.close(transport)
      end
    end

    test "stderr output surfaces as log lines" do
      config = build_config(@stderr_echo_cmd, ["-c", @stderr_echo_script])
      {:ok, transport} = Stdio.connect(config)
      os_pid = transport.os_pid

      try do
        Eva.MCP.Transport.send_message(transport, "hello")

        assert_receive {:stderr, ^os_pid, _stderr_data}, 2000
      after
        Eva.MCP.Transport.close(transport)
      end
    end

    test "close shuts down the process" do
      config = build_config(@echo_cmd, ["-c", @echo_script])
      {:ok, transport} = Stdio.connect(config)
      os_pid = transport.os_pid
      exec_pid = transport.exec_pid

      Eva.MCP.Transport.send_message(transport, "ping")
      assert_receive {:stdout, ^os_pid, _}, 2000

      Eva.MCP.Transport.close(transport)

      assert_receive {:DOWN, ^os_pid, :process, ^exec_pid, _reason}, 5000
    end

    test "handles multiple messages across the connection" do
      config = build_config(@echo_cmd, ["-c", @echo_script])
      {:ok, transport} = Stdio.connect(config)
      os_pid = transport.os_pid

      try do
        Enum.reduce(1..3, transport, fn i, t ->
          msg = "msg#{i}"
          Eva.MCP.Transport.send_message(t, msg)

          assert_receive {:stdout, ^os_pid, data}, 2000

          {:frames, lines, updated} =
            Eva.MCP.Transport.handle_message(t, {:stdout, os_pid, data})

          assert [^msg] = lines
          updated
        end)
      after
        Eva.MCP.Transport.close(transport)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  defp build_config(command, args \\ []) do
    %Config{
      name: "test",
      type: :stdio,
      config: %Config.Stdio{command: command, args: args}
    }
  end
end
