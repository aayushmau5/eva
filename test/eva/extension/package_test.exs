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

  describe "extensions on another machine" do
    test "are registered with where to dial and nothing else", %{resources: resources} do
      assert {:ok, entry} = Package.add_remote(resources, "gpu", "100.64.5.20", 9001)

      assert entry == %{
               "name" => "gpu",
               "kind" => "remote",
               "host" => "100.64.5.20",
               "port" => 9001
             }

      # No `dir`, no `start`. Those are facts about a machine we do not own.
      refute Map.has_key?(entry, "dir")
      refute Map.has_key?(entry, "start")
      assert Registry.remote(resources) == [entry]
    end

    # Lifecycle is local. Eva chooses whether to connect to another machine; it does not
    # run commands there, which is what keeps remote execution and credentials out of this.
    test "cannot be started from here", %{resources: resources} do
      {:ok, _entry} = Package.add_remote(resources, "gpu", "100.64.5.20", 9001)

      assert {:error, reason} = Package.start(resources, "gpu")
      assert reason =~ "lives on 100.64.5.20"
      assert reason =~ "start it there"
    end

    test "cannot be stopped from here", %{resources: resources} do
      {:ok, _entry} = Package.add_remote(resources, "gpu", "100.64.5.20", 9001)

      assert {:error, reason} = Package.stop(resources, "gpu")
      assert reason =~ "stop it there"
    end

    test "are listed as unreachable when nothing answers", %{resources: resources} do
      {:ok, entry} = Package.add_remote(resources, "gpu", "100.64.5.20", 9001)

      # Two states, not three: with no epmd on the other machine we cannot tell "never
      # started" from "asleep", and saying `:not_running` would be a guess.
      assert [{^entry, :unreachable}] = Package.list(resources)
    end

    test "a name is derived from the entry, since we cannot ask the other machine" do
      entry = %{"name" => "gpu", "kind" => "remote", "host" => "100.64.5.20", "port" => 9001}

      assert Registry.node_name(entry) == :"eva_ext_gpu@100.64.5.20"
    end
  end
end
