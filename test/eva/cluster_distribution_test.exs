defmodule Eva.Cluster.DistributionTest do
  @moduledoc """
  The name Eva gives itself. Starting distribution for real is `mix test.dist`'s job.
  """

  use ExUnit.Case, async: false

  alias Eva.Cluster.Distribution
  alias Eva.Core.Cluster.Host

  setup do
    # `Host` caches, and it is global.
    configured = Application.get_env(:eva_core, :host)
    cached = :persistent_term.get(Host, nil)

    on_exit(fn ->
      if configured,
        do: Application.put_env(:eva_core, :host, configured),
        else: Application.delete_env(:eva_core, :host)

      if cached, do: :persistent_term.put(Host, cached), else: :persistent_term.erase(Host)
    end)

    :ok
  end

  defp with_host(host) do
    Application.put_env(:eva_core, :host, host)
    Host.refresh()
  end

  test "carries the OS pid, so epmd -names can be read against ps" do
    # Loopback means "me" to whoever reads it, so there is nothing to add.
    with_host("127.0.0.1")

    assert Distribution.node_name("127.0.0.1") == :"eva_#{System.pid()}@127.0.0.1"
  end

  test "adds the machine, so two Evas on two machines cannot collide" do
    with_host("100.64.5.20")

    assert Distribution.node_name("127.0.0.1") ==
             :"eva_#{System.pid()}_100_64_5_20@127.0.0.1"
  end

  test "the machine goes in the name, never in the host" do
    # Eva listens on loopback. Naming it for an address it does not listen on is the one
    # thing the naming rule exists to prevent.
    with_host("100.64.5.20")

    assert Distribution.node_name("127.0.0.1")
           |> Atom.to_string()
           |> String.ends_with?("@127.0.0.1")
  end

  test "a name is left alone when there is no address to add" do
    # No tailnet means no cluster to collide in, and no change from what it was before any
    # of this existed.
    Application.delete_env(:eva_core, :host)
    System.delete_env("EVA_HOST")
    Host.refresh()

    name = Distribution.node_name("127.0.0.1") |> Atom.to_string()

    case Host.source() do
      :loopback -> assert name == "eva_#{System.pid()}@127.0.0.1"
      _resolved -> assert name =~ "eva_#{System.pid()}_"
    end
  end

  test "anything a node name cannot hold becomes an underscore" do
    with_host("devbox.example.com")

    assert Distribution.node_name("127.0.0.1") ==
             :"eva_#{System.pid()}_devbox_example_com@127.0.0.1"
  end

  test "listening stays on loopback unless a port is explicitly configured" do
    assert Distribution.listener_binding([]) == :loopback
    assert Distribution.listener_binding(port: 9_001) == {:reachable, 9_001}
  end

  test "an invalid reachable port is rejected before distribution starts" do
    assert_raise ArgumentError, ~r/distribution port/, fn ->
      Distribution.listener_binding(port: 70_000)
    end
  end
end
