defmodule Eva.AI.Events do
  @moduledoc """
  Event structs emitted by AI providers.
  """
  use TypedStruct

  alias Eva.Agent.Messages

  @type t ::
          AgentStart.t()
          | TextStart.t()
          | TextDelta.t()
          | TextEnd.t()
          | ThinkingStart.t()
          | ThinkingDelta.t()
          | ThinkingEnd.t()
          | ToolCallStart.t()
          | ToolCallDelta.t()
          | ToolCallEnd.t()
          | AssistantDone.t()
          | AssistantError.t()

  @type done_reason :: :stop | :length | :tool_use
  @type error_reason :: :aborted | :error

  typedstruct module: AgentStart do
    field :type, String.t(), default: "start"
    field :partial, Messages.AssistantMessage.t()
  end

  typedstruct module: TextStart do
    field :type, String.t(), default: "text_start"
    field :content_index, integer()
    field :partial, Messages.AssistantMessage.t()
  end

  typedstruct module: TextDelta do
    field :type, String.t(), default: "text_delta"
    field :content_index, integer()
    field :delta, String.t()
    field :partial, Messages.AssistantMessage.t()
  end

  typedstruct module: TextEnd do
    field :type, String.t(), default: "text_end"
    field :content_index, integer()
    field :content, String.t()
    field :partial, Messages.AssistantMessage.t()
  end

  typedstruct module: ThinkingStart do
    field :type, String.t(), default: "thinking_start"
    field :content_index, integer()
    field :partial, Messages.AssistantMessage.t()
  end

  typedstruct module: ThinkingDelta do
    field :type, String.t(), default: "thinking_delta"
    field :content_index, integer()
    field :delta, String.t()
    field :partial, Messages.AssistantMessage.t()
  end

  typedstruct module: ThinkingEnd do
    field :type, String.t(), default: "thinking_end"
    field :content_index, integer()
    field :content, String.t()
    field :partial, Messages.AssistantMessage.t()
  end

  typedstruct module: ToolCallStart do
    field :type, String.t(), default: "tool_call_start"
    field :content_index, integer()
    field :partial, Messages.AssistantMessage.t()
  end

  typedstruct module: ToolCallDelta do
    field :type, String.t(), default: "tool_call_delta"
    field :content_index, integer()
    field :delta, String.t()
    field :partial, Messages.AssistantMessage.t()
  end

  typedstruct module: ToolCallEnd do
    field :type, String.t(), default: "tool_call_end"
    field :content_index, integer()
    field :tool_call, Messages.ToolCall.t()
    field :partial, Messages.AssistantMessage.t()
  end

  typedstruct module: AssistantDone do
    field :type, String.t(), default: "done"
    field :reason, Eva.AI.Events.done_reason()
    field :message, Messages.AssistantMessage
  end

  typedstruct module: AssistantError do
    field :type, String.t(), default: "error"
    field :reason, Eva.AI.Events.error_reason()
    field :error, Messages.AssistantMessage
  end
end
