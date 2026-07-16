defmodule Eva.Coding.ProjectContext do
  @moduledoc """
  Project instruction files such as AGENTS.md.
  """

  use TypedStruct

  alias Eva.Coding.Resources

  @markers [
    ".git",
    "pyproject.toml",
    "uv.lock",
    "package.json",
    "mix.exs",
    "mix.lock",
    "cargo.toml"
  ]

  typedstruct module: ContextFile do
    field :path, String.t()
    field :content, String.t()
  end

  @spec discover(Resources.t()) :: [ContextFile.t()]
  def discover(resources \\ %Resources{}) do
    {context_files, _} = discover_with_diagnostics(resources)
    context_files
  end

  @spec discover_with_diagnostics(Resources.t()) :: {[ContextFile.t()], [String.t()]}
  def discover_with_diagnostics(resources \\ %Resources{}) do
    context_file_candidates(resources)
    |> Enum.reduce({[], []}, fn context_file_path, {context_files, diagnostics} ->
      case File.read(context_file_path) do
        {:ok, content} ->
          {[%ContextFile{path: context_file_path, content: content} | context_files], diagnostics}

        {:error, reason} ->
          # TODO: replace with proper diagnostic stuff
          {context_files, [reason | diagnostics]}
      end
    end)
    |> then(fn {context_files, diagnostics} ->
      {Enum.reverse(context_files), Enum.reverse(diagnostics)}
    end)
  end

  @type path :: String.t()

  @spec context_file_candidates(Resources.t()) :: [path]
  defp context_file_candidates(%Resources{} = resources) do
    ([Path.join(resources.root, "AGENTS.md")] ++
       if(resources.agents_root,
         do: [Path.join(resources.agents_root, "AGENTS.md")],
         else: []
       ) ++
       if(resources.cwd,
         do: candidates_for_cwd(resources.cwd),
         else: []
       ))
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  defp candidates_for_cwd(cwd) do
    cwd = Path.expand(cwd)

    find_project_root(cwd)
    |> ancestor_agents_files(cwd)
    |> Kernel.++([
      Path.join([cwd, ".eva", "AGENTS.md"]),
      Path.join([cwd, ".agents", "AGENTS.md"])
    ])
  end

  defp ancestor_agents_files(project_root, cwd) do
    case Path.relative_to(cwd, project_root) do
      ^cwd ->
        # Path.relative_to returns cwd if there's no relative to
        [Path.join(cwd, "AGENTS.md")]

      relative ->
        [
          project_root
          | Enum.scan(Path.split(relative), project_root, fn segment, dir ->
              Path.join(dir, segment)
            end)
        ]
        |> Enum.map(&Path.join(&1, "AGENTS.md"))
    end
  end

  # Get the project's root path
  defp find_project_root(cwd) do
    cwd
    |> Stream.iterate(&Path.dirname/1)
    |> Stream.take_while(&(&1 != Path.dirname(&1)))
    |> Enum.find(cwd, fn path ->
      Enum.any?(@markers, &File.regular?(Path.join(path, &1)))
    end)
  end
end
