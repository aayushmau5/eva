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
    # The provider's own event, passed through untouched. Opaque here on purpose: which
    # provider produced it is the host's business, and naming its type would point this
    # library back at the host it has to stay independent of.
    field :assistant_message_event, term()
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

  # Anything an extension publishes, tagged with which one published it.
  #
  # Core does not need to know what any given extension emits — a listener matches on
  # `extension` and reads `payload`.
  typedstruct module: ExtensionEvent do
    field :extension, String.t()
    field :payload, term()
  end

  # The session's set of extensions is no longer what a listener last saw: one joined from
  # another node or went away, one was switched on or off, or they were reloaded.
  #
  # Deliberately empty. A listener answers it by re-reading `list_extensions/1`.
  typedstruct module: ExtensionsChanged do
    field :type, String.t(), default: "extensions_changed"
  end

  @doc """
  Every event module in this file.
  """
  @spec modules() :: [module()]
  def modules() do
    [
      AgentStart,
      AgentEnd,
      TurnStart,
      TurnEnd,
      MessageStart,
      MessageUpdate,
      MessageEnd,
      ToolExecutionStart,
      ToolExecutionUpdate,
      ToolExecutionEnd,
      ExtensionEvent,
      ExtensionsChanged
    ]
  end
end
