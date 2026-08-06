defmodule Mix.Tasks.Herd do
  @moduledoc """
  Eva Power up!
  """

  use Mix.Task

  alias Eva.AI.Events, as: AIEvents
  alias Eva.Agent.Events
  alias Eva.Agent.Session.Storage

  alias Eva.Coding.SessionIndexManager
  alias Eva.Coding.Session, as: CodingSession
  alias Eva.Coding.Session.SessionConfig

  @impl true
  def run(args) do
    # Application.ensure_all_started(Eva.Application)
    Mix.Task.run("app.start")

    {opts, _remaining, _invalid} =
      OptionParser.parse(args,
        strict: [prompt: :string, mcp: :boolean],
        aliases: [p: :prompt]
      )

    prompt = Keyword.get(opts, :prompt)
    mcp? = Keyword.get(opts, :mcp, false)
    run_prompt(prompt, mcp?)
  end

  defp run_prompt(prompt, mcp?) do
    cwd = File.cwd!()
    index_manager = SessionIndexManager.new()
    model = "deepseek-v4-pro"

    session_index_entry =
      SessionIndexManager.prepare_index(index_manager, %{
        cwd: cwd,
        model: model,
        provider_name: "opencode-go"
      })

    jsonl_storage = Storage.Jsonl.new(session_index_entry.session_path)

    provider_config = Eva.AI.Providers.build(:opencode_go)

    config = %SessionConfig{
      cwd: cwd,
      storage: jsonl_storage,
      provider_config: provider_config,
      listener_pid: self(),
      model: model
    }

    {:ok, coding_session_pid} = CodingSession.start_link(%{config: config})

    if mcp? do
      IO.puts([IO.ANSI.faint(), "… discovering MCP tools", IO.ANSI.reset()])

      case CodingSession.prompt(coding_session_pid, "do nothing") do
        :ok -> receive_stream()
        {:error, reason} -> IO.puts(:stderr, reason)
      end
    end

    case CodingSession.prompt(coding_session_pid, prompt) do
      :ok -> receive_stream()
      {:error, reason} -> IO.puts(:stderr, reason)
    end
  end

  defp receive_stream do
    receive do
      %Events.MessageUpdate{assistant_message_event: %AIEvents.TextDelta{delta: d}} ->
        IO.write(d)
        receive_stream()

      %Events.MessageUpdate{assistant_message_event: %AIEvents.ThinkingDelta{delta: d}} ->
        IO.write([IO.ANSI.light_green(), IO.ANSI.italic(), d, IO.ANSI.reset()])
        receive_stream()

      %Events.TurnEnd{} ->
        IO.puts("")
        receive_stream()

      %Events.AgentEnd{messages: _messages} ->
        IO.puts("")

      %Events.ToolExecutionStart{} = event ->
        IO.puts([
          IO.ANSI.cyan(),
          "  ⚡ ",
          IO.ANSI.reset(),
          event.tool_name,
          format_arg_summary(event.args)
        ])

        receive_stream()

      %Events.ToolExecutionEnd{} = event ->
        icon =
          if event.is_error,
            do: [IO.ANSI.red(), "  ✗"],
            else: [IO.ANSI.green(), "  ✓"]

        IO.puts([icon, IO.ANSI.reset(), " ", event.tool_name])
        receive_stream()

      # MCP is an extension now, so its events arrive wrapped rather than as core
      # structs. Everything an extension publishes looks like this.
      %Events.ExtensionEvent{extension: name, payload: payload} ->
        IO.puts([
          IO.ANSI.faint(),
          "  ◆ ",
          IO.ANSI.reset(),
          name,
          IO.ANSI.faint(),
          " ",
          summarize_extension_event(payload),
          IO.ANSI.reset()
        ])

        receive_stream()

      %Events.ToolExecutionUpdate{} = _event ->
        receive_stream()

      other ->
        IO.puts("")

        IO.puts([
          IO.ANSI.faint(),
          "  Unhandled: ",
          Atom.to_string(other.__struct__),
          IO.ANSI.reset()
        ])

        receive_stream()
    end
  end

  # An extension's payload is its own business, so there is nothing to pattern match on —
  # show the struct name when there is one and fall back to a plain inspect.
  defp summarize_extension_event(%{__struct__: module} = payload) do
    [inspect(module), " ", inspect(Map.get(payload, :server_name, ""))]
  end

  defp summarize_extension_event(payload), do: inspect(payload)

  defp format_arg_summary(args) when map_size(args) == 0, do: ""

  defp format_arg_summary(%{command: cmd}) do
    [IO.ANSI.faint(), " ", String.slice(cmd, 0, 80), IO.ANSI.reset()]
  end

  defp format_arg_summary(%{filePath: path}) do
    [IO.ANSI.faint(), " ", Path.basename(path), IO.ANSI.reset()]
  end

  defp format_arg_summary(%{pattern: pat}) do
    [IO.ANSI.faint(), " ", pat, IO.ANSI.reset()]
  end

  defp format_arg_summary(args) do
    [IO.ANSI.faint(), " (", args |> Map.keys() |> Enum.join(", "), ")", IO.ANSI.reset()]
  end
end
