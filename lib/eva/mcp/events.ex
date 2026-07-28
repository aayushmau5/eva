defmodule Eva.MCP.Events do
  @moduledoc """
  Events broadcast by an MCP client to its subscribers.

  Every struct here is a `:pg` broadcast to the `{:mcp, scope_dir, server_name}`
  group — they are server-initiated notifications, which carry no JSON-RPC `id`
  and describe facts about the server that every subscriber needs.
  """
  use TypedStruct

  @typedoc "Where the server was configured. `:global` for `~/.eva/mcp.json`."
  @type scope_dir :: :global | String.t()

  @type tool :: %{name: String.t(), description: String.t() | nil, input_schema: map()}
  @type resource :: %{uri: String.t(), name: String.t() | nil, mime_type: String.t() | nil}
  @type resource_template :: %{uri_template: String.t(), name: String.t() | nil}
  @type prompt :: %{name: String.t(), description: String.t() | nil, arguments: [map()]}

  @type t ::
          ServerConnected.t()
          | ServerDisconnected.t()
          | ServerError.t()
          | AuthRequired.t()
          | ToolsDiscovered.t()
          | ToolsChanged.t()
          | ResourcesDiscovered.t()
          | ResourcesChanged.t()
          | ResourceUpdated.t()
          | ResourceSubscribed.t()
          | PromptsDiscovered.t()
          | PromptsChanged.t()
          | ServerLog.t()

  # -- Lifecycle --

  typedstruct module: ServerConnected do
    field :type, String.t(), default: "mcp_server_connected"
    field :server_name, String.t()
    field :scope_dir, Eva.MCP.Events.scope_dir()
    field :server_version, String.t()
    field :protocol_version, String.t()
    field :capabilities, map(), default: %{}
  end

  typedstruct module: ServerDisconnected do
    field :type, String.t(), default: "mcp_server_disconnected"
    field :server_name, String.t()
    field :scope_dir, Eva.MCP.Events.scope_dir()
    field :reason, :connection_lost | :explicit_shutdown | :process_exit
  end

  # `phase` drives what the UI can suggest: `:spawn` is a bad command or PATH
  # problem the user must fix, `:initialize` is a protocol mismatch, `:request`
  # is usually transient.
  typedstruct module: ServerError do
    field :type, String.t(), default: "mcp_server_error"
    field :server_name, String.t()
    field :scope_dir, Eva.MCP.Events.scope_dir()
    field :error, String.t()
    field :phase, :spawn | :initialize | :request
  end

  # A 401 that refreshing the stored token could not resolve. The client parks in
  # `:needs_auth` and exposes no tools; it never opens a browser itself, so this
  # is purely a hint carrying the command the user should run.
  typedstruct module: AuthRequired do
    field :type, String.t(), default: "mcp_auth_required"
    field :server_name, String.t()
    field :scope_dir, Eva.MCP.Events.scope_dir()
    field :login_command, String.t()
  end

  # -- Tools --

  typedstruct module: ToolsDiscovered do
    field :type, String.t(), default: "mcp_tools_discovered"
    field :server_name, String.t()
    field :scope_dir, Eva.MCP.Events.scope_dir()
    field :tools, [Eva.MCP.Events.tool()], default: []
  end

  # `tools` is the full new state; `added`/`removed` are the diff for the UI and
  # for logging description changes.
  typedstruct module: ToolsChanged do
    field :type, String.t(), default: "mcp_tools_changed"
    field :server_name, String.t()
    field :scope_dir, Eva.MCP.Events.scope_dir()
    field :tools, [Eva.MCP.Events.tool()], default: []
    field :added, [Eva.MCP.Events.tool()], default: []
    field :removed, [String.t()], default: []
  end

  # -- Resources --

  typedstruct module: ResourcesDiscovered do
    field :type, String.t(), default: "mcp_resources_discovered"
    field :server_name, String.t()
    field :scope_dir, Eva.MCP.Events.scope_dir()
    field :resources, [Eva.MCP.Events.resource()], default: []
    field :templates, [Eva.MCP.Events.resource_template()], default: []
  end

  typedstruct module: ResourcesChanged do
    field :type, String.t(), default: "mcp_resources_changed"
    field :server_name, String.t()
    field :scope_dir, Eva.MCP.Events.scope_dir()
    field :resources, [Eva.MCP.Events.resource()], default: []
    field :templates, [Eva.MCP.Events.resource_template()], default: []
  end

  # Broadcast to every subscriber, so a session must ignore URIs outside its own
  # read-set — the client does not track which session read what.
  typedstruct module: ResourceUpdated do
    field :type, String.t(), default: "mcp_resource_updated"
    field :server_name, String.t()
    field :scope_dir, Eva.MCP.Events.scope_dir()
    field :uri, String.t()
  end

  typedstruct module: ResourceSubscribed do
    field :type, String.t(), default: "mcp_resource_subscribed"
    field :server_name, String.t()
    field :scope_dir, Eva.MCP.Events.scope_dir()
    field :uri, String.t()
  end

  # -- Prompts --

  typedstruct module: PromptsDiscovered do
    field :type, String.t(), default: "mcp_prompts_discovered"
    field :server_name, String.t()
    field :scope_dir, Eva.MCP.Events.scope_dir()
    field :prompts, [Eva.MCP.Events.prompt()], default: []
  end

  typedstruct module: PromptsChanged do
    field :type, String.t(), default: "mcp_prompts_changed"
    field :server_name, String.t()
    field :scope_dir, Eva.MCP.Events.scope_dir()
    field :prompts, [Eva.MCP.Events.prompt()], default: []
  end

  # -- Logging --

  # Covers both `notifications/message` and stdio stderr lines, which are
  # synthesized as `level: :error, logger: "stderr"`.
  typedstruct module: ServerLog do
    field :type, String.t(), default: "mcp_server_log"
    field :server_name, String.t()
    field :scope_dir, Eva.MCP.Events.scope_dir()
    field :level, :debug | :info | :warning | :error
    field :logger, String.t()
    field :message, String.t()
  end

  @modules [
    ServerConnected,
    ServerDisconnected,
    ServerError,
    AuthRequired,
    ToolsDiscovered,
    ToolsChanged,
    ResourcesDiscovered,
    ResourcesChanged,
    ResourceUpdated,
    ResourceSubscribed,
    PromptsDiscovered,
    PromptsChanged,
    ServerLog
  ]

  @doc """
  Every event module in this file.

  Usable in a module attribute so consumers can guard on it without repeating
  the list: `@mcp_events Eva.MCP.Events.modules()`, then
  `def handle_info(%{__struct__: mod} = event, state) when mod in @mcp_events`.
  """
  @spec modules() :: [module()]
  def modules, do: @modules
end
