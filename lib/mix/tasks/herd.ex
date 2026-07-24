defmodule Mix.Tasks.Herd do
  @moduledoc """
  Eva Power up!
  """

  use Mix.Task

  alias Eva.Agent.Events
  alias Eva.Agent.Messages, as: AgentMessages
  alias Eva.Agent.Session.Storage

  alias Eva.Coding.SessionIndexManager
  alias Eva.Coding.Session, as: CodingSession
  alias Eva.Coding.Session.SessionConfig
  alias Eva.AI.Config, as: ProviderConfig

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

    provider_config = %ProviderConfig.OpenAICompatible{
      base_url: "http://localhost:1234/v1",
      provider_name: "lmstudio"
    }

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
    receive_stream(%{text_len: 0, thinking_len: 0})
  end

  defp receive_stream(state) do
    receive do
      %Events.MessageUpdate{message: msg} ->
        text = AgentMessages.AssistantMessage.text(msg)
        thinking = AgentMessages.AssistantMessage.thinking_text(msg)

        text_delta = String.slice(text, state.text_len..-1//1)
        thinking_delta = String.slice(thinking, state.thinking_len..-1//1)

        if text_delta != "", do: IO.write(text_delta)
        if thinking_delta != "", do: IO.write(thinking_delta)

        receive_stream(%{text_len: String.length(text), thinking_len: String.length(thinking)})

      %Events.TurnEnd{} ->
        IO.puts("")
        receive_stream(%{text_len: 0, thinking_len: 0})

      %Events.AgentEnd{messages: _messages} ->
        IO.puts("")

      _other ->
        receive_stream(state)
    end
  end
end
