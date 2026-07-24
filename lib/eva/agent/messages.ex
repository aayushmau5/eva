defmodule Eva.Agent.Messages do
  @moduledoc """
  Message types. Common between Agent & AI module.
  """

  alias Eva.Agent.Utils

  @type user_content :: String.t() | [TextContent.t() | ImageContent.t()]
  @type assistant_content :: TextContent.t() | ThinkingContent.t() | ToolCall.t()
  @type tool_result_content :: TextContent.t() | ImageContent.t()
  @type agent_message ::
          UserMessage.t()
          | AssistantMessage.t()
          | ToolResultMessage.t()
          | BashExecutionMessage.t()
          | CustomMessage.t()
          | BranchSummaryMessage.t()
          | CompactionSummaryMessage.t()

  defmodule UsageCost do
    @moduledoc """
    Billed response cost in USD
    """
    use TypedStruct

    typedstruct do
      field :input, float(), default: 0.0
      field :output, float(), default: 0.0
      field :cache_read, float(), default: 0.0
      field :cache_write, float(), default: 0.0
      field :total, float(), default: 0.0
    end
  end

  defmodule Usage do
    @moduledoc """
    Provider-reported token usage for one assistant response
    """
    use TypedStruct

    typedstruct do
      field :input, integer(), default: 0
      field :output, integer(), default: 0
      field :cache_read, integer(), default: 0
      field :cache_write, integer(), default: 0
      field :cache_write_1h, integer(), default: 0
      field :reasoning, integer(), default: 0
      field :total_tokens, integer(), default: 0
      field :cost, UsageCost.t(), default: %UsageCost{}
    end
  end

  defmodule TextContent do
    use TypedStruct

    typedstruct do
      field :type, String.t(), default: "text"
      field :text, String.t(), enforce: true
      field :text_signature, String.t(), default: nil
    end
  end

  defmodule ThinkingContent do
    use TypedStruct

    typedstruct do
      field :type, String.t(), default: "thinking"
      field :thinking, String.t(), enforce: true
      field :thinking_signature, String.t(), default: nil
      field :redacted, boolean(), default: false
    end
  end

  defmodule ImageContent do
    use TypedStruct

    typedstruct do
      field :type, String.t(), default: "image"
      field :data, String.t(), enforce: true
      field :mime_type, String.t(), enforce: true
    end
  end

  defmodule ToolCall do
    use TypedStruct

    typedstruct do
      field :type, String.t(), default: "tool_call"
      field :id, String.t(), enforce: true
      field :name, String.t(), enforce: true
      field :arguments, map(), default: %{}
      field :thought_signature, String.t()
    end
  end

  defmodule UserMessage do
    @moduledoc """
    A message authored by the user.
    """
    use TypedStruct
    alias Eva.Agent.Utils

    typedstruct do
      field :role, String.t(), default: "user"
      field :content, Eva.Agent.Messages.user_content()
      field :timestamp, integer(), default: Utils.current_timestamp_ms()
    end

    def text(%__MODULE__{content: content}) do
      Eva.Agent.Messages.content_text(content)
    end
  end

  defmodule AssistantDiagnosticError do
    use TypedStruct

    typedstruct do
      field :name, String.t()
      field :message, String.t()
      field :stack, String.t()
      field :code, String.t() | integer()
    end
  end

  defmodule AssistantMessageDiagnostic do
    use TypedStruct

    typedstruct do
      field :type, String.t()
      field :timestamp, integer(), default: Utils.current_timestamp_ms()
      field :error, Eva.Agent.Messages.AssistantDiagnosticError.t()
      field :details, map()
    end
  end

  defmodule AssistantMessage do
    @moduledoc """
    A message authored by the assistant with ordered content block.
    """
    use TypedStruct
    alias Eva.Agent.Messages

    @type stop_reason :: :stop | :length | :tool_use | :error | :aborted

    typedstruct do
      field :role, String.t(), default: "assistant"
      field :content, [Messages.assistant_content()], default: []
      field :api, String.t(), default: "unknown"
      field :provider, String.t(), default: "unknown"
      field :model, String.t(), default: "unknown"
      field :response_model, String.t()
      field :response_id, String.t()
      field :diagnostics, [Messages.AssistantMessageDiagnostic.t()]
      field :usage, Messages.Usage.t(), default: %Messages.Usage{}
      field :stop_reason, stop_reason(), default: :stop
      field :error_message, String.t()
      field :timestamp, integer(), default: Utils.current_timestamp_ms()
    end

    @spec text(t()) :: String.t()
    def text(%__MODULE__{content: content}) do
      Enum.reduce(content, [], fn
        %Messages.TextContent{text: text}, acc -> [text | acc]
        _, acc -> acc
      end)
      |> Enum.reverse()
      |> IO.iodata_to_binary()
    end

    @spec thinking_text(t()) :: String.t()
    def thinking_text(%__MODULE__{content: content}) do
      Enum.reduce(content, [], fn
        %Messages.ThinkingContent{thinking: thinking}, acc -> [thinking | acc]
        _, acc -> acc
      end)
      |> Enum.reverse()
      |> IO.iodata_to_binary()
    end

    @spec tool_calls(t()) :: [Messages.ToolCall.t()]
    def tool_calls(%__MODULE__{content: content}) do
      Enum.reduce(content, [], fn
        %Messages.ToolCall{} = tc, acc -> [tc | acc]
        _, acc -> acc
      end)
      |> Enum.reverse()
    end
  end

  defmodule ToolResultMessage do
    @moduledoc """
    A transcript message containing the result of a previous tool call.
    """
    use TypedStruct

    typedstruct do
      field :role, String.t(), default: "tool_result"
      field :tool_call_id, String.t()
      field :tool_name, String.t()
      field :content, [Eva.Agent.Messages.tool_result_content()], default: []
      field :details, map(), default: nil
      field :added_tool_names, [String.t()], default: nil
      field :is_error, boolean(), default: false
      field :timestamp, integer(), default: Eva.Agent.Utils.current_timestamp_ms()
    end

    @spec text(t()) :: String.t()
    def text(%__MODULE__{content: content}) do
      Eva.Agent.Messages.content_text(content)
    end
  end

  defmodule BashExecutionMessage do
    use TypedStruct

    typedstruct do
      field :role, String.t(), default: "bash_execution"
      field :command, String.t()
      field :output, String.t()
      field :exit_code, integer()
      field :cancelled, boolean(), default: false
      field :truncated, boolean(), default: false
      field :full_output_path, String.t()
      field :timestamp, integer(), default: Utils.current_timestamp_ms()
      field :exclude_from_context, boolean(), default: false
    end
  end

  defmodule CustomMessage do
    use TypedStruct

    typedstruct do
      field :role, String.t(), default: "custom"
      field :custom_type, String.t()
      field :content, Eva.Agent.Messages.user_content()
      field :display, boolean(), default: true
      field :details, map()
      field :timestamp, integer(), default: Utils.current_timestamp_ms()
    end

    @spec text(t()) :: String.t()
    def text(%__MODULE__{content: content}) do
      Eva.Agent.Messages.content_text(content)
    end
  end

  defmodule BranchSummaryMessage do
    use TypedStruct

    typedstruct do
      field :role, String.t(), default: "branch_summary"
      field :summary, String.t()
      field :from_id, String.t()
      field :timestamp, integer(), default: Utils.current_timestamp_ms()
    end
  end

  defmodule CompactionSummaryMessage do
    use TypedStruct

    typedstruct do
      field :role, String.t(), default: "compaction_summary"
      field :summary, String.t()
      field :tokens_before, integer()
      field :timestamp, integer(), default: Utils.current_timestamp_ms()
    end
  end

  defimpl JSON.Encoder,
    for: [
      UserMessage,
      AssistantMessage,
      ToolResultMessage,
      BashExecutionMessage,
      CustomMessage,
      BranchSummaryMessage,
      CompactionSummaryMessage,
      Usage,
      UsageCost,
      AssistantDiagnosticError,
      AssistantMessageDiagnostic,
      ThinkingContent,
      TextContent,
      ImageContent
    ] do
    def encode(struct, opts) do
      struct |> Map.from_struct() |> JSON.Encoder.encode(opts)
    end
  end

  @doc "Return visible text from string or text/image content."
  @spec content_text(String.t() | [assistant_content()]) :: String.t()
  def content_text(content) when is_binary(content), do: content

  def content_text(content) when is_list(content) do
    Enum.reduce(content, [], fn
      %TextContent{text: text}, acc -> [text | acc]
      _, acc -> acc
    end)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  def from_json_map(%{"role" => role} = json_map) do
    case role do
      "user" ->
        fields = Map.put(json_map, "content", convert_user_content(json_map["content"]))
        struct!(UserMessage, Utils.to_atom_keys(fields))

      "assistant" ->
        fields =
          json_map
          |> Map.update(
            "content",
            [],
            &Enum.map(&1, fn block -> convert_content_block(block) end)
          )
          |> Map.update("usage", nil, &convert_usage/1)
          |> Map.update("diagnostics", nil, fn diags ->
            Enum.map(diags, &convert_diagnostic/1)
          end)

        struct!(AssistantMessage, Utils.to_atom_keys(fields))

      "tool_result" ->
        fields =
          Map.update(
            json_map,
            "content",
            [],
            &Enum.map(&1, fn block -> convert_content_block(block) end)
          )

        struct!(ToolResultMessage, Utils.to_atom_keys(fields))

      "bash_execution" ->
        struct!(BashExecutionMessage, Utils.to_atom_keys(json_map))

      "custom" ->
        fields = Map.update(json_map, "content", nil, &convert_user_content/1)
        struct!(CustomMessage, Utils.to_atom_keys(fields))

      "branch_summary" ->
        struct!(BranchSummaryMessage, Utils.to_atom_keys(json_map))

      "compaction_summary" ->
        struct!(CompactionSummaryMessage, Utils.to_atom_keys(json_map))
    end
  end

  defp convert_user_content(content) when is_binary(content), do: content

  defp convert_user_content(nil), do: nil

  defp convert_user_content(content) when is_map(content) do
    convert_content_block(content)
  end

  defp convert_user_content(content) when is_list(content) do
    Enum.map(content, fn block -> convert_content_block(block) end)
  end

  defp convert_content_block(%{"type" => "text"} = block) do
    struct!(TextContent, Utils.to_atom_keys(block))
  end

  defp convert_content_block(%{"type" => "thinking"} = block) do
    struct!(ThinkingContent, Utils.to_atom_keys(block))
  end

  defp convert_content_block(%{"type" => "tool_call"} = block) do
    struct!(ToolCall, Utils.to_atom_keys(block))
  end

  defp convert_content_block(%{"type" => "image"} = block) do
    struct!(ImageContent, Utils.to_atom_keys(block))
  end

  defp convert_usage(nil), do: nil

  defp convert_usage(%{"cost" => cost} = usage) do
    usage
    |> Map.put("cost", struct!(UsageCost, Utils.to_atom_keys(cost)))
    |> then(&struct!(Usage, Utils.to_atom_keys(&1)))
  end

  defp convert_usage(usage) do
    struct!(Usage, Utils.to_atom_keys(usage))
  end

  defp convert_diagnostic(%{"error" => error} = diag) do
    diag
    |> Map.put("error", struct!(AssistantDiagnosticError, Utils.to_atom_keys(error)))
    |> then(&struct!(AssistantMessageDiagnostic, Utils.to_atom_keys(&1)))
  end

  defp convert_diagnostic(diag) do
    struct!(AssistantMessageDiagnostic, Utils.to_atom_keys(diag))
  end
end
