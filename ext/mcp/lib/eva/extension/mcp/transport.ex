defprotocol Eva.Extension.MCP.Transport do
  def send_message(transport, message)
  def handle_message(transport, message)
  def close(transport)
end

# Factory
defmodule Eva.Extension.MCP.Transports do
  alias Eva.Extension.MCP.Config
  alias Eva.Extension.MCP.Transport.{Http, Stdio}

  @spec connect(Config.t()) :: {:ok, Stdio.t() | Http.t()} | {:error, term()}
  def connect(%Config{type: :stdio} = config) do
    Stdio.connect(config)
  end

  def connect(%Config{type: :http} = config) do
    Http.connect(config)
  end
end
