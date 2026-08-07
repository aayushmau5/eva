defmodule Mix.Tasks.Eva.Ext do
  @shortdoc "Lists Eva's project extensions"

  @moduledoc """
  Project extensions — Mix projects that run on their own node and join Eva.

      mix eva.ext                       # same as eva.ext.list
      mix eva.ext.add <path|git-url>    # register it
      mix eva.ext.start <name>          # start its node; it announces itself
      mix eva.ext.stop <name>
      mix eva.ext.list
      mix eva.ext.remove <name>

  Scripts in `~/.eva/extensions` need none of this — they are found by scanning and
  compiled into Eva at session start. Use a project when it needs its own dependencies, or
  when one file has stopped being enough.

  **In development, skip the commands.** `iex -S mix` in the extension's own project
  announces on boot and lets you recompile a module into a live session.
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

  The name deliberately sits outside the `eva_` space an Eva or an extension announces
  under: a CLI that exists for half a second must never look like something worth joining
  to a node sweeping for Evas.
  """
  @spec ensure_node!() :: :ok
  def ensure_node! do
    if Node.alive?() do
      :ok
    else
      name = :"evacli_#{System.pid()}@127.0.0.1"

      case :net_kernel.start(name, %{name_domain: :longnames}) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> Mix.raise("could not start distribution: #{inspect(reason)}")
      end
    end
  end

  def describe(entry) do
    [
      IO.ANSI.bright(),
      entry["name"],
      IO.ANSI.reset(),
      IO.ANSI.faint(),
      "  ",
      entry["dir"],
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
  is also the trust decision: only registered names may announce themselves to Eva, so
  nothing that merely reaches the cookie can register tools the model will call.
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

defmodule Mix.Tasks.Eva.Ext.Start do
  @shortdoc "Starts a project extension's node"

  @moduledoc """
  Starts an extension's node, detached.

      mix eva.ext.start mcp

  The node runs its own `mix run --no-halt`, finds Eva through `~/.eva/node`, and
  announces itself. It keeps running after this command returns and across Eva restarts —
  stop it with `mix eva.ext.stop <name>`.

  Starting it before Eva is running is fine: it retries, and announces as soon as there is
  something to announce to.
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

  Only reaches an extension that has announced itself — a node Eva has never heard from is
  not Eva's to stop.
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
  which Eva it joined.

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

  defp status({:announced, eva}) do
    [
      IO.ANSI.green(),
      "running",
      IO.ANSI.reset(),
      IO.ANSI.faint(),
      "  ",
      to_string(eva),
      IO.ANSI.reset()
    ]
  end

  # Up, but it has joined nothing — so no session can see it. Worth saying out loud, since
  # the symptom is an extension that is "running" and contributing nothing.
  defp status(:unattached) do
    [IO.ANSI.yellow(), "running, not attached to an Eva", IO.ANSI.reset()]
  end

  defp status(:not_running), do: [IO.ANSI.faint(), "not running", IO.ANSI.reset()]
end

defmodule Mix.Tasks.Eva.Ext.Remove do
  @shortdoc "Unregisters a project extension"

  @moduledoc """
  Unregisters a project extension.

      mix eva.ext.remove mcp

  The code and its build are left where they are — this removes Eva's knowledge of the
  extension, not your work. A node still running under that name will be refused the next
  time it announces.
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
