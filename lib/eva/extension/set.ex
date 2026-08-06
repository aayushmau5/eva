defmodule Eva.Extension.Set do
  @moduledoc """
  Every loaded extension for one session, merged into one view.
  A plain struct, not a process.

  `specs` is the source of truth; tools, guidelines, commands and hook targets are
  derived from it on demand.
  """

  use TypedStruct

  alias Eva.Agent.Tools
  alias Eva.Coding.Resources
  alias Eva.Cluster
  alias Eva.Extension.{Context, Hooks, Loader, Processes, Spec, Trust}
  alias Eva.Extension.Loader.Loaded
  alias Eva.Extension.Supervisor, as: ExtSupervisor

  # Instantiating reaches across a node boundary and runs the extension's `setup/1` and
  # `init/1`, which are the extension author's code — generous, but not unbounded.
  @remote_timeout 15_000

  typedstruct do
    field :resources, Resources.t()
    field :session_pid, pid()
    field :order, [String.t()], default: []
    field :loaded, %{String.t() => Loaded.t()}, default: %{}
    field :specs, %{String.t() => Spec.t()}, default: %{}
    field :builtin_tool_names, [String.t()], default: []
    field :overrides, %{String.t() => boolean()}, default: %{}
    # Extension directories skipped for want of consent. Kept apart from `diagnostics` so
    # `trust_all/1` knows what there is to approve without parsing its own messages back.
    field :blocked_dirs, [String.t()], default: []
    # Extensions running on another node. Their processes cannot be in the local
    # `Processes` registry — it exists on both nodes, but they are separate tables — so
    # their pids live here instead.
    field :remote, %{String.t() => pid()}, default: %{}
    # What the directory said about each remote extension, for `list/1`.
    field :members, %{String.t() => map()}, default: %{}
    field :diagnostics, [String.t()], default: []
  end

  @spec empty([String.t()]) :: t()
  def empty(diagnostics \\ []), do: %__MODULE__{diagnostics: diagnostics}

  @spec load(Resources.t(), pid(), map()) :: t()
  def load(%Resources{} = resources, session_pid, opts \\ %{}) do
    overrides = Map.get(opts, :overrides, %{})

    {candidates, blocked} = Loader.candidates(resources, Map.get(opts, :extra_paths, []))

    {loaded, diagnostics} =
      candidates
      |> Enum.filter(fn {name, _path} -> enabled?(overrides, name) end)
      |> Loader.load()

    base = %__MODULE__{
      resources: resources,
      session_pid: session_pid,
      builtin_tool_names: Map.get(opts, :builtin_tool_names, []),
      overrides: overrides,
      blocked_dirs: blocked,
      diagnostics: Enum.map(blocked, &Loader.untrusted_diagnostic/1) ++ diagnostics
    }

    loaded
    |> Enum.reduce(base, &add_extension(&2, &1, session_pid, opts))
    |> add_announced(session_pid, opts)
    |> finalize()
  end

  @doc """
  Instantiates an extension that announced itself after this set was built.

  A node started while Eva is running is the normal case — the user runs
  `mix eva.ext.start mcp` mid-session — so this is not an edge path. Its tools arrive
  through `API.update_tools/2` and land at the next prompt, exactly as they do for an
  extension that was already up.
  """
  @spec add_member(t(), map(), pid(), map()) :: t()
  def add_member(%__MODULE__{} = set, member, session_pid, opts \\ %{}) do
    cond do
      not enabled?(set.overrides, member.name) ->
        set

      member.name in set.order ->
        add_diagnostic(
          set,
          "#{member.name} announced from #{member.node}, but a local extension already " <>
            "has that name — the local one is being used"
        )

      true ->
        set
        |> add_remote(member, session_pid, opts)
        |> move_last(member.name)
    end
  end

  defp move_last(%__MODULE__{} = set, name) do
    if name in set.order do
      %__MODULE__{set | order: List.delete(set.order, name) ++ [name]}
    else
      set
    end
  end

  @doc """
  Turns one extension on or off for this session.

  Off stops the process and removes the extension's contributions. On is the whole load
  pipeline for a single file — a disabled extension was never compiled, so there is no
  spec to un-hide. `opts` is the same map `load/3` takes; the caller supplies it because
  the `Set` does not keep those values after loading.

  Recording the choice in the transcript is the caller's job.
  """
  @spec set_enabled(t(), String.t(), boolean(), map()) :: {:ok, t()} | {:error, term()}
  def set_enabled(%__MODULE__{} = set, name, false, _opts) do
    %__MODULE__{} = dropped = drop(set, name, :disabled)
    {:ok, %__MODULE__{dropped | overrides: Map.put(set.overrides, name, false)}}
  end

  def set_enabled(%__MODULE__{} = set, name, true, opts) do
    set = %__MODULE__{set | overrides: Map.put(set.overrides, name, true)}

    if Map.has_key?(set.specs, name) do
      {:ok, set}
    else
      enable_from_disk(set, name, opts)
    end
  end

  @spec tools(t()) :: [Tools.AgentTool.t()]
  def tools(%__MODULE__{} = set) do
    {kept, _rejected, _seen} = resolve_tools(set)
    Enum.reverse(kept)
  end

  @doc """
  Replaces one extension's tools.
  """
  @spec put_tools(t(), String.t(), [Tools.AgentTool.t()]) :: t()
  def put_tools(%__MODULE__{} = set, name, tools) do
    case Map.fetch(set.specs, name) do
      {:ok, %Spec{} = spec} ->
        tools = Enum.map(tools, &bind_executor(&1, set, name))
        %__MODULE__{set | specs: Map.put(set.specs, name, %Spec{spec | tools: tools})}

      :error ->
        set
    end
  end

  # A tool with no executor came from another node, which kept the closure because a
  # closure cannot be called where its module is absent. What arrives is a description;
  # this gives it a body that calls home.
  #
  # The node comes from the member rather than from a pid: an extension with no processes
  # is still allowed to have tools, and it has no pid to ask.
  defp bind_executor(%Tools.AgentTool{executor: nil} = tool, %__MODULE__{} = set, name) do
    case Map.get(set.members, name) do
      nil ->
        tool

      %{node: node} ->
        %Tools.AgentTool{
          tool
          | executor: fn arguments, exec_context ->
              # `exec_context` carries a pid for progress updates, and pids are
              # location-transparent — `report_update/2` from the far side lands in the
              # Loop process here with nothing extra to arrange.
              case GenServer.call(
                     {Eva.Extension.ToolRegistry, node},
                     {:run, name, set.session_pid, tool.name, arguments, exec_context},
                     :infinity
                   ) do
                {:ok, result} -> result
                {:error, message} -> raise message
              end
            end
        }
    end
  end

  defp bind_executor(%Tools.AgentTool{} = tool, _set, _name), do: tool

  @spec guidelines(t()) :: [String.t()]
  def guidelines(%__MODULE__{} = set) do
    Enum.flat_map(set.order, &spec!(set, &1).guidelines)
  end

  @spec commands(t()) :: %{String.t() => {String.t(), Spec.Command.t()}}
  def commands(%__MODULE__{} = set) do
    set
    |> pairs(:commands)
    |> Enum.reduce(%{}, fn {name, command}, acc ->
      Map.put_new(acc, command.name, {name, command})
    end)
  end

  @spec hook_targets(t()) :: %{atom() => [{String.t(), pid()}]}
  def hook_targets(%__MODULE__{} = set) do
    set.order
    |> Enum.flat_map(&hook_pairs(set, &1))
    |> Enum.group_by(fn {hook, _target} -> hook end, fn {_hook, target} -> target end)
  end

  @spec diagnostics(t()) :: [String.t()]
  def diagnostics(%__MODULE__{} = set) do
    {_kept, rejected, _seen} = resolve_tools(set)
    set.diagnostics ++ Enum.reverse(rejected)
  end

  @spec list(t()) :: [map()]
  def list(%__MODULE__{} = set) do
    Enum.map(set.order, fn name ->
      spec = spec!(set, name)

      set
      |> origin(name)
      |> Map.merge(%{
        name: name,
        running?: server(set, name) != nil,
        tool_count: length(spec.tools),
        commands: Enum.map(spec.commands, & &1.name),
        hooks: spec.hooks,
        event_classes: spec.event_classes
      })
    end)
  end

  # Where the code is. A script has a file and a module here; an extension on another node
  # has neither, and saying which node it is on is the useful answer instead.
  defp origin(%__MODULE__{} = set, name) do
    case Map.fetch(set.loaded, name) do
      {:ok, loaded} ->
        %{path: loaded.path, module: loaded.module, node: node()}

      :error ->
        member = Map.fetch!(set.members, name)
        %{path: nil, module: nil, node: member.node}
    end
  end

  @spec run_command(t(), String.t(), String.t()) :: term() | {:error, term()}
  def run_command(%__MODULE__{} = set, command_name, args) do
    case Map.get(commands(set), command_name) do
      nil -> {:error, :unknown_command}
      {extension_name, _command} -> dispatch_command(set, extension_name, command_name, args)
    end
  end

  @doc """
  Removes an extension and stops its process.

  Stopping an already-dead process is a no-op, so this is safe to call from the
  session's `:DOWN` handler as well as from an explicit disable.
  """
  @spec drop(t(), String.t() | pid(), Eva.Extension.terminate_reason()) :: t()
  def drop(set, name, reason \\ :shutdown)

  def drop(%__MODULE__{} = set, name, reason) when is_binary(name) do
    stop_server(set, name, reason)

    %__MODULE__{
      set
      | order: List.delete(set.order, name),
        loaded: Map.delete(set.loaded, name),
        specs: Map.delete(set.specs, name),
        remote: Map.delete(set.remote, name),
        members: Map.delete(set.members, name)
    }
  end

  def drop(%__MODULE__{} = set, pid, reason) when is_pid(pid) do
    # `Registry.keys/2` only knows local processes, so a remote pid — a node that died, an
    # extension that crashed over there — has to be found by looking.
    case Registry.keys(Processes, pid) do
      [{_session_pid, name} | _] -> drop(set, name, reason)
      [] -> drop_remote(set, pid, reason)
    end
  end

  defp drop_remote(%__MODULE__{} = set, pid, reason) do
    case Enum.find(set.remote, fn {_name, remote_pid} -> remote_pid == pid end) do
      {name, _pid} -> drop(set, name, reason)
      nil -> set
    end
  end

  @spec shutdown(t(), Eva.Extension.terminate_reason()) :: :ok
  def shutdown(%__MODULE__{} = set, reason \\ :shutdown) do
    Enum.each(set.order, &stop_server(set, &1, reason))
    :ok
  end

  @doc """
  Approves every extension directory this load skipped.

  Returns the directories that were approved; the caller reloads to bring them up. An
  empty list means there was nothing waiting.
  """
  @spec trust_all(t()) :: {:ok, [String.t()]} | {:error, term()}
  def trust_all(%__MODULE__{resources: resources, blocked_dirs: dirs}) do
    Enum.reduce_while(dirs, {:ok, []}, fn dir, {:ok, approved} ->
      case Trust.trust(resources, dir) do
        :ok -> {:cont, {:ok, approved ++ [dir]}}
        {:error, reason} -> {:halt, {:error, {dir, reason}}}
      end
    end)
  end

  # -- Private --

  # No recorded choice means enabled.
  defp enabled?(overrides, name), do: Map.get(overrides, name, true)

  defp enable_from_disk(%__MODULE__{} = set, name, opts) do
    {all_candidates, _blocked} = Loader.candidates(set.resources, Map.get(opts, :extra_paths, []))

    case Enum.filter(all_candidates, fn {candidate, _path} -> candidate == name end) do
      [] ->
        {:error, :not_found}

      candidate ->
        case Loader.load(candidate) do
          {[%Loaded{} = ext], _diagnostics} ->
            added = add_extension(set, ext, set.session_pid, opts)

            if Map.has_key?(added.specs, name) do
              {:ok, %__MODULE__{added | order: discovery_order(added.order, all_candidates)}}
            else
              {:error, {:setup_failed, List.last(added.diagnostics)}}
            end

          {[], [reason | _]} ->
            {:error, {:load_failed, reason}}

          {[], []} ->
            {:error, :not_found}
        end
    end
  end

  # `add_extension/4` prepends, so a re-enabled extension would otherwise sit wherever it
  # happened to land. Put the whole set back into the order the loader found the files in —
  # `order` decides hook chaining and which extension wins a tool name.
  defp discovery_order(order, candidates) do
    known =
      candidates
      |> Enum.map(fn {name, _path} -> name end)
      |> Enum.filter(&(&1 in order))

    known ++ Enum.reject(order, &(&1 in known))
  end

  defp add_extension(%__MODULE__{} = set, %Loaded{} = ext, session_pid, opts) do
    context = build_context(ext, session_pid, opts)

    with {:ok, spec} <- call_setup(ext, context),
         :ok <- maybe_start(ext, spec, context) do
      accept(set, ext, spec)
    else
      {:error, reason} -> add_diagnostic(set, "#{ext.name}: #{reason}")
    end
  end

  # A name found on disk wins: a file in the repository you are working in is more specific
  # than an extension installed once and running for every session.
  defp add_announced(%__MODULE__{} = set, session_pid, opts) do
    :extension
    |> Cluster.members()
    |> Enum.filter(&(enabled?(set.overrides, &1.name) and &1.name not in set.order))
    |> Enum.reduce(set, &add_remote(&2, &1, session_pid, opts))
  end

  # `setup/1` and `init/1` run on the extension's node, with this session's context — the
  # host never loads the module and could not call them if it wanted to.
  defp add_remote(%__MODULE__{} = set, member, session_pid, opts) do
    context = build_remote_context(member, session_pid, opts)

    case instantiate(member, context) do
      {:ok, pid, %Spec{} = spec} ->
        # Nothing unregisters a remote pid for us: the local `Processes` registry never
        # knew about it. The session monitors instead, and drops the extension on `:DOWN`.
        if is_pid(pid), do: Process.monitor(pid)

        accept_remote(set, member, pid, spec)

      {:error, reason} ->
        add_diagnostic(set, "#{member.name} on #{member.node}: #{reason}")
    end
  end

  defp instantiate(member, context) do
    case GenServer.call(member.pid, {:instantiate, context, member.generation}, @remote_timeout) do
      {:ok, pid, %Spec{} = spec} -> {:ok, pid, spec}
      {:error, reason} -> {:error, inspect(reason)}
      other -> {:error, "instantiate returned #{inspect(other)}"}
    end
  catch
    # The node went away between announcing and being asked. Its `:DOWN` is already on its
    # way to the directory; this session just does without it.
    :exit, reason -> {:error, "unreachable: #{inspect(reason)}"}
  end

  defp build_context(%Loaded{} = ext, session_pid, opts) do
    %Context{
      name: ext.name,
      cwd: Map.get(opts, :cwd),
      model: Map.get(opts, :model),
      provider_config: Map.get(opts, :provider_config),
      session_pid: session_pid,
      extension_dir: Path.dirname(ext.path),
      # Only this extension's own entries.
      entries: opts |> Map.get(:extension_entries, %{}) |> Map.get(ext.name, []),
      capabilities: Map.get(opts, :capabilities)
    }
  end

  defp call_setup(%Loaded{module: module}, context) do
    case module.setup(context) do
      {:ok, %Spec{} = spec} -> {:ok, spec}
      {:error, reason} -> {:error, inspect(reason)}
      other -> {:error, "setup/1 returned #{inspect(other)}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, Exception.format(kind, reason)}
  end

  # The Registry is the record that a process exists.
  defp maybe_start(%Loaded{module: module}, %Spec{} = spec, context) do
    if Spec.stateful?(spec) do
      case ExtSupervisor.start_extension(module, spec, context) do
        {:ok, _pid} -> :ok
        {:error, reason} -> {:error, "failed to start: #{inspect(reason)}"}
      end
    else
      :ok
    end
  end

  defp accept(%__MODULE__{} = set, %Loaded{} = ext, %Spec{} = spec) do
    %__MODULE__{
      set
      | order: [ext.name | set.order],
        loaded: Map.put(set.loaded, ext.name, ext),
        specs: Map.put(set.specs, ext.name, spec)
    }
  end

  defp accept_remote(%__MODULE__{} = set, member, pid, %Spec{} = spec) do
    remote = if is_pid(pid), do: Map.put(set.remote, member.name, pid), else: set.remote

    set = %__MODULE__{
      set
      | order: [member.name | set.order],
        members: Map.put(set.members, member.name, member),
        specs: Map.put(set.specs, member.name, spec),
        remote: remote
    }

    # The tools `setup/1` returned arrived stripped, exactly like the ones a later
    # `update_tools/2` will send, so they need the same proxies binding to them.
    put_tools(set, member.name, spec.tools)
  end

  defp build_remote_context(member, session_pid, opts) do
    %Context{
      name: member.name,
      cwd: Map.get(opts, :cwd),
      model: Map.get(opts, :model),
      provider_config: Map.get(opts, :provider_config),
      session_pid: session_pid,
      # There is no directory here to point at — the code lives on the other node.
      extension_dir: nil,
      entries: opts |> Map.get(:extension_entries, %{}) |> Map.get(member.name, []),
      # Not the host implementation the in-VM extensions get: that module's functions run
      # where they are called, and this extension is somewhere else. The remote one has the
      # same shape and forwards.
      capabilities: Map.get(opts, :remote_capabilities, Eva.Extension.Capabilities.Remote)
    }
  end

  defp add_diagnostic(%__MODULE__{} = set, message) do
    %__MODULE__{set | diagnostics: set.diagnostics ++ [message]}
  end

  defp finalize(%__MODULE__{} = set), do: %__MODULE__{set | order: Enum.reverse(set.order)}

  defp spec!(%__MODULE__{specs: specs}, name), do: Map.fetch!(specs, name)

  defp resolve_tools(%__MODULE__{} = set) do
    set
    |> pairs(:tools)
    |> Enum.reduce({[], [], MapSet.new(set.builtin_tool_names)}, fn {name, tool},
                                                                    {kept, rejected, seen} ->
      if MapSet.member?(seen, tool.name) do
        {kept, ["#{name}: tool #{tool.name} is already registered" | rejected], seen}
      else
        {[tool | kept], rejected, MapSet.put(seen, tool.name)}
      end
    end)
  end

  # Every `field` entry across all extensions, in discovery order, tagged with its owner.
  defp pairs(%__MODULE__{} = set, field) do
    Enum.flat_map(set.order, fn name ->
      set |> spec!(name) |> Map.fetch!(field) |> Enum.map(&{name, &1})
    end)
  end

  defp hook_pairs(%__MODULE__{} = set, name) do
    case server(set, name) do
      nil -> []
      pid -> Enum.map(spec!(set, name).hooks, &{&1, {name, pid}})
    end
  end

  defp dispatch_command(%__MODULE__{} = set, extension_name, command_name, args) do
    case server(set, extension_name) do
      nil -> {:error, :no_process}
      pid -> Hooks.safe_call(pid, {:command, command_name, args})
    end
  end

  # Registry unregisters on process death, so a dead extension reads as nil
  # immediately rather than after the session has handled its `:DOWN`.
  #
  # A remote extension is never in that registry: the registry exists on its node too, but
  # they are separate tables, so a remote pid would never be found there however long you
  # looked. `remote` is the answer for those, and the session's `:DOWN` handling is what
  # keeps it honest.
  defp server(%__MODULE__{session_pid: session_pid} = set, name) do
    case Registry.whereis_name({Processes, {session_pid, name}}) do
      :undefined -> Map.get(set.remote, name)
      pid -> pid
    end
  end

  defp stop_server(%__MODULE__{} = set, name, reason) do
    case server(set, name) do
      nil -> :ok
      pid -> ExtSupervisor.stop_extension(pid, reason)
    end
  end
end
