defmodule Eva.Test.ExtensionHarness do
  @moduledoc """
  Runs one extension against a fake session.

  The fake session is a process that stores every `{:extension_*, ...}` message it
  receives, so a test can assert on what an extension sent without any storage,
  provider, or model.
  """

  alias Eva.Extension.{Context, Spec, Supervisor}

  defstruct [:module, :pid, :session, :context, :spec]

  @doc """
  Calls `setup/1`, starts the process if the Spec needs one, returns a handle.

  `entries` seeds `Context.entries`, so resume behaviour can be tested without a
  real transcript.
  """
  def start(module, opts \\ []) do
    session = spawn_fake_session()

    context = %Context{
      name: Keyword.get(opts, :name, "test_ext"),
      cwd: Keyword.get(opts, :cwd, File.cwd!()),
      model: Keyword.get(opts, :model, "test-model"),
      session_pid: session,
      extension_dir: Keyword.get(opts, :extension_dir, "/tmp"),
      entries: Keyword.get(opts, :entries, []),
      capabilities: Keyword.get(opts, :capabilities, __MODULE__.StubCapabilities)
    }

    {:ok, %Spec{} = spec} = module.setup(context)

    # Through the supervisor rather than `Server.start_link/1`: a graceful stop exits
    # with `{:shutdown, reason}`, which is not `:normal` and so propagates across a
    # link — starting it here directly would kill the test process on `stop/2`. Going
    # through the supervisor also exercises the path a real session uses.
    #
    # Cleanup still happens: the fake session is linked to the test, so when the test
    # ends the session dies, the server sees `:DOWN`, and stops itself.
    pid =
      if Spec.stateful?(spec) do
        {:ok, pid} = Supervisor.start_extension(module, spec, context)
        pid
      end

    %__MODULE__{module: module, pid: pid, session: session, context: context, spec: spec}
  end

  def hook(%__MODULE__{pid: pid}, hook, payload), do: GenServer.call(pid, {:hook, hook, payload})

  def command(%__MODULE__{pid: pid}, name, args \\ ""),
    do: GenServer.call(pid, {:command, name, args})

  @doc "Delivers a message, like the Bus or a child process would."
  def send_message(%__MODULE__{pid: pid}, message) do
    send(pid, message)
    # A GenServer call queues behind the info message, so this waits for it to be
    # handled without sleeping.
    _ = :sys.get_state(pid)
    :ok
  end

  @doc "Everything the extension sent back to the session, oldest first."
  def sent(%__MODULE__{session: session}) do
    send(session, {:dump, self()})

    receive do
      {:messages, messages} -> messages
    after
      1_000 -> raise "TestHarness: fake session did not respond"
    end
  end

  def entries(%__MODULE__{} = h), do: for({:extension_entry, _n, data} <- sent(h), do: data)
  def pushed_tools(%__MODULE__{} = h), do: for({:extension_update_tools, _n, t} <- sent(h), do: t)

  def stop(harness, reason \\ :shutdown)
  def stop(%__MODULE__{pid: nil}, _reason), do: :ok
  def stop(%__MODULE__{pid: pid}, reason), do: Supervisor.stop_extension(pid, reason)

  # -- Private --

  defp spawn_fake_session(), do: spawn_link(fn -> fake_session_loop([]) end)

  defp fake_session_loop(received) do
    receive do
      {:dump, from} ->
        send(from, {:messages, Enum.reverse(received)})
        fake_session_loop(received)

      message ->
        fake_session_loop([message | received])
    end
  end

  defmodule StubCapabilities do
    @moduledoc "Returns defaults so dialogs never hang a test."
    def ask(_question, default, _opts), do: default
  end
end
