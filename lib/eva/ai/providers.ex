defmodule Eva.AI.Providers do
  alias Eva.AI.Config.OpenAICompatible

  @spec default() :: OpenAICompatible.t()
  def default() do
    build(configured())
  end

  @spec build(:opencode_go | :lmstudio) :: OpenAICompatible.t()
  def build(:opencode_go) do
    %OpenAICompatible{
      api_key: Application.get_env(:eva, :opencode_api_key),
      base_url: "https://opencode.ai/zen/go/v1",
      provider_name: "opencode-go"
    }
  end

  def build(:lmstudio) do
    %OpenAICompatible{
      base_url: "http://localhost:1234/v1",
      provider_name: "lmstudio"
    }
  end

  defp configured(), do: Application.get_env(:eva, :provider, :lmstudio)
end
