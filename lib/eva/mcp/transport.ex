defprotocol Eva.MCP.Transport do
  def send_message(transport, message)
  def handle_message(transport, message)
  def close(transport)
end

# Factory
defmodule Eva.MCP.Transports do
  alias Eva.MCP.Config
  alias Eva.MCP.Transport.Stdio

  @spec connect(Config.t()) :: {:ok, Stdio.t()} | {:error, term()}
  def connect(%Config{type: :stdio} = config) do
    Stdio.connect(config)
  end
end
