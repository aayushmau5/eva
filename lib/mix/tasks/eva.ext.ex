defmodule Mix.Tasks.Eva.Ext do
  @shortdoc "Lists Eva's project extensions"

  @moduledoc """
  Project extensions — Mix projects that run on their own node and join Eva.

      mix eva.ext                       # same as eva.ext.list
      mix eva.ext.add <path|git-url>    # register one that runs here
      mix eva.ext.remote <name> <host>:<port>   # register one that runs elsewhere
      mix eva.ext.start <name>          # start its node; a running Eva picks it up
      mix eva.ext.stop <name>
      mix eva.ext.list
      mix eva.ext.remove <name>

  Scripts in `~/.eva/extensions` need none of this — they are found by scanning and
  compiled into Eva at session start. Use a project when it needs its own dependencies, or
  when one file has stopped being enough.

  **In development, skip the commands.** `iex -S mix` in the extension's own project is
  found the same way, and lets you recompile a module into a live session.
  """

  use Mix.Task

  @impl true
  def run(args), do: Mix.Tasks.Eva.Ext.List.run(args)
end

defmodule Mix.Tasks.Eva.Ext.Helpers do
  @moduledoc false

  alias Eva.Coding.Resources

  def resources, do: %Resources{cwd: File.cwd!()}

  @doc """
  Makes this Mix VM a node, so it can talk to the ones already running.

  Reaching another VM means being one — `Node.connect/1` from `nonode@nohost` cannot even
  be attempted. Distribution is off by default here (a Mix task should not open a socket
  for `mix eva.ext.add`), so the tasks that need it say so.

  The name deliberately sits outside the `eva_ext_` space an extension node uses: a CLI
  that exists for half a second must never look like something an Eva should dial.

  Loopback, deliberately rather than by omission. Nothing dials a Mix task that lives for
  half a second, and every node it talks to is on this machine.
  """
  @spec ensure_node!() :: :ok
  def ensure_node! do
    name = fn host -> :"evacli_#{System.pid()}@#{host}" end

    case Eva.Core.Cluster.Listener.start(name, :loopback) do
      {:ok, _node} ->
        # The same routes Eva dials with. Without these, asking a registered remote
        # extension how it is doing would fall back to `erl_epmd` and try to reach an epmd
        # on the *other* machine, which is deliberately not exposed — so a healthy remote
        # would be reported as unreachable.
        Eva.Cluster.Epmd.install(resources())

      {:error, reason} ->
        Mix.raise("could not start distribution: #{inspect(reason)}")
    end
  end

  def describe(entry) do
    where = entry["dir"] || "#{entry["host"]}:#{entry["port"]}"

    [
      IO.ANSI.bright(),
      entry["name"],
      IO.ANSI.reset(),
      IO.ANSI.faint(),
      "  ",
      where,
      IO.ANSI.reset()
    ]
  end
end

defmodule Mix.Tasks.Eva.Ext.Add do
  @shortdoc "Registers a project extension"

  @moduledoc """
  Registers a project extension.

      mix eva.ext.add ../eva-mcp
      mix eva.ext.add https://github.com/you/eva-mcp.git

  A path is registered where it lies, so an extension you are working on stays in your own
  checkout. A git URL is cloned into `~/.eva/packages/` first.

  Registering does not build or start anything — `mix eva.ext.start <name>` does that. It
  is also the trust decision: only registered names are taken on by Eva, so nothing that
  merely reaches the cookie can register tools the model will call.
  """

  use Mix.Task

  import Mix.Tasks.Eva.Ext.Helpers

  alias Eva.Extension.Package

  @impl true
  def run([source]) do
    Mix.Task.run("app.start")

    case Package.add(resources(), source) do
      {:ok, entry} ->
        Mix.shell().info(["added ", describe(entry)])

        Mix.shell().info([
          "  start it with ",
          IO.ANSI.bright(),
          "mix eva.ext.start #{entry["name"]}",
          IO.ANSI.reset()
        ])

      {:error, reason} ->
        Mix.raise(reason)
    end
  end

  def run(_args), do: Mix.raise("usage: mix eva.ext.add <path|git-url>")
end

defmodule Mix.Tasks.Eva.Ext.Remote do
  @shortdoc "Registers an extension running on another machine"

  @moduledoc """
  Registers an extension that runs somewhere else.

      mix eva.ext.remote gpu 100.64.5.20:9001
      mix eva.ext.remote gpu 100.64.5.20:9001 --machine devbox

  The host and port are what the other machine's node was started with — its `:port`
  option, on its tailnet address. Eva dials that directly and never asks a remote epmd
  anything, which is why the port has to be written down.

  `--machine` is optional and gives the machine a name a person can read. Without it, the
  host slugs the tailnet address, so a remote `share` command is typed
  `/100_64_5_20__share` rather than `/devbox__share`.

  Nothing is started or checked here. `mix eva.ext.start` and `stop` refuse a remote entry
  on purpose: running commands on a machine we do not own is not something Eva does.
  """

  use Mix.Task

  import Mix.Tasks.Eva.Ext.Helpers

  alias Eva.Extension.Package

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    case OptionParser.parse(args, strict: [machine: :string]) do
      {opts, [name, address], []} ->
        case String.split(address, ":") do
          [host, port] ->
            case Integer.parse(port) do
              {port, ""} -> add(name, host, port, opts[:machine])
              _other -> Mix.raise("#{port} is not a port number")
            end

          _other ->
            Mix.raise(usage())
        end

      _other ->
        Mix.raise(usage())
    end
  end

  defp usage, do: "usage: mix eva.ext.remote <name> <host>:<port> [--machine <label>]"

  defp add(name, host, port, machine) do
    case Package.add_remote(resources(), name, host, port, machine) do
      {:ok, entry} ->
        Mix.shell().info([
          "added ",
          IO.ANSI.bright(),
          entry["name"],
          IO.ANSI.reset(),
          IO.ANSI.faint(),
          "  #{entry["host"]}:#{entry["port"]}",
          machine_suffix(entry),
          IO.ANSI.reset()
        ])

      {:error, reason} ->
        Mix.raise(reason)
    end
  end

  defp machine_suffix(%{"machine" => machine}) when is_binary(machine) and machine != "",
    do: " as #{machine}"

  defp machine_suffix(_entry), do: ""
end

defmodule Mix.Tasks.Eva.Ext.Start do
  @shortdoc "Starts a project extension's node"

  @moduledoc """
  Starts an extension's node, detached.

      mix eva.ext.start mcp

  The node runs its own `mix run --no-halt` and then sits there. It looks for nothing; a
  running Eva finds it on its next scan, a second or two later. It keeps running after this
  command returns and across Eva restarts — stop it with `mix eva.ext.stop <name>`.

  Everything it writes goes to `~/.eva/logs/<name>.log`, appended across restarts. That
  file is the only account of a detached node that stopped on its own.

  Starting it before Eva is running is fine: there is nothing for it to wait for, and
  whichever Eva comes up next will find it.
  """

  use Mix.Task

  import Mix.Tasks.Eva.Ext.Helpers

  alias Eva.Extension.Package

  @impl true
  def run([name]) do
    Mix.Task.run("app.start")
    ensure_node!()

    case Package.start(resources(), name) do
      {:ok, entry} ->
        Mix.shell().info(["starting ", describe(entry)])

        Mix.shell().info([
          IO.ANSI.faint(),
          "  logging to ",
          entry["log"],
          IO.ANSI.reset()
        ])

      {:error, reason} ->
        Mix.raise(reason)
    end
  end

  def run(_args), do: Mix.raise("usage: mix eva.ext.start <name>")
end

defmodule Mix.Tasks.Eva.Ext.Stop do
  @shortdoc "Stops a project extension's node"

  @moduledoc """
  Asks a running extension node to shut down.

      mix eva.ext.stop mcp

  Only reaches a node on this machine — lifecycle is local, and a node running somewhere
  else is not Eva's to stop.
  """

  use Mix.Task

  import Mix.Tasks.Eva.Ext.Helpers

  alias Eva.Extension.Package

  @impl true
  def run([name]) do
    Mix.Task.run("app.start")
    ensure_node!()

    case Package.stop(resources(), name) do
      :ok -> Mix.shell().info("stopping #{name}")
      {:error, reason} -> Mix.raise(reason)
    end
  end

  def run(_args), do: Mix.raise("usage: mix eva.ext.stop <name>")
end

defmodule Mix.Tasks.Eva.Ext.List do
  @shortdoc "Lists registered project extensions"

  @moduledoc """
  Lists registered project extensions, and for each one whether its node is running and
  which Evas it is serving.

      mix eva.ext.list
  """

  use Mix.Task

  import Mix.Tasks.Eva.Ext.Helpers

  alias Eva.Extension.Package

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")
    ensure_node!()

    case Package.list(resources()) do
      [] ->
        Mix.shell().info("no project extensions registered — mix eva.ext.add <path|git-url>")

      entries ->
        Enum.each(entries, fn {entry, status} ->
          Mix.shell().info([describe(entry), "  ", status(status)])
        end)
    end
  end

  defp status({:serving, evas}) do
    [
      IO.ANSI.green(),
      "running",
      IO.ANSI.reset(),
      IO.ANSI.faint(),
      "  ",
      Enum.map_join(evas, ", ", &to_string/1),
      IO.ANSI.reset()
    ]
  end

  # Up, but no Eva has taken it on — so no session can see it. Worth saying out loud, since
  # the symptom is an extension that is "running" and contributing nothing. Briefly normal
  # now: Eva finds it on its next scan rather than being told.
  defp status(:unattached) do
    [IO.ANSI.yellow(), "running, no Eva has picked it up", IO.ANSI.reset()]
  end

  defp status(:not_running), do: [IO.ANSI.faint(), "not running", IO.ANSI.reset()]

  # Only ever said about another machine. We cannot tell "never started" from "asleep", and
  # a local entry never gets this because epmd can prove the difference here.
  defp status(:unreachable), do: [IO.ANSI.red(), "cannot be reached", IO.ANSI.reset()]
end

defmodule Mix.Tasks.Eva.Ext.Remove do
  @shortdoc "Unregisters a project extension"

  @moduledoc """
  Unregisters a project extension.

      mix eva.ext.remove mcp

  The code and its build are left where they are — this removes Eva's knowledge of the
  extension, not your work. A node still running under that name will be refused at Eva's
  next scan.
  """

  use Mix.Task

  import Mix.Tasks.Eva.Ext.Helpers

  alias Eva.Extension.Package

  @impl true
  def run([name]) do
    Mix.Task.run("app.start")

    case Package.remove(resources(), name) do
      {:ok, entry} -> Mix.shell().info(["removed ", describe(entry)])
      {:error, reason} -> Mix.raise(reason)
    end
  end

  def run(_args), do: Mix.raise("usage: mix eva.ext.remove <name>")
end
