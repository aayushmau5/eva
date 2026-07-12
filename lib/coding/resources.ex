defmodule Eva.Coding.Resources do
  @moduledoc """
  Resources like skills/prompt templates.

  Defines where to look for skills and prompt templates(with precendence chain).
  """
  use TypedStruct

  typedstruct do
    field :root, String.t(), default: Path.join(Path.expand("~"), ".eva")
    field :cwd, String.t(), default: nil
    field :agents_root, String.t(), default: Path.join(Path.expand("~"), ".agents")
  end

  def skills_dir(%__MODULE__{} = resources) do
    Path.join(resources.root, "skills")
  end

  def prompts_dir(%__MODULE__{} = resources) do
    Path.join(resources.root, "prompts")
  end

  def skills_dirs(%__MODULE__{} = resources) do
    dirs = [skills_dir(resources)]

    dirs =
      if not is_nil(resources.agents_root),
        do: dirs ++ [Path.join(resources.agents_root, "skills")],
        else: dirs

    dirs =
      if not is_nil(resources.cwd),
        do:
          dirs ++
            [
              Path.join([resources.cwd, ".eva", "skills"]),
              Path.join([resources.cwd, ".agents", "skills"])
            ],
        else: dirs

    dedup_paths(dirs)
  end

  def prompts_dirs(%__MODULE__{} = resources) do
    dirs = [prompts_dir(resources)]

    dirs =
      if not is_nil(resources.agents_root),
        do: dirs ++ [Path.join(resources.agents_root, "prompts")],
        else: dirs

    dirs =
      if not is_nil(resources.cwd),
        do:
          dirs ++
            [
              Path.join([resources.cwd, ".eva", "prompts"]),
              Path.join([resources.cwd, ".agents", "prompts"])
            ],
        else: dirs

    dedup_paths(dirs)
  end

  defp dedup_paths(paths) do
    paths
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end
end
