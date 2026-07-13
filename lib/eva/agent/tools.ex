defmodule Eva.Agent.Tools do
  @moduledoc """
  Provider-neutral tool definitions and tool execution results.
  """

  defmodule ToolCall do
    @moduledoc """
    A request from the assistant to execute a named tool.
    """
    use TypedStruct
    alias Eva.Agent.Utils

    typedstruct do
      field :id, String.t()
      field :name, String.t()
      field :arguments, map() | String.t()
    end

    def from_json_map(map) when is_map(map) do
      struct!(__MODULE__, Utils.to_atom_keys(map))
    end
  end

  defmodule AgentToolResult do
    @moduledoc """
    Structured result returned by a tool execution.
    """
    use TypedStruct

    typedstruct do
      field :tool_call_id, String.t()
      field :name, String.t()
      field :ok, boolean(), default: true
      field :content, String.t(), default: ""
      field :data, map() | nil, default: nil
      field :details, map() | nil, default: nil
      field :error, String.t() | nil, default: nil
    end
  end

  defmodule AgentTool do
    @moduledoc """
    A tool that can be exposed to an agent loop.

    ## Fields

      * `name` — unique tool name exposed to the model.
      * `description` — description the model uses to decide when to call this tool.
      * `input_schema` — JSON Schema for the tool's arguments.
      * `executor` — function `(arguments -> AgentToolResult)`. Called to
        execute the tool.
      * `prompt_snippet` — optional text injected into the system prompt to guide
        the model on when to use this tool.
      * `prompt_guidelines` — additional guideline strings for the system prompt.
    """
    use TypedStruct

    typedstruct do
      field :name, String.t()
      field :description, String.t()
      field :input_schema, map()
      field :executor, function()
      field :prompt_snippet, String.t() | nil, default: nil
      field :prompt_guidelines, [String.t()], default: []
    end
  end

  @type tool_call :: ToolCall.t()
  @type tool_result :: AgentToolResult.t()
  @type tool :: AgentTool.t()

  @doc """
  Executes a tool with provider-neutral arguments.

  Delegates to the tool's `executor` function.
  """
  @spec execute(AgentTool.t(), map()) :: AgentToolResult.t()
  def execute(%AgentTool{executor: executor}, arguments) do
    executor.(arguments)
  end

  defimpl JSON.Encoder, for: ToolCall do
    def encode(struct, opts) do
      struct |> Map.from_struct() |> JSON.Encoder.encode(opts)
    end
  end
end
