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
    field :tools, [Tools.AgentTool.t()] | [], default: []
    field :resource_paths, Eva.Coding.Resources.t()
    field :session_id, String.t()
    field :session_index_manager, Eva.Coding.SessionIndexManager.t()
    field :provider_config, Eva.AI.Config.t()
    field :auto_compact_token_threshold, non_neg_integer(), default: 200_000
    field :auto_compact_enabled, boolean(), default: true
    field :defer_index?, boolean(), default: false
    field :listener_pid, pid() | nil, default: nil
  end
end
