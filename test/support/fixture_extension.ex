defmodule Eva.Extension.Fixture do
  @moduledoc """
  A whole extension, small enough to reason about, real enough to run on another node.

  It lives in `test/support` rather than a heredoc because a node extension has to be
  *loadable from a code path* — a module compiled into a test VM's memory cannot be reached
  by a second VM, which is the whole situation being tested.
  """

  use Eva.Extension

  @impl true
  def setup(ctx) do
    {:ok,
     %Spec{
       guidelines: ["fixture guideline for #{ctx.cwd}"],
       commands: [%Spec.Command{name: "fixture", description: "echoes", arg_hint: "[text]"}],
       tools: [
         %Tools.AgentTool{
           name: "fixture_echo",
           description: "Echoes its argument back",
           input_schema: %{type: "object", properties: %{text: %{type: "string"}}},
           executor: fn args, _exec_ctx ->
             %Tools.AgentToolResult{
               content: [%Messages.TextContent{text: "echo: #{args["text"]}"}]
             }
           end
         }
       ]
     }}
  end

  @impl true
  def init(ctx), do: {:ok, %{ctx: ctx, seen: []}}

  @impl true
  def handle_command("fixture", args, state) do
    {{:text, "fixture on #{node()} says #{args}"}, state}
  end

  @impl true
  def handle_request(:where, state), do: {{:ok, node()}, state}

  def handle_request(:entries, state), do: {{:ok, state.ctx.entries}, state}

  def handle_request({:publish, payload}, state) do
    API.publish_event(state.ctx, payload)
    {:ok, state}
  end

  # Exercises the capability path from wherever this extension happens to be running.
  def handle_request({:ask, question, default}, state) do
    impl = state.ctx.capabilities
    {{:ok, impl.ask(question, default, session_pid: state.ctx.session_pid)}, state}
  end

  def handle_request(:capabilities_module, state), do: {{:ok, state.ctx.capabilities}, state}

  def handle_request(_request, state), do: {{:error, :not_implemented}, state}
end
