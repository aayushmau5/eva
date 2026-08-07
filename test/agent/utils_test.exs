defmodule Eva.Agent.UtilsTest do
  use ExUnit.Case, async: true

  alias Eva.Core.Agent.Messages
  alias Eva.Agent.Session.Entries.SessionIndexEntry
  alias Eva.Core.Agent.Utils

  describe "to_struct/2" do
    test "reads string keys into the matching fields" do
      entry =
        Utils.to_struct(SessionIndexEntry, %{
          "id" => "abc",
          "cwd" => "/tmp/project",
          "title" => "a session",
          "created_at" => 1.0,
          "updated_at" => 2.0
        })

      assert %SessionIndexEntry{id: "abc", cwd: "/tmp/project", title: "a session"} = entry
      assert entry.created_at == 1.0
    end

    test "leaves absent fields at their struct defaults" do
      message = Utils.to_struct(Messages.AssistantMessage, %{"model" => "some-model"})

      assert message.model == "some-model"
      assert message.content == []
      assert message.stop_reason == :stop
    end

    test "ignores keys the struct doesn't have" do
      entry = Utils.to_struct(SessionIndexEntry, %{"id" => "abc", "from_a_newer_eva" => true})

      assert entry.id == "abc"
      refute Map.has_key?(entry, :from_a_newer_eva)
    end

    # to_atom_keys/1 is evaluated before struct!/2 forces the module to load, so on a cold VM the
    # field atoms don't exist yet and reading an index blows up with ArgumentError. Purging the
    # module reproduces that state.
    test "works when the target module has not been loaded yet" do
      :code.purge(SessionIndexEntry)
      :code.delete(SessionIndexEntry)

      assert %SessionIndexEntry{id: "abc"} =
               Utils.to_struct(SessionIndexEntry, %{"id" => "abc", "created_at" => 1.0})
    end
  end
end
