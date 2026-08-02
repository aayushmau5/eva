defmodule Eva.Extension.Set do
  @moduledoc """
  Every loaded extension for one session, merged into one view.
  A plain struct, not a process..

  `specs` is the source of truth; tools, guidelines, commands and hook targets are
  derived from it on demand.
  """

  use TypedStruct

  alias Eva.Agent.Tools
  alias Eva.Coding.Resources
  alias Eva.Extension.{Context, Hooks, Loader, Processes, Spec}
  alias Eva.Extension.Loader.Loaded
  alias Eva.Extension.Supervisor, as: ExtSupervisor

  typedstruct do
    field :resources, Resources.t()
    field :session_pid, pid()
    field :order, [String.t()], default: []
    field :loaded, %{String.t() => Loaded.t()}, default: %{}
    field :specs, %{String.t() => Spec.t()}, default: %{}
    field :builtin_tool_names, [String.t()], default: []
    field :overrides, %{String.t() => boolean()}, default: %{}
    field :diagnostics, [String.t()], default: []
  end

  @spec empty([String.t()]) :: t()
  def empty(diagnostics \\ []), do: %__MODULE__{diagnostics: diagnostics}

  @spec load(Resources.t(), pid(), map()) :: t()
  def load(%Resources{} = resources, session_pid, opts \\ %{}) do
    overrides = Map.get(opts, :overrides, %{})

    {loaded, diagnostics} =
      resources
      |> Loader.candidates(Map.get(opts, :extra_paths, []))
      |> Enum.filter(fn {name, _path} -> enabled?(overrides, name) end)
      |> Loader.load()

    base = %__MODULE__{
      resources: resources,
      session_pid: session_pid,
      builtin_tool_names: Map.get(opts, :builtin_tool_names, []),
      overrides: overrides,
      diagnostics: diagnostics
    }

    loaded
    |> Enum.reduce(base, &add_extension(&2, &1, session_pid, opts))
    |> finalize()
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
    %__MODULE__{} = dropped = drop(set, name)
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
      loaded = Map.fetch!(set.loaded, name)

      %{
        name: name,
        path: loaded.path,
        module: loaded.module,
        running?: server(set, name) != nil,
        tool_count: length(spec.tools),
        commands: Enum.map(spec.commands, & &1.name),
        hooks: spec.hooks,
        event_classes: spec.event_classes
      }
    end)
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
  @spec drop(t(), String.t() | pid()) :: t()
  def drop(%__MODULE__{} = set, name) when is_binary(name) do
    stop_server(set, name)

    %__MODULE__{
      set
      | order: List.delete(set.order, name),
        loaded: Map.delete(set.loaded, name),
        specs: Map.delete(set.specs, name)
    }
  end

  def drop(%__MODULE__{} = set, pid) when is_pid(pid) do
    case Registry.keys(Processes, pid) do
      [{_session_pid, name} | _] -> drop(set, name)
      [] -> set
    end
  end

  @spec shutdown(t()) :: :ok
  def shutdown(%__MODULE__{} = set) do
    Enum.each(set.order, &stop_server(set, &1))
    :ok
  end

  # -- Private --

  # No recorded choice means enabled.
  defp enabled?(overrides, name), do: Map.get(overrides, name, true)

  defp enable_from_disk(%__MODULE__{} = set, name, opts) do
    all_candidates = Loader.candidates(set.resources, Map.get(opts, :extra_paths, []))

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
    context = build_context(ext, session_pid, set.resources, opts)

    with {:ok, spec} <- call_setup(ext, context),
         :ok <- maybe_start(ext, spec, context) do
      accept(set, ext, spec)
    else
      {:error, reason} -> add_diagnostic(set, "#{ext.name}: #{reason}")
    end
  end

  defp build_context(%Loaded{} = ext, session_pid, resources, opts) do
    %Context{
      name: ext.name,
      cwd: Map.get(opts, :cwd),
      model: Map.get(opts, :model),
      provider_config: Map.get(opts, :provider_config),
      session_pid: session_pid,
      resources: resources,
      extension_dir: Path.dirname(ext.path)
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
  defp server(%__MODULE__{session_pid: session_pid}, name) do
    case Registry.whereis_name({Processes, {session_pid, name}}) do
      :undefined -> nil
      pid -> pid
    end
  end

  defp stop_server(%__MODULE__{} = set, name) do
    case server(set, name) do
      nil -> :ok
      pid -> ExtSupervisor.stop_extension(pid)
    end
  end
end
