defmodule Eva.Extension.PackageTest do
  @moduledoc """
  Registering project extensions.

  There is no build step here any more: Eva does not compile an extension, does not load
  it, and does not assemble its VM. Registering records where it is and how to start it,
  which is why these tests are fast — the previous version of this file shelled out to
  `mix deps.get` and `mix compile` and took eight seconds.
  """

  use ExUnit.Case, async: false

  alias Eva.Coding.Resources
  alias Eva.Extension.{Package, Registry}

  defp tmp_dir do
    path = Path.join(System.tmp_dir!(), "package_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  # A project as it looks on disk. It is never compiled here, so `lib/` can stay empty —
  # what `add` reads is the app name, and nothing else.
  defp unique_app(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp write_project(dir, app) do
    File.mkdir_p!(Path.join(dir, "lib"))

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule #{Macro.camelize(app)}.MixProject do
      use Mix.Project

      def project, do: [app: :#{app}, version: "0.1.0", elixir: "~> 1.20"]
      def application, do: [extra_applications: [:logger]]
    end
    """)

    dir
  end

  setup do
    root = tmp_dir()
    %{root: root, resources: %Resources{root: root}}
  end

  describe "add/3" do
    test "records where it is and how to start it", %{root: root, resources: resources} do
      app = unique_app("eva_notes")
      dir = write_project(Path.join(root, "src"), app)

      assert {:ok, entry} = Package.add(resources, dir)

      # The app is `eva_notes_1`; the extension is `notes_1` — what the user types, what
      # the entry is keyed by, and what the node announces itself as.
      name = String.replace_prefix(app, "eva_", "")

      assert entry == %{
               "name" => name,
               "kind" => "project",
               "dir" => dir,
               "start" => ["mix", "run", "--no-halt"]
             }

      assert {:ok, ^entry} = Registry.fetch(resources, name)
    end

    test "an app without the eva_ prefix keeps its name", %{root: root, resources: resources} do
      app = unique_app("notes")
      dir = write_project(Path.join(root, "src"), app)

      assert {:ok, %{"name" => ^app}} = Package.add(resources, dir)
    end

    test "the name and start command can be given explicitly", %{
      root: root,
      resources: resources
    } do
      dir = write_project(Path.join(root, "src"), unique_app("eva_notes"))

      assert {:ok, entry} =
               Package.add(resources, dir, name: "scratch", start: ["./run.sh", "--fast"])

      assert entry["name"] == "scratch"
      assert entry["start"] == ["./run.sh", "--fast"]
    end

    test "a directory that is not a project is refused", %{root: root, resources: resources} do
      assert {:error, reason} = Package.add(resources, root)
      assert reason =~ "no mix.exs"

      assert {:error, reason} = Package.add(resources, Path.join(root, "nowhere"))
      assert reason =~ "is not a directory"
    end

    test "adding twice replaces rather than duplicating", %{root: root, resources: resources} do
      dir = write_project(Path.join(root, "src"), unique_app("eva_notes"))

      {:ok, _} = Package.add(resources, dir)
      {:ok, _} = Package.add(resources, dir, start: ["mix", "run", "--no-halt", "--verbose"])

      assert [%{"start" => ["mix", "run", "--no-halt", "--verbose"]}] = Registry.read(resources)
    end
  end

  describe "list/1 and remove/2" do
    test "nothing registered is not an error", %{resources: resources} do
      assert Package.list(resources) == []
      assert Package.allowed_names(resources) == []
    end

    test "a registered extension is listed as not running", %{
      root: root,
      resources: resources
    } do
      dir = write_project(Path.join(root, "src"), unique_app("eva_notes"))
      {:ok, entry} = Package.add(resources, dir)

      # Nothing has announced, and with distribution off nothing can.
      assert Package.list(resources) == [{entry, :not_running}]
      assert Package.allowed_names(resources) == [entry["name"]]
    end

    test "remove unregisters and leaves the code alone", %{root: root, resources: resources} do
      dir = write_project(Path.join(root, "src"), unique_app("eva_notes"))
      {:ok, %{"name" => name}} = Package.add(resources, dir)

      assert {:ok, %{"name" => ^name}} = Package.remove(resources, name)
      assert Registry.read(resources) == []
      assert File.regular?(Path.join(dir, "mix.exs"))

      assert {:error, reason} = Package.remove(resources, name)
      assert reason =~ "not registered"
    end
  end

  describe "start/2 and stop/2" do
    test "starting something unregistered says so", %{resources: resources} do
      assert {:error, reason} = Package.start(resources, "nope")
      assert reason =~ "not registered"
    end

    test "stopping something that never announced says so", %{resources: resources} do
      assert {:error, reason} = Package.stop(resources, "nope")
      assert reason =~ "not running"
    end
  end
end
