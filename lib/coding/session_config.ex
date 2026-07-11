defmodule Eva.Coding.SessionConfig do
  use TypedStruct

  alias Eva.Agent.Tools

  typedstruct do
    field :cwd, String.t(), enforce: true
    field :storage, Eva.Agent.Session.Storage.t(), enforce: true
    field :system_prompt, String.t()
    field :custom_system_prompt, String.t()
    field :append_system_prompt, String.t()
    field :context_files, map(), default: %{}
    field :tools, [Tools.AgentTool.t()], default: []
  end
end
