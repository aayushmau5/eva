defmodule Eva.AI.LmStudioTest do
  use ExUnit.Case

  alias Eva.AI.{LmStudio, Events}

  describe "GenServer lifecycle" do
    test "starts and accepts change_config" do
      {:ok, pid} = LmStudio.start_link(name: nil)

      assert :ok = GenServer.call(pid, {:change_config, %{model: "test"}})

      state = GenServer.call(pid, :get_state)
      assert state.model == "test"

      GenServer.stop(pid)
    end
  end

  describe "streaming with real LM Studio" do
    @tag :external
    @tag timeout: 30_000

    test "{:run, prompt, self()} streams events in order" do
      {:ok, pid} = LmStudio.start_link(name: nil)

      GenServer.cast(pid, {:run, "What is the weather?", self()})

      assert_receive %Events.ProviderResponseStart{model: model}, 5000
      assert is_binary(model)

      {deltas, end_event} = collect_events([])

      assert %Events.ProviderResponseEnd{
               message: %{content: content},
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
