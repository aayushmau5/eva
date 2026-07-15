defmodule Eva.Coding.SkillsTest do
  use ExUnit.Case

  alias Eva.Coding.Skills
  alias Eva.Coding.Resources

  @tmp_root Path.expand("tmp/test/skills")

  setup do
    tmp =
      @tmp_root
      |> Path.join("#{System.unique_integer([:positive, :monotonic])}")
      |> tap(&File.mkdir_p!/1)

    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  defp make_skill_dir(skills_dir, name, content) do
    skill_dir = Path.join(skills_dir, name)
    File.mkdir_p!(skill_dir)
    File.write!(Path.join(skill_dir, "SKILL.md"), content)
    skill_dir
  end

  describe "load/1" do
    test "returns empty list when skills_dir does not exist" do
      resources = %Resources{root: "/nonexistent/path"}
      assert Skills.load(resources) == []
    end

    test "loads skills from a directory with SKILL.md files", %{tmp: tmp} do
      skill_dir = Path.join(tmp, "skills")
      File.mkdir_p!(skill_dir)
      make_skill_dir(skill_dir, "my-skill", "# My Skill\n\nDoes cool things.")

      resources = %Resources{root: tmp}
      skills = Skills.load(resources)

      assert length(skills) == 1
      assert hd(skills).name == "my-skill"
    end

    test "reads frontmatter description from SKILL.md", %{tmp: tmp} do
      skill_dir = Path.join(tmp, "skills")
      File.mkdir_p!(skill_dir)

      content = "---\ndescription: A described skill\n---\n\n# Body\n\nSome content."
      make_skill_dir(skill_dir, "my-skill", content)

      resources = %Resources{root: tmp}
      skills = Skills.load(resources)

      assert length(skills) == 1
      assert hd(skills).description == "A described skill"
    end

    test "derives description from heading when no frontmatter", %{tmp: tmp} do
      skill_dir = Path.join(tmp, "skills")
      File.mkdir_p!(skill_dir)

      make_skill_dir(skill_dir, "my-skill", "# Skill Heading\n\nNo frontmatter here.")

      resources = %Resources{root: tmp}
      skills = Skills.load(resources)

      assert length(skills) == 1
      assert hd(skills).description == "Skill Heading"
    end

    test "skips directory that has no SKILL.md", %{tmp: tmp} do
      skill_dir = Path.join(tmp, "skills")
      File.mkdir_p!(skill_dir)
      File.mkdir_p!(Path.join(skill_dir, "empty-skill"))

      resources = %Resources{root: tmp}
      assert Skills.load(resources) == []
    end

    test "skips bare .md files in skills dir", %{tmp: tmp} do
      skill_dir = Path.join(tmp, "skills")
      File.mkdir_p!(skill_dir)
      File.write!(Path.join(skill_dir, "bare.md"), "# I am a bare file")

      resources = %Resources{root: tmp}
      assert Skills.load(resources) == []
    end

    test "deduplicates skills by name across skills directories", %{tmp: tmp} do
      skills_dir = Path.join(tmp, "skills")
      cwd_skills_dir = Path.join([tmp, ".eva", "skills"])
      File.mkdir_p!(skills_dir)
      File.mkdir_p!(cwd_skills_dir)

      make_skill_dir(skills_dir, "dup-skill", "# First\n\nContent A.")
      make_skill_dir(cwd_skills_dir, "dup-skill", "# Second\n\nContent B.")

      resources = %Resources{root: tmp, cwd: tmp}

      skills = Skills.load(resources)

      assert length(skills) == 1
      assert hd(skills).name == "dup-skill"
      assert hd(skills).content =~ "Content A."
    end

    test "loads multiple skills sorted alphabetically", %{tmp: tmp} do
      skill_dir = Path.join(tmp, "skills")
      File.mkdir_p!(skill_dir)

      make_skill_dir(skill_dir, "zebra-skill", "# Zebra\n\nLast.")
      make_skill_dir(skill_dir, "alpha-skill", "# Alpha\n\nFirst.")
      make_skill_dir(skill_dir, "mango-skill", "# Mango\n\nMiddle.")

      resources = %Resources{root: tmp}
      skills = Skills.load(resources)

      assert length(skills) == 3
      assert Enum.map(skills, & &1.name) == ["alpha-skill", "mango-skill", "zebra-skill"]
    end

    test "loads from multiple skills directories", %{tmp: tmp} do
      main_skills = Path.join(tmp, "skills")
      cwd_skills = Path.join([tmp, ".eva", "skills"])
      File.mkdir_p!(main_skills)
      File.mkdir_p!(cwd_skills)

      make_skill_dir(main_skills, "skill-a", "# Skill A\n\nContent A.")
      make_skill_dir(cwd_skills, "skill-b", "# Skill B\n\nContent B.")

      resources = %Resources{root: tmp, cwd: tmp}

      skills = Skills.load(resources)

      assert length(skills) == 2
    end

    test "path stored is the SKILL.md path", %{tmp: tmp} do
      skill_dir = Path.join(tmp, "skills")
      File.mkdir_p!(skill_dir)

      skill_md_path = Path.join([skill_dir, "my-skill", "SKILL.md"])
      make_skill_dir(skill_dir, "my-skill", "# My Skill\n\nContent.")

      resources = %Resources{root: tmp}
      skills = Skills.load(resources)

      assert length(skills) == 1
      assert hd(skills).path == skill_md_path
    end

    test "content is the full SKILL.md body", %{tmp: tmp} do
      skill_dir = Path.join(tmp, "skills")
      File.mkdir_p!(skill_dir)

      content = "# Heading\n\nSome body text.\n\nMore text."
      make_skill_dir(skill_dir, "my-skill", content)

      resources = %Resources{root: tmp}
      skills = Skills.load(resources)

      assert length(skills) == 1
      assert hd(skills).content =~ "Some body text."
    end
  end

  describe "expand_skill_command/2" do
    test "returns {:ok, nil} for non-skill text" do
      assert Skills.expand_skill_command("hello world", []) == {:ok, nil}
    end

    test "returns {:ok, nil} for empty string" do
      assert Skills.expand_skill_command("", []) == {:ok, nil}
    end

    test "returns error for /skill: with no name" do
      assert {:error, msg} = Skills.expand_skill_command("/skill:", [])
      assert msg =~ "must include a skill name"
    end

    test "returns error for /skill: followed by whitespace" do
      assert {:error, msg} = Skills.expand_skill_command("/skill:   ", [])
      assert msg =~ "must include a skill name"
    end

    test "returns error for unknown skill" do
      skill = %Skills{name: "known", path: "/tmp/skill.md", content: "some content"}

      assert {:error, msg} = Skills.expand_skill_command("/skill:unknown", [skill])
      assert msg =~ "Unknown skill: unknown"
    end

    test "returns formatted invocation for matching skill" do
      skill = %Skills{
        name: "my-skill",
        path: "/tmp/my-skill/SKILL.md",
        content: "# My Skill\n\nI do things."
      }

      assert {:ok, result} = Skills.expand_skill_command("/skill:my-skill", [skill])
      assert result =~ ~s(<skill name="my-skill")
      assert result =~ ~s(location="/tmp/my-skill/SKILL.md")
      assert result =~ "References are relative to /tmp/my-skill"
      assert result =~ "I do things."
      assert result =~ "</skill>"
    end

    test "trims whitespace around the command" do
      skill = %Skills{
        name: "my-skill",
        path: "/tmp/my-skill/SKILL.md",
        content: "content"
      }

      assert {:ok, result} = Skills.expand_skill_command("  /skill:my-skill  ", [skill])
      assert result =~ ~s(<skill name="my-skill")
    end

    test "includes additional instructions when provided" do
      skill = %Skills{
        name: "my-skill",
        path: "/tmp/my-skill/SKILL.md",
        content: "skill body"
      }

      assert {:ok, result} =
               Skills.expand_skill_command("/skill:my-skill do this extra thing", [skill])

      assert result =~ "</skill>"
      assert result =~ "do this extra thing"
    end

    test "returns nil instructions when none provided" do
      skill = %Skills{
        name: "my-skill",
        path: "/tmp/my-skill/SKILL.md",
        content: "skill body"
      }

      assert {:ok, result} = Skills.expand_skill_command("/skill:my-skill", [skill])
      assert result =~ ~s(<skill name="my-skill")
      refute result =~ "\n\n\n"
    end
  end

  describe "skills_index/1" do
    test "returns 'none' for empty skills" do
      assert Skills.skills_index([]) == "Available skills: none"
    end

    test "lists skills with descriptions" do
      skills = [
        %Skills{name: "alpha", path: "/t/a.md", content: "a", description: "Alpha skill"},
        %Skills{name: "beta", path: "/t/b.md", content: "b", description: "Beta skill"}
      ]

      result = Skills.skills_index(skills)

      assert result =~ "Available skills:"
      assert result =~ "- alpha: Alpha skill"
      assert result =~ "- beta: Beta skill"
    end

    test "sorts skills alphabetically" do
      skills = [
        %Skills{name: "zulu", path: "/t/z.md", content: "z", description: "Z"},
        %Skills{name: "alpha", path: "/t/a.md", content: "a", description: "A"},
        %Skills{name: "mike", path: "/t/m.md", content: "m", description: "M"}
      ]

      result = Skills.skills_index(skills)
      lines = String.split(result, "\n")

      assert Enum.at(lines, 1) =~ "- alpha:"
      assert Enum.at(lines, 2) =~ "- mike:"
      assert Enum.at(lines, 3) =~ "- zulu:"
    end

    test "shows 'No description' when description is nil" do
      skills = [
        %Skills{name: "no-desc", path: "/t/n.md", content: "c", description: nil}
      ]

      result = Skills.skills_index(skills)

      assert result =~ "- no-desc: No description"
    end
  end
end
