defmodule Eva.Test.MockHarness do
  @moduledoc """
  A mock harness GenServer for testing Eva.Agent.Loop.

  Collects agent events and implements the drain_queue call required by the loop.
  Pre-populate steering or follow-up queues to test mid-run message injection.
  """

  use GenServer

  def start_link(initial_queues \\ %{steering: [], follow_up: []}) do
    GenServer.start_link(__MODULE__, initial_queues)
  end

  @doc """
  Returns all events collected so far, in order.
  """
  def get_events(pid) do
    GenServer.call(pid, :get_events)
  end

  @impl true
  def init(queues) do
    {:ok, %{events: [], queues: queues}}
  end

  @impl true
  def handle_call({:drain_queue, type}, _from, state) do
    queued = get_in(state.queues, [type]) || []
    {:reply, queued, put_in(state.queues[type], [])}
  end

  @impl true
  def handle_call(:get_events, _from, state) do
    {:reply, Enum.reverse(state.events), state}
  end

  @impl true
  def handle_info(event, state) do
    {:noreply, %{state | events: [event | state.events]}}
  end
end
