defmodule Eva.Core.Extension.Spec do
  @moduledoc """
  The contract between an extension and Eva.
  """

  use TypedStruct

  alias Eva.Core.Agent.Tools

  typedstruct do
    # Extensions can have tools
    field :tools, [Tools.AgentTool.t()], default: []

    # Extensions can have guidelines that go into the system prompt
    field :guidelines, [String.t()], default: []

    # Extensions can register `/` commands
    field :commands, [Command.t()], default: []

    # Extensions can provide hooks at tool_call, tool_result, modify user input, or
    # reshape the messages sent to the model (`:context`)
    field :hooks, [:tool_call | :tool_result | :input | :context], default: []

    # The event classes this extension is concerned with(does it only need :mcp events or :extension events)
    field :event_classes, [Eva.Core.Bus.classes()], default: []
  end

  typedstruct module: Command do
    field :name, String.t()
    field :description, String.t()
    field :arg_hint, String.t()
  end

  @doc """
  Whether the extension needs to work on a separate process or not.
  Extensions that provide `tools` or `guidelines` only don't need a separate process.
  """
  @spec stateful?(t()) :: boolean()
  def stateful?(%__MODULE__{hooks: [], event_classes: [], commands: []}), do: false
  def stateful?(%__MODULE__{}), do: true
end
