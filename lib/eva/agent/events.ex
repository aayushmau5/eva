defmodule Eva.Agent.Events do
  @moduledoc """
  Events emitted by Eva's agent layer(i.e. the loop).
  """
  use TypedStruct

  alias Eva.Agent.{Messages, Tools}

  @type t ::
          AgentStart.t()
          | AgentEnd.t()
          | TurnStart.t()
          | TurnEnd.t()
          | MessageStart.t()
          | MessageUpdate.t()
          | MessageEnd.t()
          | ToolExecutionStart.t()
          | ToolExecutionUpdate.t()
          | ToolExecutionEnd.t()

  typedstruct module: AgentStart do
    field :type, String.t(), default: "agent_start"
  end

  typedstruct module: AgentEnd do
    field :type, String.t(), default: "agent_end"
    field :messages, [Messages.agent_message()], default: []
  end

  typedstruct module: TurnStart do
    field :type, String.t(), default: "turn_start"
  end

  typedstruct module: TurnEnd do
    field :type, String.t(), default: "turn_end"
    field :message, Messages.agent_message()
    field :tool_results, [Messages.ToolResultMessage.t()], default: []
  end

  typedstruct module: MessageStart do
    field :type, String.t(), default: "message_start"
    field :message, Messages.agent_message()
  end

  typedstruct module: MessageUpdate do
    field :type, String.t(), default: "message_update"
    field :message, Messages.agent_message()
    field :assistant_message_event, Eva.AI.Events.provider_event()
  end

  typedstruct module: MessageEnd do
    field :type, String.t(), default: "message_end"
    field :message, Messages.agent_message()
  end

  typedstruct module: ToolExecutionStart do
    field :type, String.t(), default: "tool_execution_start"
    field :tool_call_id, String.t()
    field :tool_name, String.t()
    field :args, map(), default: %{}
  end

  typedstruct module: ToolExecutionUpdate do
    field :type, String.t(), default: "tool_execution_update"
    field :tool_call_id, String.t()
    field :tool_name, String.t()
    field :args, map(), default: %{}
    field :partial_result, Tools.AgentToolResult.t()
  end

  typedstruct module: ToolExecutionEnd do
    field :type, String.t(), default: "tool_execution_end"
    field :tool_call_id, String.t()
    field :tool_name, String.t()
    field :result, Tools.AgentToolResult.t()
    field :is_error, boolean()
  end
end
