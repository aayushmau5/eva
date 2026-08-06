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

  @doc """
  Every request this provider was asked to stream, oldest first.

  One entry per provider call, not per turn — a turn with tool calls makes several.
  Lets a test assert on what the model actually saw, as opposed to what the
  transcript holds.
  """
  def get_requests(pid), do: GenServer.call(pid, :get_requests)

  @impl true
  def init(turns) do
    {:ok, %{turns: turns, current: 0, requests: []}}
  end

  @impl true
  def handle_call(:get_requests, _from, state) do
    {:reply, Enum.reverse(state.requests), state}
  end

  @impl true
  def handle_cast({:stream, opts}, state) do
    turn_events = Enum.at(state.turns, state.current, [])
    listener_pid = opts.listener_pid

    Task.start(fn ->
      Enum.each(turn_events, fn event ->
        send(listener_pid, event)
      end)
    end)

    {:noreply, %{state | current: state.current + 1, requests: [opts | state.requests]}}
  end
end
