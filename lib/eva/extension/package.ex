defmodule Eva.Extension.Package do
  @moduledoc """
  Registering project extensions, and starting the nodes they run on.

  A project extension is a Mix project that runs as its own BEAM node and announces itself
  to Eva. Eva does not build it, does not load it, and does not own its VM — so this is a
  good deal. What is left:

    * **add** — remember where it is, and how to start it
    * **start** — run that command, detached, so it outlives the terminal
    * **stop** — ask the running node to shut down
    * **list** — what is registered, and what each one is currently doing

  Adding is also the trust model: a name has to be registered before it may announce, so
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
  Starts an extension's node.

  Detached on purpose: the node outlives the command that started it, and keeps running
  across Eva restarts. It announces itself when it comes up, and again whenever Eva
  returns — so starting it before Eva is running is fine.
  """
  @spec start(Resources.t(), String.t(), keyword()) ::
          {:ok, Registry.entry()} | {:error, String.t()}
  def start(%Resources{} = resources, name, opts \\ []) do
    with {:ok, entry} <- fetch(resources, name),
         :ok <- refuse_if_running(name),
         [_command | _args] <- entry["start"] do
      # Deliberately not a port. A port's lifetime is tied to this VM, and closing one
      # races the child's `exec` — which shows up as a node that starts perfectly well
      # most of the time and silently never appears the rest. `nohup ... &` hands the
      # process to init and returns immediately, which is what "detached" has to mean for
      # something meant to outlive the command that started it.
      script = "nohup " <> shell_command(entry["start"]) <> " >/dev/null 2>&1 &"

      case System.cmd("sh", ["-c", script], cd: entry["dir"], env: environment(resources, opts)) do
        {_output, 0} -> {:ok, entry}
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

  Only reaches an extension that has announced itself; there is nothing else to address a
  node by, and a node Eva has never heard from is not Eva's to stop.
  """
  @spec stop(Resources.t(), String.t()) :: :ok | {:error, String.t()}
  def stop(%Resources{} = _resources, name) do
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

  @doc """
  Every registered extension, with what its node is currently doing.

  Three states, not two. A node that is up but has joined no Eva looks exactly like one
  that never started if you only ask whether it announced — and those want opposite things
  done about them, so they are told apart here.
  """
  @spec list(Resources.t()) :: [{Registry.entry(), status()}]
  def list(%Resources{} = resources) do
    # Discovered once rather than per entry: each pass connects to every extension node on
    # the machine, and the registry is not usually one line long.
    running = running_by_name()

    Enum.map(Registry.read(resources), fn entry ->
      case Map.fetch(running, entry["name"]) do
        {:ok, %{announced?: true, eva_node: eva}} -> {entry, {:announced, eva}}
        {:ok, _status} -> {entry, :unattached}
        :error -> {entry, :not_running}
      end
    end)
  end

  @typedoc """
  What a registered extension's node is doing.

  `{:announced, node}` names the Eva it joined, because with more than one running that is
  the difference between "working" and "working, but not for the Eva you are looking at".
  """
  @type status :: {:announced, node()} | :unattached | :not_running

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
  The names allowed to announce — the registry, as the directory wants it.
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
  defp shell_command(argv) do
    Enum.map_join(argv, " ", fn part ->
      "'" <> String.replace(to_string(part), "'", "'\\''") <> "'"
    end)
  end

  # The child finds Eva by itself — epmd knows where every Eva is, and the child asks the
  # same way this command would. `:eva_node` is the caller pinning it to one, which is
  # worth passing down: it is the only way to choose when several are running.
  defp environment(_resources, opts) do
    case Keyword.get(opts, :eva_node) do
      nil -> []
      node -> [{"EVA_NODE", to_string(node)}]
    end
  end

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
  # what the extension announces itself as. Reading it from `mix.exs` rather than asking
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
