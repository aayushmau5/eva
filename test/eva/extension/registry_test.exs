defmodule Eva.Extension.RegistryTest do
  use ExUnit.Case, async: true

  alias Eva.Coding.Resources
  alias Eva.Extension.Registry

  defp resources do
    root = Path.join(System.tmp_dir!(), "registry_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %Resources{root: root}
  end

  defp entry(name, overrides \\ %{}) do
    Map.merge(
      %{
        "name" => name,
        "kind" => "project",
        "dir" => "/packages/#{name}",
        "start" => ["mix", "run", "--no-halt"]
      },
      overrides
    )
  end

  test "an absent registry reads as empty" do
    assert Registry.read(resources()) == []
  end

  test "a corrupt registry reads as empty rather than crashing the session" do
    resources = resources()
    File.write!(Registry.store_path(resources), "{not json")

    assert Registry.read(resources) == []
  end

  test "put/2 appends, and round-trips through the file" do
    resources = resources()

    :ok = Registry.put(resources, entry("mcp"))
    :ok = Registry.put(resources, entry("memory"))

    assert Enum.map(Registry.read(resources), & &1["name"]) == ["mcp", "memory"]
    assert {:ok, %{"dir" => "/packages/mcp"}} = Registry.fetch(resources, "mcp")
    assert Registry.fetch(resources, "nope") == :error
  end

  test "put/2 replaces in place, keeping position" do
    resources = resources()

    :ok = Registry.put(resources, entry("a"))
    :ok = Registry.put(resources, entry("b"))
    :ok = Registry.put(resources, entry("a", %{"dir" => "/moved"}))

    assert Enum.map(Registry.read(resources), & &1["name"]) == ["a", "b"]
    assert {:ok, %{"dir" => "/moved"}} = Registry.fetch(resources, "a")
  end

  test "delete/2 removes, and removing what isn't there is fine" do
    resources = resources()

    :ok = Registry.put(resources, entry("mcp"))
    :ok = Registry.delete(resources, "mcp")
    :ok = Registry.delete(resources, "mcp")

    assert Registry.read(resources) == []
  end

  test "no temp file is left behind" do
    resources = resources()
    :ok = Registry.put(resources, entry("mcp"))

    refute File.exists?(Registry.store_path(resources) <> ".tmp")
  end
end
