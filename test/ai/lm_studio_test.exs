defmodule Eva.AI.LmStudioTest do
  use ExUnit.Case

  alias Eva.AI.{LmStudio, Events}
  alias Eva.Agent

  describe "GenServer lifecycle" do
    test "starts with default config" do
      {:ok, pid} = LmStudio.start_link(name: nil)

      assert Process.alive?(pid)

      GenServer.stop(pid)
    end
  end

  describe "streaming with real LM Studio" do
    @tag :external
    @tag timeout: 30_000

    test "{:run, run_opts} streams events in order" do
      {:ok, pid} = LmStudio.start_link(name: nil)

      GenServer.cast(
        pid,
        {:run,
         [
           listener_pid: self(),
           messages: [%Agent.Messages.UserMessage{content: "What's the weather?"}]
         ]}
      )

      assert_receive %Events.ProviderResponseStart{model: model}, 5000
      assert is_binary(model)

      {deltas, end_event} = collect_events([])

      assert %Events.ProviderResponseEnd{
               message: %Agent.Messages.AssistantMessage{content: content},
               finish_reason: finish_reason
             } = end_event

      assert content == Enum.join(Enum.reverse(deltas), "")
      assert is_binary(finish_reason) or is_nil(finish_reason)

      GenServer.stop(pid)
    end

    defp collect_events(acc) do
      receive do
        %Events.ProviderTextDelta{delta: d} ->
          collect_events([d | acc])

        %Events.ProviderThinkingDelta{delta: d} ->
          collect_events([d | acc])

        %Events.ProviderResponseEnd{} = ev ->
          {acc, ev}
      after
        10000 -> {acc, nil}
      end
    end
  end
end
