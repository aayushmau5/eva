defmodule Eva.Test.MockProvider do
  @moduledoc """
  A mock provider GenServer for testing Eva.Agent.Loop.

  Accepts a list of turns where each turn is a list of `Eva.AI.Events` structs
  to send to the listener. Supports multi-turn agent runs.
  """

  use GenServer

  def start_link(turns \\ []) do
    GenServer.start_link(__MODULE__, turns)
  end

  @impl true
  def init(turns) do
    {:ok, %{turns: turns, current: 0}}
  end

  @impl true
  def handle_cast({:run, run_opts}, state) do
    turn_events = Enum.at(state.turns, state.current, [])
    listener_pid = Keyword.fetch!(run_opts, :listener_pid)

    Task.start(fn ->
      Enum.each(turn_events, fn event ->
        send(listener_pid, event)
      end)
    end)

    {:noreply, %{state | current: state.current + 1}}
  end
end
