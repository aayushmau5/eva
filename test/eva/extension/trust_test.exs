defmodule Eva.Extension.TrustTest do
  use ExUnit.Case, async: false

  alias Eva.Coding.Resources
  alias Eva.Extension.{Loader, Set, Trust}

  defp tmp_dir do
    path = Path.join(System.tmp_dir!(), "trust_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp module_for(name), do: Eva.Core.Extension.namespace(name)

  defp extension(name) do
    ~s'''
    defmodule #{inspect(module_for(name))} do
      use Eva.Core.Extension

      def setup(_ctx), do: {:ok, %Eva.Core.Extension.Spec{guidelines: ["from #{name}"]}}
    end
    '''
  end

  # A root for the trust store and global extensions, plus a project directory with one
  # extension in it — the shape the gate exists for.
  defp project_setup(name) do
    root = tmp_dir()
    cwd = tmp_dir()
    project_dir = Path.join([cwd, ".eva", "extensions"])
    File.mkdir_p!(project_dir)
    File.write!(Path.join(project_dir, "#{name}.exs"), extension(name))

    {%Resources{root: root, cwd: cwd}, project_dir}
  end

  describe "candidates/2" do
    test "an unapproved project directory contributes nothing and is reported" do
      name = "untrusted_#{System.unique_integer([:positive])}"
      {resources, project_dir} = project_setup(name)

      {candidates, blocked} = Loader.candidates(resources)

      assert candidates == []
      assert blocked == [project_dir]
    end

    test "the same directory loads once approved" do
      name = "approved_#{System.unique_integer([:positive])}"
      {resources, project_dir} = project_setup(name)

      :ok = Trust.trust(resources, project_dir)

      {candidates, blocked} = Loader.candidates(resources)

      assert blocked == []
      assert List.keymember?(candidates, name, 0)
    end

    test "the global directory is never blocked" do
      name = "global_#{System.unique_integer([:positive])}"
      root = tmp_dir()
      global_dir = Path.join(root, "extensions")
      File.mkdir_p!(global_dir)
      File.write!(Path.join(global_dir, "#{name}.exs"), extension(name))

      {candidates, blocked} = Loader.candidates(%Resources{root: root, cwd: tmp_dir()})

      assert blocked == []
      assert List.keymember?(candidates, name, 0)
    end

    test "an explicit path loads even from an unapproved directory" do
      name = "explicit_#{System.unique_integer([:positive])}"
      {resources, project_dir} = project_setup(name)
      path = Path.join(project_dir, "#{name}.exs")

      {candidates, blocked} = Loader.candidates(resources, [path])

      assert blocked == [project_dir]
      assert List.keymember?(candidates, name, 0)
    end

    test "a project directory that does not exist is absent, not blocked" do
      resources = %Resources{root: tmp_dir(), cwd: tmp_dir()}

      assert {[], []} = Loader.candidates(resources)
    end
  end

  describe "trusted?/2" do
    test "editing an extension withdraws consent" do
      name = "edited_#{System.unique_integer([:positive])}"
      {resources, project_dir} = project_setup(name)

      :ok = Trust.trust(resources, project_dir)
      assert Trust.trusted?(resources, project_dir)

      File.write!(Path.join(project_dir, "#{name}.exs"), extension(name) <> "\n# changed\n")

      refute Trust.trusted?(resources, project_dir)
    end

    test "adding an extension withdraws consent" do
      name = "added_#{System.unique_integer([:positive])}"
      {resources, project_dir} = project_setup(name)

      :ok = Trust.trust(resources, project_dir)
      File.write!(Path.join(project_dir, "sneaky.exs"), extension("sneaky"))

      refute Trust.trusted?(resources, project_dir)
    end

    test "a README changing does not" do
      name = "readme_#{System.unique_integer([:positive])}"
      {resources, project_dir} = project_setup(name)

      :ok = Trust.trust(resources, project_dir)
      File.write!(Path.join(project_dir, "README.md"), "# notes")

      assert Trust.trusted?(resources, project_dir)
    end

    test "revoke/2 forgets a directory" do
      name = "revoked_#{System.unique_integer([:positive])}"
      {resources, project_dir} = project_setup(name)

      :ok = Trust.trust(resources, project_dir)
      :ok = Trust.revoke(resources, project_dir)

      refute Trust.trusted?(resources, project_dir)
    end

    test "consent is per directory" do
      name = "scoped_#{System.unique_integer([:positive])}"
      {resources, project_dir} = project_setup(name)
      other = tmp_dir()

      :ok = Trust.trust(resources, project_dir)

      refute Trust.trusted?(resources, other)
    end
  end

  describe "Set.trust_all/1" do
    test "approves what was blocked, and a reload picks it up" do
      name = "set_trust_#{System.unique_integer([:positive])}"
      {resources, project_dir} = project_setup(name)

      set = Set.load(resources, self())

      assert set.blocked_dirs == [project_dir]
      refute name in set.order
      assert Enum.any?(set.diagnostics, &String.contains?(&1, "not been approved"))

      assert {:ok, [^project_dir]} = Set.trust_all(set)

      reloaded = Set.load(resources, self())

      assert reloaded.blocked_dirs == []
      assert name in reloaded.order
      assert "from #{name}" in Set.guidelines(reloaded)
    end

    test "is a no-op when nothing is blocked" do
      set = Set.load(%Resources{root: tmp_dir(), cwd: tmp_dir()}, self())

      assert {:ok, []} = Set.trust_all(set)
    end
  end
end
