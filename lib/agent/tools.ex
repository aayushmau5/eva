defmodule Eva.Agent.Tools do
  @moduledoc """
  Tool related types. Common between Agent & AI module.
  """
  defmodule ToolCall do
    @moduledoc """
    A request from the assistant to execute a named tool.
    """
    use TypedStruct

    typedstruct do
      field :id, String.t()
      field :name, String.t()
      field :arguments, map() | String.t()
    end
  end
end
