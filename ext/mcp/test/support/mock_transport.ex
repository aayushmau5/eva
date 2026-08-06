defmodule Eva.Extension.MCP.MockTransport do
  use TypedStruct

  typedstruct do
    field :test_pid, pid()
    field :fail_send?, boolean(), default: false
  end
end

defimpl Eva.Extension.MCP.Transport, for: Eva.Extension.MCP.MockTransport do
  def send_message(%{fail_send?: true}, _message), do: {:error, :mock_failure}

  def send_message(transport, message) do
    send(transport.test_pid, {:mcp_sent, message})
    :ok
  end

  def handle_message(transport, {:frame, line}) do
    {:frames, [line], transport}
  end

  def handle_message(transport, {:frames, lines}) do
    {:frames, lines, transport}
  end

  def handle_message(transport, {:stderr, line}) do
    {:log, [line], transport}
  end

  def handle_message(_transport, {:closed, reason}) do
    {:closed, reason}
  end

  def handle_message(_transport, _message), do: :ignore

  def close(_transport), do: :ok
end
