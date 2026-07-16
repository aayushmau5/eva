defmodule Eva.Coding.SystemPrompt do
  use TypedStruct

  alias Eva.Agent.Tools

  alias Eva.Coding.Skills
  alias Eva.Coding.ProjectContext

  typedstruct module: Options do
    field :cwd, String.t(), enforce: true
    field :tools, [Tools.tool()] | [], default: []
    field :skills, [Skills.t()], default: []
    field :custom_prompt, String.t()
    field :append_system_prompt, String.t()
    field :context_files, [ProjectContext.ContextFile.t()], default: []
    field :current_date, Date.t()
    field :extra_guidelines, [String.t()], default: []
  end

  @spec build(options :: __MODULE__.Options.t()) :: String.t()
  def build(options) do
    current_date =
      if not is_nil(options.current_date),
        do: options.current_date,
        else: DateTime.now!("Etc/UTC") |> DateTime.to_date()

    append_section =
      if not is_nil(options.append_system_prompt),
        do: "\n\n#{options.append_system_prompt}",
        else: ""

    prompt =
      if not is_nil(options.custom_prompt) do
        options.custom_prompt
      else
        """
        You are an expert coding assistant operating inside Eva, a coding agent harness.
        You help users by reading files, executing commands, editing code, and writing new files.

        Available tools:
        #{format_available_tools(options.tools)}

        In addition to the tools above, you may have access to other custom tools depending on the project.

        Guidelines:
        #{format_guidelines(options)}
        """
      end

    prompt =
      prompt <>
        append_section <>
        format_project_context(options) <>
        format_skills_for_prompt(options) <>
        "\nCurrent date: #{Date.to_iso8601(current_date)}" <>
        "\nCurrent working directory: #{options.cwd}"

    prompt
  end

  defp format_project_context(%Options{} = options) do
    context_files = options.context_files

    if length(context_files) > 0 do
      lines = ["\n\n<project_context>", "", "Project-specific instructions and guidelines:", ""]

      context_lines =
        Enum.flat_map(context_files, fn file ->
          [
            ~s(<project_instructions path="#{file.path}">),
            file.content,
            "</project_instructions>",
            ""
          ]
        end)

      Enum.concat([lines, context_lines, ["</project_context>"]]) |> Enum.join("\n")
    else
      ""
    end
  end

  defp format_skills_for_prompt(%Options{} = options) do
    if Enum.any?(options.tools, &(&1.name == "read")) && length(options.skills) > 0 do
      lines = [
        "\n\nThe following skills provide specialized instructions for specific tasks.",
        "Read the full skill file when the task matches its description.",
        "When a skill file references a relative path, resolve it against the skill directory ",
        "(parent of SKILL.md / dirname of the path) and use that absolute path in tool commands.\n",
        "<available_skills>"
      ]

      skills_lines =
        Enum.flat_map(options.skills, fn skill ->
          description =
            if is_nil(skill.description), do: "No description", else: skill.description

          [
            "  <skill>",
            "    <name>#{skill.name}</name>",
            "    <description>#{description}</description>",
            "    <location>#{skill.path}</location>",
            "  </skill>"
          ]
        end)

      Enum.concat([lines, skills_lines, ["</available_skills>"]]) |> Enum.join("\n")
    else
      ""
    end
  end

  # Format visible tools using prompt snippets.
  @spec format_available_tools(tools :: [Tools.tool()]) :: String.t()
  defp format_available_tools(tools) do
    tools
    |> Enum.filter(&(not is_nil(&1.prompt_snippet)))
    |> Enum.map(&"- #{&1.name}: #{&1.prompt_snippet}")
    |> Enum.join("\n")
  end

  defp format_guidelines(options) do
    collect_prompt_guidelines(options.tools, options.extra_guidelines)
    |> Enum.map(&("- " <> &1))
    |> Enum.join("\n")
  end

  defp collect_prompt_guidelines(tools, extra_guidelines) do
    tool_names = Enum.map(tools, & &1.name)
    has_bash? = "bash" in tool_names
    has_exploration_tools? = Enum.any?(["grep", "find", "ls"], &(&1 in tool_names))

    guidelines =
      if has_bash? do
        if has_exploration_tools?,
          do: [
            "Prefer grep/find/ls tools over bash for file exploration (faster, respects .gitignore)"
          ],
          else: ["Use bash for file operations like ls, rg, find"]
      else
        []
      end

    tool_guidelines = Enum.map(tools, & &1.prompt_guidelines) |> List.flatten()

    guidelines ++
      tool_guidelines ++
      extra_guidelines ++
      ["Be concise in your responses", "Show file paths clearly when working with files"]
  end
end
