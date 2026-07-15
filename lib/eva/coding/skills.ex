defmodule Eva.Coding.Skills do
  use TypedStruct

  alias Eva.Coding.Resources
  alias Eva.Agent.Utils

  typedstruct do
    field :name, String.t(), enforce: true
    field :path, String.t(), enforce: true
    field :content, String.t(), enforce: true
    field :description, String.t()
  end

  @doc """
  Load skills from resource paths.
  """
  @spec load(Resources.t() | nil) :: [t()]
  def load(resources \\ %Resources{}) do
    Resources.skills_dirs(resources)
    |> Enum.flat_map(&load_skills_from_dir/1)
    |> Enum.uniq_by(& &1.name)
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Expand the `/skill:name` prompt text. Retruns `nil` for non-skill text.
  """
  @spec expand_skill_command(String.t(), [t()]) :: {:ok, String.t() | nil} | {:error, String.t()}
  def expand_skill_command(text, skills) do
    stripped_text = String.trim(text)

    if not String.starts_with?(stripped_text, "/skill:") do
      {:ok, nil}
    else
      {command, request} =
        case String.split(stripped_text, " ", parts: 2) do
          [first, second] -> {String.trim(first), String.trim(second)}
          [first] -> {String.trim(first), nil}
        end

      skill_name = String.replace_prefix(command, "/skill:", "")

      if String.length(skill_name) == 0 do
        {:error, "Skill command must include a skill name"}
      else
        case Enum.find(skills, &(&1.name == skill_name)) do
          nil ->
            {:error, "Unknown skill: #{skill_name}"}

          skill ->
            additional_instructions =
              if request != nil and String.length(request) > 0, do: request, else: nil

            {:ok, format_skill_invocation(skill, additional_instructions)}
        end
      end
    end
  end

  @doc """
  Builds skill index lines.
  """
  @spec skills_index([t()]) :: String.t()
  def skills_index(skills) do
    if length(skills) == 0 do
      "Available skills: none"
    else
      lines =
        Enum.sort_by(skills, & &1.name)
        |> Enum.map(fn skill ->
          description =
            if is_nil(skill.description), do: "No description", else: skill.description

          "- #{skill.name}: #{description}"
        end)

      ["Available skills:" | lines]
      |> Enum.join("\n")
    end
  end

  defp load_skills_from_dir(skills_dir) do
    if not File.exists?(skills_dir) or not File.dir?(skills_dir) do
      []
    else
      skills_dir
      |> File.ls!()
      |> Enum.sort()
      |> Enum.reduce({[], MapSet.new()}, fn name, {skills, seen} ->
        path = Path.join(skills_dir, name)

        result =
          if File.dir?(path) do
            skill_md = Path.join(path, "SKILL.md")
            if File.exists?(skill_md), do: {:ok, name, skill_md}, else: :skip
          else
            :skip
          end

        case result do
          :skip ->
            {skills, seen}

          {:ok, skill_name, skill_path} ->
            if MapSet.member?(seen, skill_name) do
              {skills, seen}
            else
              skill = load_skill(skill_name, skill_path)
              {[skill | skills], MapSet.put(seen, skill_name)}
            end
        end
      end)
      |> elem(0)
      |> Enum.reverse()
    end
  end

  defp load_skill(name, path) do
    {metadata, content} = File.read!(path) |> Utils.parse_markdown_resource()
    description = Map.get(metadata, "description", Utils.derive_description(content))
    %__MODULE__{name: name, path: path, content: content, description: description}
  end

  defp format_skill_invocation(%__MODULE__{} = skill, additional_instructions) do
    parent_dir = Path.dirname(skill.path)

    block = [
      ~s(<skill name="#{skill.name}" location="#{skill.path}">),
      ~s(References are relative to #{parent_dir}.),
      "",
      ~s(#{String.trim(skill.content)}),
      ~s(</skill>)
    ]

    block =
      if not is_nil(additional_instructions),
        do: block ++ [additional_instructions],
        else: block

    Enum.join(block, "\n")
  end
end
