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

  # Loaded modules are cached in persistent_term by this cache key.
  @cache_key {__MODULE__, :required_paths}

  typedstruct module: Loaded do
    field :name, String.t()
    field :path, String.t()
    field :module, module()
  end

  @doc """
  Discovers extension files.
  """
  @spec candidates(Resources.t(), [String.t()]) :: [{name :: String.t(), path :: String.t()}]
  def candidates(%Resources{} = resources, extra_paths \\ []) do
    dir_candidates =
      resources
      |> Resources.extensions_dir()
      |> Enum.flat_map(&candidates_in_dir/1)

    extra_candidates =
      extra_paths
      |> Enum.map(&candidate_from_path/1)
      |> Enum.reject(&is_nil/1)

    (dir_candidates ++ extra_candidates)
    |> dedup_by_name()
  end

  @doc """
  Loads the extension into the VM.
  """
  @spec discover([{String.t(), String.t()}]) :: {[Loaded.t()], [String.t()]}
  def load(candidates) do
    candidates
    |> Enum.reduce({[], [], MapSet.new()}, &load_into_acc/2)
    |> then(fn {loaded, diagnostics, _seen} ->
      {Enum.reverse(loaded), Enum.reverse(diagnostics)}
    end)
  end

  @doc """
  Finds and loads every extension reachable from `resources`, plus any `extra_paths`.
  Returns `{loaded, diagnostics}`.
  """
  @spec discover(Resources.t(), [String.t()]) :: {[Loaded.t()], [String.t()]}
  def discover(%Resources{} = resources, extra_paths \\ []) do
    resources |> candidates(extra_paths) |> load()
  end

  @doc """
  Unloads extension modules so the next `discover/2` recompiles them from disk.

  Stop the extension processes first — `:code.purge/1` kills anything still running
  the old code.
  """
  @spec purge([Loaded.t()]) :: :ok
  def purge(loaded) do
    loaded |> Enum.map(& &1.path) |> Code.unrequire_files()

    Enum.each(loaded, fn %Loaded{module: module, path: path} ->
      # `delete` only moves the current version to "old"; the second purge removes it.
      # Without it the next require warns about redefining, which fails precommit.
      :code.purge(module)
      :code.delete(module)
      :code.purge(module)
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
          reason = "#{path} defines #{inspect(module)}, already claimed by another extension"
          {loaded, [reason | diagnostics], seen_modules}
        else
          {[extension | loaded], diagnostics, MapSet.put(seen_modules, module)}
        end

      {:error, reason} ->
        {loaded, [reason | diagnostics], seen_modules}
    end
  end

  defp load_one(name, path) do
    with {:ok, modules} <- require_modules(path),
         {:ok, module} <- extension_module(modules, path),
         :ok <- validate(module, path) do
      {:ok, %Loaded{name: name, path: path, module: module}}
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
    case Code.require_file(path) do
      nil ->
        case Map.fetch(required_cache(), path) do
          {:ok, modules} -> {:ok, modules}
          :error -> {:error, "#{path} was already required but is missing from the loader cache"}
        end

      results when is_list(results) ->
        modules = Enum.map(results, fn {module, _binary} -> module end)
        cache_modules(path, modules)
        {:ok, modules}
    end
  rescue
    e -> {:error, "#{path} failed to compile: #{Exception.message(e)}"}
  catch
    kind, reason -> {:error, "#{path} failed to load: #{Exception.format(kind, reason)}"}
  end

  # Picked by the marker `use Eva.Extension` injects.
  defp extension_module(modules, path) do
    case Enum.filter(modules, &extension_module?/1) do
      [module] ->
        {:ok, module}

      [] ->
        {:error, "#{path} defines no module that uses Eva.Extension"}

      many ->
        {:error,
         "#{path} defines #{length(many)} extension modules (#{inspect(many)}); expected one"}
    end
  end

  defp extension_module?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__eva_extension__, 0)
  end

  # A missing `setup/1` is only a compile warning from `@behaviour`, so check here.
  defp validate(module, path) do
    if function_exported?(module, :setup, 1) do
      :ok
    else
      {:error, "#{inspect(module)} in #{path} does not export setup/1"}
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
