defmodule Eva.Coding.ShellExecTest do
  use ExUnit.Case

  alias Eva.Coding.ShellExec

  @tmp_root Path.expand("tmp/test")

  setup do
    tmp =
      @tmp_root
      |> Path.join("#{System.unique_integer([:positive, :monotonic])}")
      |> tap(&File.mkdir_p!/1)

    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  defp write_file(tmp, filename, content) do
    path = Path.join(tmp, filename)
    File.write!(path, content)
    path
  end

  describe "run/2" do
    test "returns output and zero exit status for a successful command" do
      result = ShellExec.run("echo hello")

      assert result.output == "hello\n"
      assert result.exit_status == 0
      refute result.timed_out
      refute result.cancelled
    end

    test "returns multi-line output" do
      result = ShellExec.run("printf 'a\\nb\\nc\\n'")

      assert result.output == "a\nb\nc\n"
    end

    test "captures stderr merged into stdout" do
      result = ShellExec.run("echo stdout; echo stderr >&2")

      assert result.output =~ "stdout"
      assert result.output =~ "stderr"
    end

    test "returns non-zero exit status when command fails" do
      result = ShellExec.run("exit 3")

      assert result.exit_status == 3
      assert result.output == ""
    end

    test "returns error exit status for a command not found" do
      result = ShellExec.run("nonexistent_command_xyz_123")

      assert result.exit_status != 0
      refute result.timed_out
      refute result.cancelled
    end

    test "kills on timeout and returns timed_out: true" do
      result = ShellExec.run("sleep 30", timeout: 100)

      assert result.timed_out
      refute result.cancelled
    end

    test "runs command in the given cwd", %{tmp: tmp} do
      write_file(tmp, "marker.txt", "found")
      result = ShellExec.run("cat marker.txt", cwd: tmp)

      assert result.output == "found"
      assert result.exit_status == 0
    end

    test "honours the :executable option" do
      result = ShellExec.run("echo sh-ran", executable: "sh")

      assert result.output == "sh-ran\n"
      assert result.exit_status == 0
    end

    test "returns empty output for an empty command" do
      result = ShellExec.run(":")

      assert result.output == ""
      assert result.exit_status == 0
    end

    test "handles command that writes to stdout and then fails" do
      result = ShellExec.run("echo partial; exit 7")

      assert result.output == "partial\n"
      assert result.exit_status == 7
    end
  end

  describe "cancel/1" do
    test "sends a :cancel message to the task process" do
      task =
        Task.async(fn ->
          receive do
            :cancel -> :got_cancel
          end
        end)

      assert ShellExec.cancel(task) == :cancel
      assert Task.await(task) == :got_cancel
    end
  end

  describe "run_async/2 with cancel/1" do
    test "cancels a long-running command and returns cancelled: true" do
      task = ShellExec.run_async("sleep 30")

      Process.sleep(100)
      ShellExec.cancel(task)

      result = Task.await(task, :infinity)

      assert result.cancelled
      refute result.timed_out
    end

    test "cancelling an already-finished task is a no-op" do
      task = ShellExec.run_async("echo quick")

      Process.sleep(100)
      :cancel = ShellExec.cancel(task)

      result = Task.await(task, :infinity)

      assert result.output == "quick\n"
      assert result.exit_status == 0
      refute result.cancelled
      refute result.timed_out
    end
  end

  describe "result map fields" do
    test "has all expected keys" do
      result = ShellExec.run("echo x")

      assert is_map_key(result, :output)
      assert is_map_key(result, :exit_status)
      assert is_map_key(result, :timed_out)
      assert is_map_key(result, :cancelled)
    end

    test "successful run has timed_out and cancelled as false" do
      result = ShellExec.run("true")

      refute result.timed_out
      refute result.cancelled
    end
  end
end
