defmodule Eva.Agent.Messages do
  @moduledoc """
  Message types. Common between Agent & AI module.
  """

  alias Eva.Agent.{Tools, Utils}

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

  defimpl JSON.Encoder, for: [UserMessage, AssistantMessage, ToolResultMessage] do
    def encode(struct, opts) do
      struct |> Map.from_struct() |> JSON.Encoder.encode(opts)
    end
  end

  def from_json_map(map) when is_map(map) do
    tc = (map["tool_calls"] || []) |> Enum.map(&Tools.ToolCall.from_json_map/1)
    fields = Utils.to_atom_keys(map) |> Map.put(:tool_calls, tc)
    struct!(AssistantMessage, fields)
  end
end
