defmodule Eva.Coding.SessionName do
  @moduledoc """
  Module for naming a session.
  """

  alias Eva.AI.Events, as: AIEvents
  alias Eva.AI.OpenAICompatibleProvider
  alias Eva.AI.Config, as: ProviderConfig

  alias Eva.Agent.Messages

  @session_name_system_prompt """
  You write concise coding-agent session names. Reply with only a short title,
  maximum four words, no quotes, no punctuation-only output.
  """

  @doc """
  Name a session from User's (first) message.

  This function must be spawned in a Task or separate process.
  """
  @spec name_session(String.t(), %{
          config: ProviderConfig.OpenAICompatibleConfig.t(),
          model: String.t()
        }) :: String.t() | nil
  def name_session(first_message, opts) do
    prompt = """
    Create a concise session name for this first user message. Use at most four words.

    User message:

    #{first_message}
    """

    messages = [%Messages.UserMessage{content: prompt}]

    {:ok, provider_pid} =
      OpenAICompatibleProvider.start_link(
        name: nil,
        config: opts.config
      )

    :ok =
      OpenAICompatibleProvider.stream_response(provider_pid, %{
        listener_pid: self(),
        model: opts.model,
        system_prompt: @session_name_system_prompt,
        messages: messages,
        tools: []
      })

    case collect_name_response(<<>>) do
      nil -> nil
      text -> sanitize_session_name(text)
    end
  end

  @doc """
  Strips quotes, punctuation and surrounding symbols, then takes the first four words.
  Returns nil when no words remain (e.g. the prompt was all punctuation).
  """
  @spec sanitize_session_name(String.t()) :: String.t() | nil
  def sanitize_session_name(text) when is_binary(text) do
    words =
      text
      |> String.trim()
      |> String.replace(~r/["'`"“‘']/u, "")
      |> String.split()
      |> Enum.map(&String.replace(&1, ~r/^[\p{P}\p{S}"'`"“”‘’]+|[\p{P}\p{S}"'`"“”‘’]+$/u, ""))
      |> Enum.reject(&(&1 == ""))

    if words == [], do: nil, else: words |> Enum.take(4) |> Enum.join(" ")
  end

  defp collect_name_response(acc) do
    receive do
      %AIEvents.TextDelta{delta: d} ->
        collect_name_response(<<acc::binary, d::binary>>)

      %AIEvents.AssistantDone{message: message} ->
        text = Messages.AssistantMessage.text(message)
        if text != "", do: text, else: acc

      %AIEvents.AssistantError{} ->
        nil

      _ ->
        collect_name_response(acc)
    after
      15_000 ->
        nil
    end
  end
end
