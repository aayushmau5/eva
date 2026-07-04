defmodule Eva.AI.Events do
  @moduledoc """
  Event structs emitted by AI providers.
  """

  defmodule ProviderResponseStart do
    @moduledoc """
    The provider has started a model response.
    """
    use TypedStruct

    typedstruct do
      field :type, String.t(), default: "response_start"
      field :model, String.t()
    end
  end

  defmodule ProviderRetry do
    @moduledoc """
    The provider adapter is retrying a transient request failure.
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

  defmodule ProviderTextDelta do
    use TypedStruct

    typedstruct do
      field :type, String.t(), default: "text_delta"
      field :delta, String.t()
    end
  end

  defmodule ProviderThinkingDelta do
    @moduledoc """
    A streamed thinking/reasoning fragment from the provider.
    """
    use TypedStruct

    typedstruct do
      field :type, String.t(), default: "thinking_delta"
      field :delta, String.t()
    end
  end

  defmodule ProviderToolCall do
    @moduledoc """
    A complete tool call requested by the model.
    """
    use TypedStruct
    alias Eva.Agent.Tools

    typedstruct do
      field :type, String.t(), default: "tool_call"
      field :tool_call, Tools.ToolCall.t()
    end
  end

  defmodule ProviderResponseEnd do
    @moduledoc """
    The provider has completed a model response.
    """
    use TypedStruct
    alias Eva.Agent.Messages

    typedstruct do
      field :type, String.t(), default: "response_end"
      field :message, Messages.AssistantMessage.t()
      field :finish_reason, String.t() | nil, default: nil
    end
  end

  defmodule ProviderError do
    @moduledoc """
    A provider-level error that can be surfaced by the agent layer.
    """
    use TypedStruct

    typedstruct do
      field :type, String.t(), default: "error"
      field :message, String.t()
      field :data, map() | nil, default: nil
    end
  end

  @type provider_event ::
          ProviderResponseStart.t()
          | ProviderRetry.t()
          | ProviderTextDelta.t()
          | ProviderThinkingDelta.t()
          | ProviderToolCall.t()
          | ProviderResponseEnd.t()
          | ProviderError.t()
end
