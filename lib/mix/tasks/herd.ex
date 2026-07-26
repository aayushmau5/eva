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
      OptionParser.parse(args, strict: [prompt: :string], aliases: [p: :prompt])

    prompt = Keyword.get(opts, :prompt)
    run_prompt(prompt)
  end

  defp run_prompt(prompt) do
    cwd = File.cwd!()
    index_manager = SessionIndexManager.new()
    model = "nvidia/nemotron-3-nano-4b"

    session_index_entry =
      SessionIndexManager.prepare_index(index_manager, %{
        cwd: cwd,
        model: model,
        provider_name: "lmstudio"
      })

    jsonl_storage = Storage.Jsonl.new(session_index_entry.session_path)

    provider_config = Eva.AI.Providers.build(:lmstudio)

    config = %SessionConfig{
      cwd: cwd,
      storage: jsonl_storage,
      provider_config: provider_config,
      listener_pid: self(),
      model: model
    }

    {:ok, coding_session_pid} = CodingSession.start_link(%{config: config})

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

      _other ->
        receive_stream()
    end
  end
end
