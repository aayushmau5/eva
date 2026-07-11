defmodule Eva.Agent.Events do
  @moduledoc """
  Events emitted by Eva's agent layer.
  """

  alias Eva.Agent.{Messages, Tools}

  defmodule AgentStart do
    @moduledoc """
    The agent loop has started processing a task.
    """
    use TypedStruct

    typedstruct do
      field :type, String.t(), default: "agent_start"
    end
  end

  defmodule AgentEnd do
    @moduledoc """
    The agent loop has finished processing a task.
    """
    use TypedStruct

    typedstruct do
      field :type, String.t(), default: "agent_end"
    end
  end

  defmodule TurnStart do
    @moduledoc """
    A new agent turn is beginning.
    """
    use TypedStruct

    typedstruct do
      field :type, String.t(), default: "turn_start"
      field :turn, integer()
    end
  end

  defmodule TurnEnd do
    @moduledoc """
    The current agent turn has completed.
    """
    use TypedStruct

    typedstruct do
      field :type, String.t(), default: "turn_end"
      field :turn, integer()
    end
  end

  defmodule Retry do
    @moduledoc """
    The agent is retrying after a transient failure.
    """
    use TypedStruct

    typedstruct do
      field :type, String.t(), default: "retry"
      field :attempt, integer()
      field :max_attempts, integer()
      field :delay_seconds, float()
      field :message, String.t()
      field :data, map() | nil, default: nil
    end
  end

  defmodule QueueUpdate do
    @moduledoc """
    The steering or follow-up question queue has changed.
    """
    use TypedStruct

    typedstruct do
      field :type, String.t(), default: "queue_update"
      field :steering, [String.t()], default: []
      field :follow_up, [String.t()], default: []
    end
  end

  defmodule MessageStart do
    @moduledoc """
    The agent has started composing a message.
    """
    use TypedStruct

    typedstruct do
      field :type, String.t(), default: "message_start"
      field :message_role, String.t(), default: "assistant"
    end
  end

  defmodule MessageDelta do
    @moduledoc """
    A streamed content delta for the current message.
    """
    use TypedStruct

    typedstruct do
      field :type, String.t(), default: "message_delta"
      field :delta, String.t()
    end
  end

  defmodule ThinkingDelta do
    @moduledoc """
    A streamed thinking/reasoning delta for the current message.
    """
    use TypedStruct

    typedstruct do
      field :type, String.t(), default: "thinking_delta"
      field :delta, String.t()
    end
  end

  defmodule MessageEnd do
    @moduledoc """
    The agent has finished composing a message.
    """
    use TypedStruct

    typedstruct do
      field :type, String.t(), default: "message_end"

      field :message,
            Messages.UserMessage.t()
            | Messages.AssistantMessage.t()
            | Messages.ToolResultMessage.t()
    end
  end

  defmodule ToolExecutionStart do
    @moduledoc """
    A tool call has started executing.
    """
    use TypedStruct

    typedstruct do
      field :type, String.t(), default: "tool_execution_start"
      field :tool_call, Tools.ToolCall.t()
    end
  end

  defmodule ToolExecutionUpdate do
    @moduledoc """
    A progress update from a running tool execution.
    """
    use TypedStruct

    typedstruct do
      field :type, String.t(), default: "tool_execution_update"
      field :tool_call_id, String.t()
      field :message, String.t()
      field :data, map() | nil, default: nil
    end
  end

  defmodule ToolExecutionEnd do
    @moduledoc """
    A tool execution has completed.
    """
    use TypedStruct

    typedstruct do
      field :type, String.t(), default: "tool_execution_end"
      field :result, Messages.ToolResultMessage.t()
    end
  end

  defmodule Error do
    @moduledoc """
    An error occurred during agent processing.
    """
    use TypedStruct

    typedstruct do
      field :type, String.t(), default: "error"
      field :message, String.t()
      field :recoverable, boolean(), default: false
      field :data, map() | nil, default: nil
    end
  end

  @doc """
  All the event modules defined
  """
  def event_modules do
    [
      AgentStart,
      AgentEnd,
      TurnStart,
      TurnEnd,
      MessageStart,
      MessageDelta,
      ThinkingDelta,
      MessageEnd,
      ToolExecutionStart,
      ToolExecutionUpdate,
      ToolExecutionEnd,
      QueueUpdate,
      Retry,
      Error
    ]
  end

  @type agent_event ::
          AgentStart.t()
          | AgentEnd.t()
          | TurnStart.t()
          | TurnEnd.t()
          | QueueUpdate.t()
          | Retry.t()
          | MessageStart.t()
          | MessageDelta.t()
          | ThinkingDelta.t()
          | MessageEnd.t()
          | ToolExecutionStart.t()
          | ToolExecutionUpdate.t()
          | ToolExecutionEnd.t()
          | Error.t()
end
