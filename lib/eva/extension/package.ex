defmodule Eva.Extension.Package do
  @moduledoc """
  Registering project extensions, and starting the nodes they run on.

  A project extension is a Mix project that runs as its own BEAM node and is dialled by
  Eva. Eva does not build it, does not load it, and does not own its VM — so this is a
  good deal. What is left:

    * **add** — remember where it is, and how to start it
    * **start** — run that command, detached, so it outlives the terminal
    * **stop** — ask the running node to shut down
    * **list** — what is registered, and what each one is currently doing

  Adding is also the trust model: a name has to be registered before Eva will take it on, so
  nothing that merely reaches the cookie can register tools the model will call.

  ## Nodes are asked about themselves

  An extension node is found through `Eva.Cluster.Discovery` and asked what it is. That
  works with no Eva running at all, which is the case `mix eva.ext.stop` most needs to
  handle, and it does not care how many Evas there are.
  """

  alias Eva.Cluster.Discovery
  alias Eva.Coding.Resources
  alias Eva.Extension.Registry

  @default_start ["mix", "run", "--no-halt"]

  @doc """
  Registers an extension at a path or git URL.

  A path is used where it lies, so an extension you are working on is registered from your
  own checkout. A git URL is cloned into `<root>/packages/` first.
  """
  @spec add(Resources.t(), String.t(), keyword()) ::
          {:ok, Registry.entry()} | {:error, String.t()}
  def add(%Resources{} = resources, source, opts \\ []) do
    with {:ok, dir} <- resolve(resources, source),
         {:ok, name} <- extension_name(dir, opts) do
      entry = %{
        "name" => name,
        "kind" => "project",
        "dir" => dir,
        "start" => Keyword.get(opts, :start, @default_start)
      }

      case Registry.put(resources, entry) do
        :ok -> {:ok, entry}
        {:error, reason} -> {:error, "could not write the registry: #{inspect(reason)}"}
      end
    end
  end

  @doc """
  Registers an extension that runs on another machine.

  Nothing is fetched, built or checked — the machine may well be asleep. All this records
  is where to dial, which is the only thing we could act on anyway.
  """
  @spec add_remote(Resources.t(), String.t(), String.t(), :inet.port_number()) ::
          {:ok, Registry.entry()} | {:error, String.t()}
  def add_remote(%Resources{} = resources, name, host, port)
      when is_binary(name) and is_binary(host) and is_integer(port) do
    entry = %{"name" => name, "kind" => "remote", "host" => host, "port" => port}

    case Registry.put(resources, entry) do
      :ok -> {:ok, entry}
      {:error, reason} -> {:error, "could not write the registry: #{inspect(reason)}"}
    end
  end

  @doc """
  Starts an extension's node.

  Detached on purpose: the node outlives the command that started it, and keeps running
  across Eva restarts. Starting it before Eva is running is fine — it does not go looking
  for anything, and a running Eva picks it up on its next scan a second or two later.
  """
  @spec start(Resources.t(), String.t(), keyword()) ::
          {:ok, Registry.entry()} | {:error, String.t()}
  def start(%Resources{} = resources, name, opts \\ []) do
    with {:ok, entry} <- fetch(resources, name),
         :ok <- refuse_if_remote(entry, "start"),
         :ok <- refuse_if_running(name),
         [_command | _args] <- entry["start"] do
      # Deliberately not a port. A port's lifetime is tied to this VM, and closing one
      # races the child's `exec` — which shows up as a node that starts perfectly well
      # most of the time and silently never appears the rest. `nohup ... &` hands the
      # process to init and returns immediately, which is what "detached" has to mean for
      # something meant to outlive the command that started it.
      #
      # Output goes to a log rather than /dev/null. A detached node that dies takes its
      # crash report with it otherwise, and "it ran for a while and then stopped" is the
      # one failure this command has no other way to explain.
      log = log_path(resources, name)
      script = "nohup " <> shell_command(entry["start"]) <> " >>" <> shell_quote(log) <> " 2>&1 &"

      case System.cmd("sh", ["-c", script], cd: entry["dir"], env: environment(resources, opts)) do
        {_output, 0} -> {:ok, Map.put(entry, "log", log)}
        {output, status} -> {:error, "#{name}: start exited #{status}\n#{output}"}
      end
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, "#{name}: bad start command #{inspect(other)}"}
    end
  rescue
    e -> {:error, "#{name}: could not start — #{Exception.message(e)}"}
  end

  @doc """
  Asks a running extension node to stop.

  Only reaches a node running on this machine — lifecycle is local, and a node somewhere
  else is not Eva's to stop.
  """
  @spec stop(Resources.t(), String.t()) :: :ok | {:error, String.t()}
  def stop(%Resources{} = resources, name) do
    # Registration is not required to stop something — a node running under a name nobody
    # registered is still this machine's to shut down. Only a *remote* entry is refused.
    case Registry.fetch(resources, name) do
      {:ok, entry} ->
        with :ok <- refuse_if_remote(entry, "stop"), do: stop_local(name)

      :error ->
        stop_local(name)
    end
  end

  defp stop_local(name) do
    case Discovery.extension_node(name) do
      {:ok, node} ->
        # An orderly `init:stop`, not a kill: `terminate/2` runs, which is what takes an
        # extension's own children — an MCP server's OS process, say — down with it.
        :erpc.cast(node, :init, :stop, [])
        :ok

      :error ->
        {:error, "#{name} is not running — no node is up under that name"}
    end
  end

  # Lifecycle is local. Eva may choose whether to connect to another machine's node, but
  # starting and stopping it means running commands there, which we deliberately cannot do:
  # no remote execution, no credentials, no logs to ship back.
  defp refuse_if_remote(entry, verb) do
    if Registry.remote?(entry) do
      {:error, "#{entry["name"]} lives on #{entry["host"]} — #{verb} it there, not here"}
    else
      :ok
    end
  end

  @doc """
  Every registered extension, with what its node is currently doing.

  Three states, not two. A node that is up but serving no Eva looks exactly like one that
  never started if you only ask whether it is running — and those want opposite things done
  about them, so they are told apart here.
  """
  @spec list(Resources.t()) :: [{Registry.entry(), status()}]
  def list(%Resources{} = resources) do
    # Discovered once rather than per entry: each pass connects to every extension node on
    # the machine, and the registry is not usually one line long.
    running = running_by_name()

    Enum.map(Registry.read(resources), fn entry ->
      if Registry.remote?(entry),
        do: {entry, remote_status(entry)},
        else: {entry, local_status(running, entry)}
    end)
  end

  defp local_status(running, entry) do
    case Map.fetch(running, entry["name"]) do
      {:ok, %{serving: [_ | _] = evas}} -> {:serving, evas}
      {:ok, _status} -> :unattached
      :error -> :not_running
    end
  end

  # Asked directly rather than enumerated — there is no epmd on another machine to list it.
  # Two states, not three: we cannot tell "never started" from "cannot be reached", and
  # pretending otherwise would be a guess.
  defp remote_status(entry) do
    case Discovery.status(Registry.node_name(entry)) do
      %{serving: [_ | _] = evas} -> {:serving, evas}
      %{} -> :unattached
      nil -> :unreachable
    end
  end

  @typedoc """
  What a registered extension's node is doing.

  `{:serving, nodes}` names the Evas that took it on — a list rather than one, because
  since Eva does the dialling there is nothing stopping two from using the same node. With
  several running, which ones is the difference between "working" and "working, but not for
  the Eva you are looking at".

  `:not_running` is only ever said about this machine, where epmd can prove it. A remote
  that does not answer is `:unreachable`, which is honestly less information.
  """
  @type status :: {:serving, [node()]} | :unattached | :not_running | :unreachable

  @doc """
  Unregisters an extension. Its code and its build are left alone.
  """
  @spec remove(Resources.t(), String.t()) :: {:ok, Registry.entry()} | {:error, String.t()}
  def remove(%Resources{} = resources, name) do
    with {:ok, entry} <- fetch(resources, name),
         :ok <- Registry.delete(resources, name) do
      {:ok, entry}
    end
  end

  @doc """
  The names allowed to join — the registry, as the directory wants it.
  """
  @spec allowed_names(Resources.t()) :: [String.t()]
  def allowed_names(%Resources{} = resources) do
    resources |> Registry.read() |> Enum.map(& &1["name"])
  end

  @doc """
  Where clones live: `<root>/packages/<name>`.
  """
  @spec packages_dir(Resources.t()) :: String.t()
  def packages_dir(%Resources{root: root}), do: Path.join(root, "packages")

  # -- Private --

  defp fetch(resources, name) do
    case Registry.fetch(resources, name) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, "#{name} is not registered — run mix eva.ext.add <path|git-url>"}
    end
  end

  defp refuse_if_running(name) do
    case Discovery.extension_node(name) do
      {:ok, node} -> {:error, "#{name} is already running on #{node}"}
      :error -> :ok
    end
  end

  # Local enumeration only, never the directory: the directory holds other machines' nodes
  # too, and `stop` reading from it would kill somebody else's.
  #
  # Keyed by the name the node reports rather than the one in its node name, for the reason
  # `Eva.Cluster.Discovery.extension_node/1` gives: prefixes cannot tell `mcp` from `mcp_2`.
  defp running_by_name do
    for node <- Discovery.extension_nodes(),
        status = Discovery.status(node),
        is_map(status),
        into: %{},
        do: {status.name, status}
  end

  # Quoted, because a start command is user data: a directory with a space in it, or an
  # argument with one, must not become two arguments.
  @doc """
  Where a node started by `start/3` writes everything it says.

  One file per extension, appended to across restarts, so the run before the one that
  is up is still there to read.
  """
  @spec log_path(Resources.t(), String.t()) :: String.t()
  def log_path(%Resources{root: root}, name) do
    dir = Path.join(root, "logs")
    File.mkdir_p!(dir)
    Path.join(dir, "#{name}.log")
  end

  defp shell_command(argv), do: Enum.map_join(argv, " ", &shell_quote/1)

  defp shell_quote(part) do
    "'" <> String.replace(to_string(part), "'", "'\\''") <> "'"
  end

  # Nothing to tell it. The child does not look for an Eva — it comes up, sits there, and
  # is found. Which Evas it will then serve is its own `:serve` setting, not ours to pass.
  defp environment(_resources, _opts), do: []

  defp resolve(resources, source) do
    if git_url?(source), do: clone(resources, source), else: local(source)
  end

  defp local(source) do
    dir = Path.expand(source)

    cond do
      not File.dir?(dir) -> {:error, "#{dir} is not a directory"}
      not File.regular?(Path.join(dir, "mix.exs")) -> {:error, "#{dir} has no mix.exs"}
      true -> {:ok, dir}
    end
  end

  defp git_url?(source) do
    String.starts_with?(source, ["http://", "https://", "git@", "ssh://"]) or
      String.ends_with?(source, ".git")
  end

  defp clone(resources, url) do
    name = url |> Path.basename() |> String.replace_suffix(".git", "")
    dir = Path.join(packages_dir(resources), name)

    if File.dir?(dir) do
      {:error, "#{dir} already exists — remove it, or add it by path"}
    else
      File.mkdir_p!(packages_dir(resources))

      case System.cmd("git", ["clone", "--depth", "1", url, dir], stderr_to_stdout: true) do
        {_output, 0} -> {:ok, dir}
        {output, _status} -> {:error, "git clone failed:\n#{output}"}
      end
    end
  end

  # `eva_mcp` is the app; `mcp` is what the user types, what the entry is keyed by, and
  # what the extension reports itself as. Reading it from `mix.exs` rather than asking
  # keeps the two from drifting.
  defp extension_name(dir, opts) do
    case Keyword.get(opts, :name) do
      name when is_binary(name) -> {:ok, name}
      nil -> name_from_mix(dir)
    end
  end

  defp name_from_mix(dir) do
    probe = String.to_atom("eva_ext_probe_#{:erlang.phash2(dir)}")

    config = Mix.Project.in_project(probe, dir, fn _module -> Mix.Project.config() end)

    case Keyword.get(config, :app) do
      nil -> {:error, "#{dir}: mix.exs declares no :app"}
      app -> {:ok, app |> to_string() |> String.replace_prefix("eva_", "")}
    end
  rescue
    e -> {:error, "#{dir}: could not read mix.exs — #{Exception.message(e)}"}
  end
end
