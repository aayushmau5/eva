defmodule Mix.Tasks.Herd do
  @moduledoc """
  Eva Power up!
  """

  use Mix.Task

  alias Eva.Coding.SessionIndexManager
  alias Eva.Coding.Session, as: CodingSession
  alias Eva.Coding.SessionConfig
  alias Eva.Agent.Events
  alias Eva.Agent.Session.Storage
  alias Eva.Coding.SystemPrompt

  @impl true
  def run(args) do
    # Application.ensure_all_started(Eva.Application)
    Mix.Task.run("app.start")

    {opts, _remaining, _invalid} =
      OptionParser.parse(args, strict: [prompt: :string], aliases: [p: :prompt])

    prompt = Keyword.get(opts, :prompt)
    run_prompt(prompt)
  end

  defp run_prompt(prompt) do
    cwd = File.cwd!()
    index_manager = SessionIndexManager.new()
    tools = Eva.Coding.Tools.coding_tools(cwd)

    session_index_entry =
      SessionIndexManager.prepare_index(index_manager, %{
        cwd: cwd,
        model: "liquid/lfm2.5-1.2b",
        provider_name: "lmstudio"
      })

    jsonl_storage = Storage.Jsonl.new(session_index_entry.session_path)

    system_prompt_options = %SystemPrompt.Options{
      cwd: cwd,
      tools: tools
    }

    config = %SessionConfig{
      cwd: cwd,
      storage: jsonl_storage,
      listener_pid: self(),
      system_prompt: SystemPrompt.build(system_prompt_options)
      # system_prompt:
      #   "You are a weather assistant. Always reply with weather is nice. Don't use any tools."
    }

    {:ok, coding_session_pid} = CodingSession.start_link(%{config: config})

    case CodingSession.prompt(coding_session_pid, prompt) do
      :ok -> receive_stream()
      {:error, reason} -> IO.puts(:stderr, reason)
    end
  end

  defp receive_stream do
    receive do
      %Events.MessageDelta{delta: d} ->
        IO.write(d)
        receive_stream()

      %Events.ThinkingDelta{delta: d} ->
        IO.write(d)
        receive_stream()

      %Events.AgentEnd{} ->
        IO.puts("")

      %Events.Error{message: msg} ->
        IO.puts(:stderr, "\nError: #{msg}")

      _other ->
        receive_stream()
    end
  end
end
