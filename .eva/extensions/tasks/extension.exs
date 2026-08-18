defmodule Eva.Extension.Tasks do
  use Eva.Core.Extension

  @snapshot_type "tasks_snapshot"
  @snapshot_version 1
  @max_tasks 50
  @max_content_length 500
  @statuses ~w(pending in_progress completed cancelled)
  @priorities ~w(high medium low)

  @guidelines [
    "Use `task_write` when work contains three or more meaningful steps.",
    "Do not create a task list for one straightforward action or a purely informational response.",
    "Submit the complete updated task list on every `task_write` call.",
    "Keep at most one task `in_progress`.",
    "Before starting a pending task, mark it `in_progress`.",
    "Update completed tasks promptly instead of waiting until the end.",
    "Mark a task `completed` only after its work and required verification are finished.",
    "If a task is no longer required, mark it `cancelled` instead of `completed`.",
    "When new work is discovered, add it to the task list.",
    "Preserve exact commands supplied by the user inside task descriptions."
  ]

  @impl true
  def setup(ctx) do
    {:ok,
     %Spec{
       tools: [task_write_tool(ctx)],
       guidelines: @guidelines,
       commands: [
         %Spec.Command{
           name: "tasks",
           description: "Show the current session task list",
           arg_hint: ""
         }
       ]
     }}
  end

  @impl true
  def init(ctx) do
    {:ok, %{ctx: ctx, tasks: restore_tasks(ctx.entries)}}
  end

  @impl true
  def handle_request({:write_tasks, tasks}, state) do
    case validate_tasks(tasks) do
      {:ok, tasks} ->
        persist(state.ctx, tasks)
        publish_update(state.ctx, tasks)

        result = %Tools.AgentToolResult{
          content: [%Messages.TextContent{text: format_tool_result(tasks)}],
          details: %{"tasks" => tasks}
        }

        {{:ok, result}, %{state | tasks: tasks}}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  def handle_request(:get_tasks, state), do: {{:ok, state.tasks}, state}

  @impl true
  def handle_command("tasks", args, state) do
    if String.trim(args) == "" do
      {{:text, format_command(state.tasks)}, state}
    else
      {{:error, "usage: /tasks"}, state}
    end
  end

  defp task_write_tool(ctx) do
    %Tools.AgentTool{
      name: "task_write",
      description: """
      Replace the current session's complete task list. Use this to plan and track
      multi-step work. Every call must contain the full desired list, including tasks
      that are completed or cancelled.
      """,
      prompt_snippet: "Create and maintain a session task list for multi-step work",
      input_schema: %{
        type: "object",
        properties: %{
          tasks: %{
            type: "array",
            maxItems: @max_tasks,
            description: "The complete updated task list",
            items: %{
              type: "object",
              properties: %{
                content: %{
                  type: "string",
                  minLength: 1,
                  maxLength: @max_content_length,
                  description: "A short, actionable description of the work"
                },
                status: %{
                  type: "string",
                  enum: @statuses,
                  description: "Current state of the task"
                },
                priority: %{
                  type: "string",
                  enum: @priorities,
                  description: "Priority of the task"
                }
              },
              required: ["content", "status", "priority"],
              additionalProperties: false
            }
          }
        },
        required: ["tasks"],
        additionalProperties: false
      },
      execution_mode: :sequential,
      executor: fn arguments, _exec_ctx ->
        tasks = Map.get(arguments, "tasks")

        case API.call(ctx, ctx.name, {:write_tasks, tasks}) do
          {:ok, %Tools.AgentToolResult{} = result} -> result
          {:error, reason} -> raise reason
        end
      end
    }
  end

  defp validate_tasks(tasks) when not is_list(tasks),
    do: {:error, "tasks must be an array"}

  defp validate_tasks(tasks) when length(tasks) > @max_tasks,
    do: {:error, "tasks may contain at most #{@max_tasks} items"}

  defp validate_tasks(tasks) do
    with {:ok, tasks} <- validate_each(tasks),
         :ok <- validate_in_progress(tasks) do
      {:ok, tasks}
    end
  end

  defp validate_each(tasks) do
    tasks
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {task, position}, {:ok, valid} ->
      case validate_task(task, position) do
        {:ok, task} -> {:cont, {:ok, [task | valid]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, valid} -> {:ok, Enum.reverse(valid)}
      error -> error
    end
  end

  defp validate_task(task, position) when not is_map(task),
    do: {:error, "task #{position} must be an object"}

  defp validate_task(task, position) do
    content = Map.get(task, "content")
    status = Map.get(task, "status")
    priority = Map.get(task, "priority")

    cond do
      not is_binary(content) or String.trim(content) == "" ->
        {:error, "task #{position} content must not be empty"}

      String.length(content) > @max_content_length ->
        {:error, "task #{position} content may contain at most #{@max_content_length} characters"}

      status not in @statuses ->
        {:error, "task #{position} status must be one of: #{Enum.join(@statuses, ", ")}"}

      priority not in @priorities ->
        {:error, "task #{position} priority must be one of: #{Enum.join(@priorities, ", ")}"}

      true ->
        {:ok, %{"content" => content, "status" => status, "priority" => priority}}
    end
  end

  defp validate_in_progress(tasks) do
    if Enum.count(tasks, &(&1["status"] == "in_progress")) <= 1 do
      :ok
    else
      {:error, "at most one task may be in_progress"}
    end
  end

  defp restore_tasks(entries) do
    Enum.reduce(entries, [], fn
      %{"type" => @snapshot_type, "version" => @snapshot_version, "tasks" => tasks}, current ->
        case validate_tasks(tasks) do
          {:ok, tasks} -> tasks
          {:error, _reason} -> current
        end

      _entry, current ->
        current
    end)
  end

  defp persist(ctx, tasks) do
    API.append_entry(ctx, %{
      "type" => @snapshot_type,
      "version" => @snapshot_version,
      "tasks" => tasks
    })
  end

  defp publish_update(ctx, tasks) do
    API.publish_event(ctx, %{
      "type" => "tasks.updated",
      "tasks" => tasks,
      "remaining" => remaining_count(tasks)
    })
  end

  defp format_tool_result(tasks) do
    header =
      "Tasks updated: #{length(tasks)} total, #{remaining_count(tasks)} remaining"

    case format_rows(tasks) do
      [] -> header <> "\n\nNo tasks in this session."
      rows -> Enum.join([header, "" | rows], "\n")
    end
  end

  defp format_command([]), do: "No tasks in this session."

  defp format_command(tasks) do
    completed = Enum.count(tasks, &(&1["status"] == "completed"))
    header = "Tasks — #{completed}/#{length(tasks)} completed"

    Enum.join([header, "" | format_rows(tasks)], "\n")
  end

  defp format_rows(tasks) do
    Enum.map(tasks, fn task ->
      marker = status_marker(task["status"])
      priority = task["priority"] |> String.upcase() |> String.pad_trailing(6)
      "#{marker} #{priority} #{task["content"]}"
    end)
  end

  defp status_marker("pending"), do: "[ ]"
  defp status_marker("in_progress"), do: "[>]"
  defp status_marker("completed"), do: "[x]"
  defp status_marker("cancelled"), do: "[-]"

  defp remaining_count(tasks) do
    Enum.count(tasks, &(&1["status"] in ["pending", "in_progress"]))
  end
end
