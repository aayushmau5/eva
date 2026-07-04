defmodule Eva.Agent.Messages do
  @moduledoc """
  Message types. Common between Agent & AI module.
  """

  defmodule UserMessage do
    @moduledoc """
    A message authored by the user.
    """
    use TypedStruct

    typedstruct do
      field :role, String.t(), default: "user"
      field :content, String.t()
    end
  end

  defmodule AssistantMessage do
    @moduledoc """
    A message authored by the assistant, optionally requesting tool calls.
    """
    use TypedStruct
    alias Eva.Agent.Tools

    typedstruct do
      field :role, String.t(), default: "assistant"
      field :content, String.t()
      field :tool_calls, [Tools.ToolCall.t()]
    end
  end

  defmodule ToolResultMessage do
    @moduledoc """
    A transcript message containing the result of a previous tool call.
    """
    use TypedStruct

    typedstruct do
      field :role, String.t(), default: "tool"
      field :tool_call_id, String.t()
      field :name, String.t()
      field :content, String.t()
      field :ok, boolean(), default: true
      field :data, map(), default: nil
      field :details, map(), default: nil
      field :error, String.t(), default: nil
    end
  end
end
