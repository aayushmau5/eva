defmodule Eva.Coding.ShellExec do
  @moduledoc """
  Module runs a shell command with a timeout and a cooperative cancellation signal, and reliably kills the
  *entire process tree* (not just the immediate child) if either fires.

  Written by Sonnet 5 + GLM 5.2
  """

  @type result :: %{
          output: binary(),
          exit_status: term(),
          timed_out: boolean(),
          cancelled: boolean()
        }

  @doc """
  Starts `shell_command` under `cwd` and returns a `Task` immediately.

  ## Options

    * `:cwd` - working directory (default: `File.cwd!/0`)
    * `:timeout` - milliseconds before the process is killed, or `nil` for
      no timeout (default: `nil`)
    * `:executable` - override the shell binary that runs the command.
      Defaults to `"bash"` so commands run under a consistent shell regardless
      of the user's `$SHELL` (e.g. fish). The command is executed as
      `<executable> -c <command>`.

  Send a cancellation with `ShellExec.cancel/1` at any point while it's
  running; the task will kill the whole process tree and return with
  `cancelled: true`.
  """
  @spec run_async(String.t(), keyword()) :: Task.t()
  def run_async(shell_command, opts \\ []) do
    Task.Supervisor.async(Eva.TaskSupervisor, fn -> do_run(shell_command, opts) end)
  end

  @doc "Sends a cooperative cancellation signal to a task started by `run_async/2`."
  @spec cancel(Task.t()) :: :cancel
  def cancel(%Task{pid: pid}), do: send(pid, :cancel)

  @doc """
  Convenience wrapper that runs synchronously (blocks the calling process
  until the command finishes, times out, or — since no concurrent caller
  holds the Task reference — cannot be cancelled). For cancellable runs, use
  `run_async/2` + `cancel/1` from another process instead.
  """
  @spec run(String.t(), keyword()) :: result()
  def run(shell_command, opts \\ []) do
    shell_command
    |> run_async(opts)
    |> Task.await(:infinity)
  end

  # erlexec's exec-port runs with a minimal environment and may not resolve a
  # bare command name via PATH, so resolve the executable to an absolute path
  # up front. Falls back to the given name (letting :exec.run surface the
  # "cannot execute" error) if it isn't on PATH at all.
  defp resolve_executable(name) do
    case System.find_executable(name) do
      nil -> name
      path -> path
    end
  end

  defp do_run(shell_command, opts) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    timeout = Keyword.get(opts, :timeout)
    executable = resolve_executable(Keyword.get(opts, :executable, "bash"))

    base_opts = [
      # capture stdout as {:stdout, os_pid, data} messages
      :stdout,
      # merge stderr into the same stream
      {:stderr, :stdout},
      {:cd, cwd},
      # new process group, rooted at the child's own OS pid
      {:group, 0},
      # ensure the whole group (not just the immediate pid) is targeted on kill
      :kill_group,
      # get a {:DOWN, os_pid, :process, exec_pid, status} message on exit
      :monitor
    ]

    # Run as `<executable> -c <command>` (a real bash -c), not a shell string.
    # erlexec's :executable option does NOT do this — it treats the command as
    # a single argv element to that binary, so we pass an argv list instead,
    # which erlexec runs without an intervening login shell.
    argv = [executable, "-c", shell_command]

    case :exec.run(argv, base_opts) do
      {:ok, exec_pid, os_pid} ->
        deadline = timeout && System.monotonic_time(:millisecond) + timeout
        collect(os_pid, exec_pid, deadline, [], :running)

      {:error, reason} ->
        %{output: "", exit_status: {:error, reason}, timed_out: false, cancelled: false}
    end
  end

  defp collect(os_pid, exec_pid, deadline, acc, state) do
    receive do
      {:stdout, ^os_pid, data} ->
        collect(os_pid, exec_pid, deadline, [data | acc], state)

      {:DOWN, ^os_pid, :process, ^exec_pid, exit_reason} ->
        finalize(acc, exit_reason, state)

      :cancel ->
        # Immediate SIGKILL to the whole process group, no grace period
        :exec.kill(os_pid, 9)
        next_state = if state == :running, do: :cancelled, else: state
        # keep draining output until the DOWN message arrives, same as the
        collect(os_pid, exec_pid, nil, acc, next_state)

      # erlexec occasionally posts messages we don't model (e.g. flow-control
      # or error notices); discard them rather than letting them pile up in
      # the mailbox and stall the drain.
      _other ->
        collect(os_pid, exec_pid, deadline, acc, state)
    after
      time_left(deadline) ->
        :exec.kill(os_pid, 9)
        collect(os_pid, exec_pid, nil, acc, :timed_out)
    end
  end

  defp time_left(nil), do: :infinity

  defp time_left(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end

  defp finalize(acc, exit_reason, state) do
    %{
      output: acc |> Enum.reverse() |> IO.iodata_to_binary(),
      exit_status: normalize_exit(exit_reason),
      timed_out: state == :timed_out,
      cancelled: state == :cancelled
    }
  end

  # erlexec encodes termination as the OS wait(2) status: exit codes land in
  # the high byte (e.g. exit 3 -> {:exit_status, 768}) and signals as a raw
  # integer (e.g. 9 for SIGKILL). Use :exec.status/1 to decode it back to the
  # conventional shell exit code (the code, or 128+signum for signals).
  defp normalize_exit(:normal), do: 0

  defp normalize_exit({:exit_status, status}) when is_integer(status) do
    case :exec.status(status) do
      {:status, code} -> code
      {:signal, _name, _coredump?} -> 128 + status
    end
  end

  defp normalize_exit(other), do: other
end
