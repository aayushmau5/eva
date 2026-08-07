defmodule Eva.Core.Agent.Tools do
  @moduledoc """
  Provider-neutral tool definitions and tool execution results.
  """

  alias Eva.Core.Agent.Messages
  alias Eva.Core.Agent.Events

  defmodule AgentToolResult do
    @moduledoc """
    Structured result returned by a tool execution.
    """
    use TypedStruct

    typedstruct do
      field :content, [Messages.TextContent.t() | Messages.ImageContent.t()], default: []
      field :details, map()
      field :added_tool_names, [String.t()]
      field :terminate, boolean()
    end
  end

  defmodule AgentTool do
    @moduledoc """
    A tool that can be exposed to an agent loop.

    ## Fields

      * `name` — unique tool name exposed to the model.
      * `description` — description the model uses to decide when to call this tool.
      * `input_schema` — JSON Schema for the tool's arguments.
      * `executor` — function `(arguments, context -> AgentToolResult)`. Called to
        execute the tool.
      * `prompt_snippet` — optional text injected into the system prompt to guide
        the model on when to use this tool.
      * `prompt_guidelines` — additional guideline strings for the system prompt.
      * `execution_mode` — whether the tool can be run in parallel or sequential
    """
    use TypedStruct

    typedstruct do
      field :name, String.t()
      field :description, String.t()
      field :input_schema, map()
      field :executor, function()
      field :prompt_snippet, String.t() | nil, default: nil
      field :prompt_guidelines, [String.t()], default: []
      field :execution_mode, :sequential | :parallel, default: :parallel
    end
  end

  defmodule ExecContext do
    @moduledoc """
    Extra context provided to tool executor for progress tracking.
    """
    use TypedStruct

    typedstruct do
      field :tool_call_id, String.t()
      field :tool_name, String.t()
      field :harness_pid, pid()
    end
  end

  @type tool_call :: ToolCall.t()
  @type tool_result :: AgentToolResult.t()
  @type tool :: AgentTool.t()

  @doc """
  Executes a tool with provider-neutral arguments.

  Delegates to the tool's `executor` function.
  """
  @spec execute(AgentTool.t(), map(), ExecContext.t()) :: AgentToolResult.t()
  def execute(%AgentTool{executor: executor}, arguments, context) do
    executor.(arguments, context)
  end

  # This bypasses the loop process.
  # It is deliberate because this changes nothing on the transcript.
  @doc """
  Sends a `ToolExecutionUpdate` message to the harness directly.
  """
  @spec report_update(ExecContext.t(), AgentToolResult.t()) :: Events.ToolExecutionUpdate.t()
  def report_update(ctx, result) do
    %Events.ToolExecutionUpdate{
      tool_call_id: ctx.tool_call_id,
      tool_name: ctx.tool_name,
      partial_result: result
    }
    |> then(&send(ctx.harness_pid, &1))
  end
end
