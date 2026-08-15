defmodule Eva.Core.Cluster.HostTest do
  @moduledoc """
  What this machine calls itself, and how it decided.

  The range check is the part worth testing hard: it is the only piece that has to work
  identically on a Linux box with `tailscale0` and a Mac with some `utunN`, and the only
  way to be sure is to check the addresses rather than the interface names.
  """

  use ExUnit.Case, async: false

  alias Eva.Core.Cluster.Host

  setup do
    # `resolve/0` reads app env and the environment; both are global, so this file cannot
    # be async and has to put back what it found.
    host = Application.get_env(:eva_core, :host)
    env = System.get_env("EVA_HOST")
    cached = :persistent_term.get(Host, nil)

    on_exit(fn ->
      if host,
        do: Application.put_env(:eva_core, :host, host),
        else: Application.delete_env(:eva_core, :host)

      if env, do: System.put_env("EVA_HOST", env), else: System.delete_env("EVA_HOST")
      if cached, do: :persistent_term.put(Host, cached), else: :persistent_term.erase(Host)
    end)

    Application.delete_env(:eva_core, :host)
    System.delete_env("EVA_HOST")
    :persistent_term.erase(Host)

    :ok
  end

  describe "resolve/0" do
    test "config wins over everything" do
      Application.put_env(:eva_core, :host, "10.0.0.1")
      System.put_env("EVA_HOST", "10.0.0.2")

      assert Host.resolve() == {"10.0.0.1", :config}
    end

    test "EVA_HOST is next, for a node started by a script with no app config to reach" do
      System.put_env("EVA_HOST", "10.0.0.2")

      assert Host.resolve() == {"10.0.0.2", :env}
    end

    test "an empty setting is not a setting" do
      Application.put_env(:eva_core, :host, "")
      System.put_env("EVA_HOST", "")

      assert {_host, source} = Host.resolve()
      refute source in [:config, :env]
    end

    test "falls back to loopback, which is the right answer for one machine" do
      # Only meaningful on a machine with no tailnet — where there is one, the fallback is
      # correctly not reached, and `tailscale_address/1` below covers that half.
      case Host.resolve() do
        {"127.0.0.1", :loopback} -> :ok
        {_address, :tailscale} -> :ok
      end
    end
  end

  describe "tailscale_address/1" do
    test "finds a 100.64.0.0/10 address whatever the interface is called" do
      assert Host.tailscale_address([
               {~c"lo0", [addr: {127, 0, 0, 1}]},
               {~c"utun4", [addr: {100, 64, 5, 20}]}
             ]) == "100.64.5.20"

      assert Host.tailscale_address([{~c"tailscale0", [addr: {100, 96, 1, 2}]}]) == "100.96.1.2"
    end

    test "knows where the /10 ends" do
      # The trap: 100.x.y.z reads like "the tailnet range" and most of it is not. The range
      # is 100.64 through 100.127, and ordinary routable space sits on both sides of it.
      assert Host.tailscale_address([{~c"en0", [addr: {100, 64, 0, 1}]}]) == "100.64.0.1"

      assert Host.tailscale_address([{~c"en0", [addr: {100, 127, 255, 254}]}]) ==
               "100.127.255.254"

      refute Host.tailscale_address([{~c"en0", [addr: {100, 63, 255, 255}]}])
      refute Host.tailscale_address([{~c"en0", [addr: {100, 128, 0, 1}]}])
      refute Host.tailscale_address([{~c"en0", [addr: {99, 64, 0, 1}]}])
      refute Host.tailscale_address([{~c"en0", [addr: {101, 64, 0, 1}]}])
    end

    test "ignores IPv6, which a node name has no room for" do
      refute Host.tailscale_address([
               {~c"utun4", [addr: {64_206, 0, 0, 0, 0, 0, 0, 1}]}
             ])
    end

    test "skips interfaces that have flags but no address" do
      assert Host.tailscale_address([
               {~c"gif0", [flags: [:up]]},
               {~c"utun4", [flags: [:up], addr: {100, 64, 5, 20}, netmask: {255, 255, 255, 255}]}
             ]) == "100.64.5.20"
    end

    test "nothing matching is nil, not a crash" do
      refute Host.tailscale_address([])
      refute Host.tailscale_address([{~c"lo0", [addr: {127, 0, 0, 1}]}])
    end
  end

  describe "local_hosts/0" do
    test "always offers loopback, and never offers it twice" do
      Application.put_env(:eva_core, :host, "127.0.0.1")
      Host.refresh()

      assert Host.local_hosts() == ["127.0.0.1"]
    end

    test "offers this machine's own address alongside it when there is a distinct one" do
      Application.put_env(:eva_core, :host, "100.64.5.20")
      Host.refresh()

      assert Host.local_hosts() == ["127.0.0.1", "100.64.5.20"]
    end
  end

  describe "ip/1" do
    test "parses an address" do
      assert Host.ip("100.64.5.20") == {:ok, {100, 64, 5, 20}}
      assert Host.ip("127.0.0.1") == {:ok, {127, 0, 0, 1}}
    end

    test "resolves a name, so EVA_HOST can be one" do
      assert Host.ip("localhost") == {:ok, {127, 0, 0, 1}}
    end

    test "fails rather than guessing, so a listener is never bound somewhere unintended" do
      assert {:error, _reason} = Host.ip("no-such-host.invalid")
    end
  end

  describe "current/0" do
    test "caches, so two callers cannot disagree about what this machine is called" do
      Application.put_env(:eva_core, :host, "10.0.0.1")
      assert Host.hostname() == "10.0.0.1"

      Application.put_env(:eva_core, :host, "10.0.0.2")
      assert Host.hostname() == "10.0.0.1"
      assert Host.refresh() == {"10.0.0.2", :config}
      assert Host.hostname() == "10.0.0.2"
    end
  end
end
