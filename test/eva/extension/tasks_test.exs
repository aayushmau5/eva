Code.require_file(Path.expand("../../../.eva/extensions/tasks/extension.exs", __DIR__))

defmodule Eva.Extension.TasksTest do
  use ExUnit.Case, async: false

  alias Eva.Core.Agent.Events.ExtensionEvent
  alias Eva.Core.Agent.Tools
  alias Eva.Core.Extension.API
  alias Eva.Test.ExtensionHarness, as: Harness

  @tasks [
    %{
      "content" => "Inspect authentication flow",
      "status" => "completed",
      "priority" => "high"
    },
    %{
      "content" => "Fix refresh-token handling",
      "status" => "in_progress",
      "priority" => "high"
    },
    %{
      "content" => "Run authentication tests",
      "status" => "pending",
      "priority" => "medium"
    }
  ]

  test "registers the OpenCode-style tool, guidelines, and command" do
    harness = Harness.start(Eva.Extension.Tasks, name: "tasks")

    assert [%Tools.AgentTool{name: "task_write", execution_mode: :sequential} = tool] =
             harness.spec.tools

    assert tool.input_schema.required == ["tasks"]
    assert Enum.any?(harness.spec.guidelines, &String.contains?(&1, "complete updated task list"))
    assert [%{name: "tasks"}] = harness.spec.commands
  end

  test "replaces the list, persists a snapshot, and publishes an update" do
    harness = Harness.start(Eva.Extension.Tasks, name: "tasks")
    Eva.Core.Bus.subscribe_pid(self(), harness.session, [:extension])

    result = write_tasks(harness, @tasks)

    assert %Tools.AgentToolResult{details: %{"tasks" => @tasks}} = result
    assert text(result) =~ "Tasks updated: 3 total, 2 remaining"
    assert text(result) =~ "[>] HIGH   Fix refresh-token handling"

    assert [
             %{
               "type" => "tasks_snapshot",
               "version" => 1,
               "tasks" => @tasks
             }
           ] = Harness.entries(harness)

    assert_receive %ExtensionEvent{
      extension: "tasks",
      payload: %{
        "type" => "tasks.updated",
        "tasks" => @tasks,
        "remaining" => 2
      }
    }

    assert {:ok, @tasks} = API.call(harness.context, "tasks", :get_tasks)
  end

  test "a later call replaces rather than appends to the list" do
    harness = Harness.start(Eva.Extension.Tasks, name: "tasks")
    _result = write_tasks(harness, @tasks)

    replacement = [
      %{"content" => "Ship the fix", "status" => "in_progress", "priority" => "high"}
    ]

    result = write_tasks(harness, replacement)

    assert result.details == %{"tasks" => replacement}
    assert {:ok, ^replacement} = API.call(harness.context, "tasks", :get_tasks)
    assert length(Harness.entries(harness)) == 2
  end

  test "rejects multiple in-progress tasks without changing state" do
    harness = Harness.start(Eva.Extension.Tasks, name: "tasks")
    _result = write_tasks(harness, @tasks)

    invalid = [
      %{"content" => "First", "status" => "in_progress", "priority" => "high"},
      %{"content" => "Second", "status" => "in_progress", "priority" => "low"}
    ]

    assert_raise RuntimeError, "at most one task may be in_progress", fn ->
      write_tasks(harness, invalid)
    end

    assert {:ok, @tasks} = API.call(harness.context, "tasks", :get_tasks)
    assert length(Harness.entries(harness)) == 1
  end

  test "restores the newest valid snapshot and ignores malformed entries" do
    earlier = [
      %{"content" => "Earlier", "status" => "pending", "priority" => "low"}
    ]

    latest = [
      %{"content" => "Latest", "status" => "completed", "priority" => "high"}
    ]

    entries = [
      snapshot(earlier),
      %{"type" => "unrelated"},
      %{"type" => "tasks_snapshot", "version" => 99, "tasks" => []},
      snapshot(latest),
      snapshot([%{"content" => "broken"}])
    ]

    harness = Harness.start(Eva.Extension.Tasks, name: "tasks", entries: entries)

    assert {:ok, ^latest} = API.call(harness.context, "tasks", :get_tasks)
    assert {:text, output} = Harness.command(harness, "tasks")
    assert output =~ "Tasks — 1/1 completed"
    assert output =~ "[x] HIGH   Latest"
  end

  test "keeps task state isolated between sessions" do
    first = Harness.start(Eva.Extension.Tasks, name: "tasks")
    second = Harness.start(Eva.Extension.Tasks, name: "tasks")

    _result = write_tasks(first, @tasks)

    assert {:ok, @tasks} = API.call(first.context, "tasks", :get_tasks)
    assert {:ok, []} = API.call(second.context, "tasks", :get_tasks)
  end

  test "/tasks is read-only and rejects arguments" do
    harness = Harness.start(Eva.Extension.Tasks, name: "tasks")

    assert {:text, "No tasks in this session."} = Harness.command(harness, "tasks")
    assert {:error, "usage: /tasks"} = Harness.command(harness, "tasks", "clear")
  end

  defp write_tasks(harness, tasks) do
    [tool] = harness.spec.tools

    tool.executor.(
      %{"tasks" => tasks},
      %Tools.ExecContext{tool_call_id: "call", tool_name: tool.name, harness_pid: self()}
    )
  end

  defp snapshot(tasks) do
    %{"type" => "tasks_snapshot", "version" => 1, "tasks" => tasks}
  end

  defp text(%Tools.AgentToolResult{content: [%{text: text}]}), do: text
end
