defmodule Eva.Extension.MCP.Transport.Stdio do
  @moduledoc """
  Talks to an MCP server running as a child OS process.

  The server reads newline-delimited JSON-RPC from its stdin and writes it back
  on stdout. Bytes arrive from erlexec in arbitrary chunks — a single message
  can span several `{:stdout, _, _}` messages, and one chunk can hold several
  messages — so `buffer` holds whatever is left over after the last newline.

  `stderr` is kept on its own channel. Servers log freely to it, and merging it
  into stdout (the way `Eva.Coding.ShellExec` does) would corrupt the JSON-RPC
  stream. It surfaces as `{:log, lines, transport}` instead.
  """
  use TypedStruct

  alias Eva.Extension.MCP.Config

  typedstruct do
    field :config, Config.t()
    field :exec_pid, pid()
    field :os_pid, non_neg_integer()
    field :buffer, binary(), default: <<>>
    field :stderr_buffer, binary(), default: <<>>
  end

  @doc """
  Spawns the server process.

  Must be called from the process that will receive its messages — erlexec
  delivers `{:stdout, ...}` and `{:DOWN, ...}` to whoever called `:exec.run/2`.
  """
  @spec connect(Config.t()) :: {:ok, t()} | {:error, term()}
  def connect(%Config{config: %Config.Stdio{} = stdio} = config) do
    with {:ok, executable} <- resolve_executable(stdio.command),
         {:ok, exec_pid, os_pid} <- :exec.run([executable | stdio.args], exec_options(stdio)) do
      {:ok, %__MODULE__{config: config, exec_pid: exec_pid, os_pid: os_pid}}
    end
  end

  @doc """
  Appends `data` to `buffer` and cuts it at every newline.

  Returns the complete lines and the trailing remainder to carry over. Blank
  lines are dropped rather than passed on to be decoded.
  """
  @spec split_lines(binary(), binary()) :: {[binary()], binary()}
  def split_lines(buffer, data) do
    {complete, [remainder]} =
      (buffer <> data)
      |> String.split("\n")
      |> Enum.split(-1)

    {Enum.reject(complete, &(&1 == "")), remainder}
  end

  # erlexec's port runs with a minimal environment and won't resolve a bare
  # command name via PATH, so resolve it up front. A missing binary is the most
  # common way a server fails to start — name it explicitly rather than letting
  # erlexec report a generic spawn failure.
  defp resolve_executable(nil), do: {:error, :missing_command}

  defp resolve_executable(command) do
    case System.find_executable(command) do
      nil -> {:error, {:executable_not_found, command}}
      path -> {:ok, path}
    end
  end

  defp exec_options(%Config.Stdio{} = stdio) do
    [
      # writable stdin — this is how requests reach the server
      :stdin,
      # {:stdout, os_pid, data} messages
      :stdout,
      # kept separate from stdout on purpose; see the moduledoc
      :stderr,
      # new process group rooted at the child, so `npx` and everything it
      # spawns is killed together rather than orphaned
      {:group, 0},
      :kill_group,
      # {:DOWN, os_pid, :process, exec_pid, reason} on exit
      :monitor
    ]
    |> put_cwd(stdio.cwd)
    |> put_env(stdio.env)
  end

  defp put_cwd(opts, nil), do: opts
  defp put_cwd(opts, cwd), do: [{:cd, cwd} | opts]

  defp put_env(opts, nil), do: opts
  defp put_env(opts, env) when map_size(env) == 0, do: opts

  # Merged into the inherited environment, not a replacement — servers still
  # need PATH and HOME.
  defp put_env(opts, env) do
    [{:env, Enum.map(env, fn {key, value} -> {to_string(key), to_string(value)} end)} | opts]
  end
end

defimpl Eva.Extension.MCP.Transport, for: Eva.Extension.MCP.Transport.Stdio do
  alias Eva.Extension.MCP.Transport.Stdio

  def send_message(%Stdio{os_pid: nil}, _message), do: {:error, :not_connected}

  def send_message(%Stdio{os_pid: os_pid}, message) do
    # :exec.send/2 takes a binary, not iodata, and chunks anything oversized
    # itself. The newline is the frame delimiter and belongs here, not in
    # Eva.Extension.MCP.Protocol — the HTTP transport must not have one.
    :exec.send(os_pid, IO.iodata_to_binary([message, ?\n]))
  end

  # Repeating `os_pid` across both patterns constrains the message to *this*
  # connection. After a reconnect, stragglers from the previous process no
  # longer match and fall through to :ignore.
  def handle_message(%Stdio{os_pid: os_pid} = transport, {:stdout, os_pid, data}) do
    {lines, buffer} = Stdio.split_lines(transport.buffer, data)
    {:frames, lines, %Stdio{transport | buffer: buffer}}
  end

  def handle_message(%Stdio{os_pid: os_pid} = transport, {:stderr, os_pid, data}) do
    {lines, buffer} = Stdio.split_lines(transport.stderr_buffer, data)
    {:log, lines, %Stdio{transport | stderr_buffer: buffer}}
  end

  def handle_message(
        %Stdio{os_pid: os_pid, exec_pid: exec_pid},
        {:DOWN, os_pid, :process, exec_pid, reason}
      ) do
    {:closed, reason}
  end

  # erlexec posts messages we don't model; the client needs a "not mine" answer
  # so it can leave them alone.
  def handle_message(_transport, _message), do: :ignore

  def close(%Stdio{os_pid: nil}), do: :ok

  def close(%Stdio{os_pid: os_pid}) do
    # The MCP shutdown sequence for stdio is: close stdin, let the server exit,
    # then signal. :exec.stop/1 covers the tail of that (SIGTERM, then SIGKILL
    # after its kill_timeout). A server that already exited returns an error
    # here, which is not worth propagating.
    :exec.send(os_pid, :eof)
    :exec.stop(os_pid)
    :ok
  end
end
