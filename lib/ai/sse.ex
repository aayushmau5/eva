defmodule Eva.AI.Sse do
  @moduledoc """
  SSE parser
  """

  def parse("data: [DONE]") do
    :done
  end

  def parse("data: " <> line) do
    {:line, JSON.decode!(line)}
  end

  def parse_delta(%{"choices" => [choice | _]} = _chunk) do
    delta = choice["delta"] || %{}

    %{
      content: delta["content"],
      # TODO: understand where does the response differ?
      thinking: delta["reasoning_content"] || delta["reasoning"] || delta["thinking"],
      tool_calls: delta["tool_calls"] || [],
      finish_reason: choice["finish_reason"]
    }
  end

  def parse_delta(_chunk) do
    %{content: nil, thinking: nil, tool_calls: [], finish_reason: nil}
  end
end
