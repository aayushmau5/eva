defmodule Eva.Coding.Thinking do
  @thinking_levels ["none", "minimal", "low", "medium", "high", "xhigh"]
  @thinking_level_descriptions %{
    "none" => "No reasoning",
    "minimal" => "Very brief reasoning",
    "low" => "Light reasoning",
    "medium" => "Moderate reasoning",
    "high" => "Deep reasoning",
    "xhigh" => "Maximum reasoning"
  }
  @default_thinking_level "low"

  def thinking_levels() do
    @thinking_levels
  end

  def thinking_level_descriptions() do
    @thinking_level_descriptions
  end

  def default_thinking_level() do
    @default_thinking_level
  end
end
