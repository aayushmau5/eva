defmodule Eva.Coding.SessionName do
  @moduledoc """
  Module for naming a session.
  """

  alias Eva.AI.Events, as: AIEvents
  alias Eva.AI.LmStudio

  alias Eva.Agent.Messages

  @session_name_system_prompt """
  You write concise coding-agent session names. Reply with only a short title,
  maximum four words, no quotes, no punctuation-only output.
  """

  @doc """
  Name a session from User's (first) message.

  This function must be spawned in a Task or separate process.
  """
  @spec name_session(String.t(), String.t()) :: String.t() | nil
  def name_session(first_message, model) do
    prompt = """
    Create a concise session name for this first user message. Use at most four words.

    User message:

    #{first_message}
    """

    messages = [%Messages.UserMessage{content: prompt}]

    {:ok, provider_pid} =
      LmStudio.start_link(
        system_prompt: @session_name_system_prompt,
        model: model,
        name: nil
      )

    GenServer.cast(provider_pid, {:run, [listener_pid: self(), messages: messages, tools: []]})

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
      %AIEvents.ProviderTextDelta{delta: d} ->
        collect_name_response(<<acc::binary, d::binary>>)

      %AIEvents.ProviderThinkingDelta{} ->
        collect_name_response(acc)

      %AIEvents.ProviderToolCall{} ->
        collect_name_response(acc)

      %AIEvents.ProviderResponseStart{} ->
        collect_name_response(acc)

      %AIEvents.ProviderResponseEnd{message: %Messages.AssistantMessage{content: c}} ->
        if c != "", do: c, else: acc

      %AIEvents.ProviderError{} ->
        nil
    after
      15_000 ->
        nil
    end
  end
end
