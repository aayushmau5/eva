defmodule Eva.Extension.Loader do
  @moduledoc """
  Finds extension `.exs` files, compiles them into the running VM, and reports which
  module each one defined.

  Modules are registered globally, so two sessions loading the same file share one
  compiled module.

  Nothing here raises — a bad extension file becomes a diagnostic string.
  """

  use TypedStruct

  alias Eva.Coding.Resources
  alias Eva.Extension.Trust

  # Loaded modules are cached in persistent_term by this cache key.
  @cache_key {__MODULE__, :required_paths}

  typedstruct module: Loaded do
    field :name, String.t()
    field :path, String.t()
    # The module carrying `__eva_extension__` — the one whose callbacks get called.
    field :module, module()
    # Every module the file brought in, including any it required itself. Purging
    # only `module` leaves a split extension's siblings loaded at their old version.
    field :modules, [module()], default: []
    # Every file this load required, `path` included.
    field :files, [String.t()], default: []
  end

  @doc """
  Every script to load, and the directories that were skipped for want of consent.

  Scripts only. A project extension runs on its own node and announces itself — Eva never
  loads one, so nothing about it reaches this module; see `Eva.Cluster`.

  A project's `.eva/extensions` is code from whoever wrote the repository and it runs
  before the first prompt, so it contributes nothing until `Trust.trust/2` has been called
  for it. The global directory and any explicit `extra_paths` are provided by the user.
  """
  @spec candidates(Resources.t(), [String.t()]) ::
          {[{name :: String.t(), path :: String.t()}], blocked :: [String.t()]}
  def candidates(%Resources{} = resources, extra_paths \\ []) do
    global = Path.expand(Path.join(resources.root, "extensions"))

    {allowed, blocked} =
      resources
      |> Resources.extensions_dir()
      |> Enum.split_with(fn dir ->
        dir == global or not File.dir?(dir) or Trust.trusted?(resources, dir)
      end)

    dir_candidates = Enum.flat_map(allowed, &candidates_in_dir/1)

    extra_candidates =
      extra_paths
      |> Enum.map(&candidate_from_path/1)
      |> Enum.reject(&is_nil/1)

    {dedup_by_name(dir_candidates ++ extra_candidates), blocked}
  end

  @doc """
  Loads the extension into the VM.
  """
  @spec load([{String.t(), String.t()}]) :: {[Loaded.t()], [String.t()]}
  def load(candidates) do
    candidates
    |> Enum.reduce({[], [], MapSet.new()}, &load_into_acc/2)
    |> then(fn {loaded, diagnostics, _seen} ->
      {Enum.reverse(loaded), Enum.reverse(diagnostics)}
    end)
  end

  @doc """
  Finds and loads every extension reachable from `resources`, plus any `extra_paths`.
  Returns `{loaded, diagnostics}`, with a diagnostic for each directory skipped for want
  of consent.
  """
  @spec discover(Resources.t(), [String.t()]) :: {[Loaded.t()], [String.t()]}
  def discover(%Resources{} = resources, extra_paths \\ []) do
    {candidates, blocked} = candidates(resources, extra_paths)
    {loaded, diagnostics} = load(candidates)
    {loaded, Enum.map(blocked, &untrusted_diagnostic/1) ++ diagnostics}
  end

  @doc """
  The notice shown for a directory that has not been approved.
  """
  @spec untrusted_diagnostic(String.t()) :: String.t()
  def untrusted_diagnostic(dir) do
    "#{dir} has extensions that have not been approved, so none of them are loaded. " <>
      "Run /trust-extensions to review and enable them."
  end

  @doc """
  Unloads extension modules so the next `discover/2` recompiles them from disk.

  Stop the extension processes first — `:code.purge/1` kills anything still running
  the old code.

  Every module the file defined is purged, not just the one with the marker: a script
  that requires a sibling would otherwise keep that sibling at its old version after a
  reload, with no error to say so.
  """
  @spec purge([Loaded.t()]) :: :ok
  def purge(loaded) do
    loaded |> Enum.flat_map(& &1.files) |> Code.unrequire_files()

    Enum.each(loaded, fn %Loaded{modules: modules, path: path} ->
      Enum.each(modules, fn module ->
        # `delete` only moves the current version to "old"; the second purge removes it.
        # Without it the next require warns about redefining, which fails precommit.
        :code.purge(module)
        :code.delete(module)
        :code.purge(module)
      end)

      drop_cached(path)
    end)

    :ok
  end

  # -- Private --

  defp load_into_acc({name, path}, {loaded, diagnostics, seen_modules}) do
    case load_one(name, path) do
      {:ok, %Loaded{module: module} = extension} ->
        # Module names are global, so two files defining `Guard` would redefine
        # each other. Keep the first.
        if MapSet.member?(seen_modules, module) do
          reason =
            "#{extension.path} defines #{inspect(module)}, already claimed by another extension"

          {loaded, [reason | diagnostics], seen_modules}
        else
          {[extension | loaded], diagnostics, MapSet.put(seen_modules, module)}
        end

      {:error, reason} ->
        {loaded, [reason | diagnostics], seen_modules}
    end
  end

  defp load_one(name, path) do
    with {:ok, %{modules: modules, files: files}} <- require_modules(path),
         {:ok, module} <- extension_module(modules, path),
         :ok <- validate(module, name, path) do
      {:ok, %Loaded{name: name, path: path, module: module, modules: modules, files: files}}
    end
  end

  defp candidates_in_dir(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.flat_map(fn entry ->
          path = Path.join(dir, entry)

          cond do
            File.dir?(path) ->
              nested = Path.join(path, "extension.exs")
              if File.regular?(nested), do: [{entry, nested}], else: []

            String.ends_with?(entry, ".exs") ->
              [{Path.basename(entry, ".exs"), path}]

            true ->
              []
          end
        end)

      {:error, _reason} ->
        []
    end
  end

  defp candidate_from_path(path) do
    expanded = Path.expand(path)

    cond do
      File.regular?(expanded) and String.ends_with?(expanded, ".exs") ->
        {Path.basename(expanded, ".exs"), expanded}

      File.dir?(expanded) ->
        nested = Path.join(expanded, "extension.exs")
        if File.regular?(nested), do: {Path.basename(expanded), nested}, else: nil

      true ->
        nil
    end
  end

  # Keeps the last entry for a name while preserving order, so project beats global.
  defp dedup_by_name(candidates) do
    candidates
    |> Enum.reverse()
    |> Enum.uniq_by(fn {name, _path} -> name end)
    |> Enum.reverse()
  end

  defp require_modules(path) do
    required_before = MapSet.new(Code.required_files())

    case Code.require_file(path) do
      nil ->
        case Map.fetch(required_cache(), path) do
          {:ok, entry} -> {:ok, entry}
          :error -> {:error, "#{path} was already required but is missing from the loader cache"}
        end

      results when is_list(results) ->
        files = Enum.reject(Code.required_files(), &MapSet.member?(required_before, &1))
        entry = %{modules: loaded_modules(results, files), files: files}
        cache_modules(path, entry)
        {:ok, entry}
    end
  rescue
    e -> {:error, "#{path} failed to compile: #{Exception.message(e)}"}
  catch
    kind, reason -> {:error, "#{path} failed to load: #{Exception.format(kind, reason)}"}
  end

  # `Code.require_file/1` reports only the modules the file defined itself — a sibling
  # it required in turn is invisible there, and would survive a reload at its old
  # version. Compile metadata records the source path, so the code server can say which
  # loaded modules came from the files this load pulled in.
  defp loaded_modules(results, files) do
    direct = Enum.map(results, fn {module, _binary} -> module end)
    sources = MapSet.new(files, &String.to_charlist/1)

    siblings =
      for {module, _location} <- :code.all_loaded(),
          module not in direct,
          source = compile_source(module),
          MapSet.member?(sources, source),
          do: module

    direct ++ siblings
  end

  defp compile_source(module) do
    module.module_info(:compile)[:source]
  rescue
    # Purged between `all_loaded/0` and here, or compiled without the chunk.
    _ -> nil
  end

  # Picked by the marker `use Eva.Core.Extension` injects.
  defp extension_module(modules, path) do
    case Enum.filter(modules, &extension_module?/1) do
      [module] ->
        {:ok, module}

      [] ->
        {:error, "#{path} defines no module that uses Eva.Core.Extension"}

      many ->
        {:error,
         "#{path} defines #{length(many)} extension modules (#{inspect(many)}); expected one"}
    end
  end

  defp extension_module?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__eva_extension__, 0)
  end

  # A missing `setup/1` is only a compile warning from `@behaviour`, so check here.
  #
  # `use Eva.Core.Extension` already refuses a module outside `Eva.Extension.*`; this pins
  # it to *this* extension's own subtree, so `mcp` cannot define `Eva.Extension.Memory`
  # and quietly take a name that belongs to something else.
  defp validate(module, name, path) do
    expected = Eva.Core.Extension.namespace(name)

    # Case-insensitively, so an extension named `mcp` can call itself `Eva.Extension.MCP`
    # rather than `Eva.Extension.Mcp`.
    actual = module |> Atom.to_string() |> String.downcase()
    prefix = expected |> Atom.to_string() |> String.downcase()

    cond do
      not function_exported?(module, :setup, 1) ->
        {:error, "#{inspect(module)} in #{path} does not export setup/1"}

      actual != prefix and not String.starts_with?(actual, prefix <> ".") ->
        {:error,
         "#{path}: extension #{name} must define #{inspect(expected)}, got #{inspect(module)}"}

      true ->
        :ok
    end
  end

  # `:persistent_term.put/2` triggers a global GC scan — keep it off per-session paths.
  defp required_cache, do: :persistent_term.get(@cache_key, %{})

  defp cache_modules(path, modules) do
    :persistent_term.put(@cache_key, Map.put(required_cache(), path, modules))
  end

  defp drop_cached(path) do
    :persistent_term.put(@cache_key, Map.delete(required_cache(), path))
  end
end
