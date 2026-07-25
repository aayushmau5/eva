defmodule Eva.AI.LmStudioTest do
  use ExUnit.Case

  alias Eva.AI.{Events, OpenAICompatibleProvider, Config.OpenAICompatible}
  alias Eva.Agent

  describe "GenServer lifecycle" do
    test "starts with default config" do
      config = %OpenAICompatible{
        base_url: "http://localhost:1234",
        api: "openai-completions",
        provider_name: "lm-studio"
      }

      {:ok, pid} = OpenAICompatibleProvider.start_link(config: config, name: nil)

      assert Process.alive?(pid)

      GenServer.stop(pid)
    end
  end

  describe "streaming with real LM Studio" do
    @tag :external
    @tag timeout: 30_000

    test "{:stream, opts} sends events in order" do
      unless lm_studio_alive?() do
        IO.puts(
          :stderr,
          "Skipping integration test: LM Studio not reachable at #{lm_studio_url()}"
        )
      else
        config = %OpenAICompatible{
          base_url: lm_studio_url(),
          api: "openai-completions",
          provider_name: "lm-studio"
        }

        {:ok, pid} = OpenAICompatibleProvider.start_link(config: config, name: nil)

        OpenAICompatibleProvider.stream_response(
          pid,
          %{
            listener_pid: self(),
            model: model_name(),
            system_prompt: "",
            messages: [%Agent.Messages.UserMessage{content: "What's the weather?"}],
            tools: []
          }
        )

        assert_receive %Events.AssistantStart{partial: partial}, 5000
        assert is_binary(partial.model)

        {deltas, end_event} = collect_events([])

        assert %Events.AssistantDone{
                 message: %Agent.Messages.AssistantMessage{} = message,
                 reason: _finish_reason
               } = end_event

        assert Agent.Messages.AssistantMessage.text(message) ==
                 Enum.join(Enum.reverse(deltas), "")

        GenServer.stop(pid)
      end
    end

    defp collect_events(acc) do
      receive do
        %Events.TextDelta{delta: d} ->
          collect_events([d | acc])

        %Events.ThinkingDelta{delta: d} ->
          collect_events([d | acc])

        %Events.AssistantDone{} = ev ->
          {acc, ev}

        %Events.AssistantError{} = ev ->
          {acc, ev}
      after
        50_000 -> {acc, nil}
      end
    end
  end

  defp lm_studio_url, do: Application.get_env(:eva, :lm_studio_url, "http://localhost:1234")

  defp lm_studio_alive? do
    uri = URI.parse(lm_studio_url())
    host = uri.host |> String.to_charlist()
    port = uri.port

    case :gen_tcp.connect(host, port, [], 500) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        true

      {:error, _} ->
        false
    end
  end

  defp model_name do
    Application.get_env(:eva, :lm_studio_model, "nvidia/nemotron-3-nano-4b")
  end
end
