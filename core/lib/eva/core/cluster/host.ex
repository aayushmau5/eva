defmodule Eva.Core.Cluster.Host do
  @moduledoc """
  What address(host) this machine goes by.

  ## Ordering of host

  Explicit config, then `EVA_HOST`, then a Tailscale address, then loopback.

  ## To know

  The interface is `tailscale0` on Linux and some `utunN` on macOS, where the number moves.
  The only static part is the range: `100.64.0.0/10`, `:inet.getifaddrs/0` is scanned for
  an address in that range.

  Only IPv4 is matched. Tailscale also assigns IPv6, but we are not handling it right now.

  ## Caching

  The resolved host is cached, so two callers cannot disagree about what this machine is
  called. `refresh/0` re-resolves — a node name is fixed for as long as distribution stays
  up, but distribution can be taken down and brought back, which is the only way an address
  that appeared late (like tailscale start after Eva) can ever be picked up.
  """

  @loopback "127.0.0.1"

  @typedoc "Where the host resolution came from. `:loopback` means nothing else answered."
  @type source :: :config | :env | :tailscale | :loopback

  @spec hostname() :: String.t()
  def hostname, do: elem(current(), 0)

  @doc """
  How `hostname/0` was decided.
  """
  @spec source() :: source()
  def source, do: elem(current(), 1)

  @spec current() :: {String.t(), source()}
  def current do
    case :persistent_term.get(__MODULE__, nil) do
      nil -> refresh()
      cached -> cached
    end
  end

  @doc """
  Resolves again and replaces the cached answer.

  Only meaningful alongside restarting distribution. A name already given to
  `:net_kernel.start/2` does not change because this did.
  """
  @spec refresh() :: {String.t(), source()}
  def refresh do
    resolved = resolve()
    :persistent_term.put(__MODULE__, resolved)
    resolved
  end

  @doc """
  Resolves without touching the cache.
  """
  @spec resolve() :: {String.t(), source()}
  def resolve do
    cond do
      host = configured() -> {host, :config}
      host = from_env() -> {host, :env}
      host = tailscale_address(interfaces()) -> {host, :tailscale}
      true -> {@loopback, :loopback}
    end
  end

  @doc """
  Loopback, and this machine's own address when it has a distinct one.

  For building a candidate node name out of a bare name from epmd (epmd returns short names only).
  Local nodes are named for where they listen, and a node on this machine that made itself reachable is
  `name@100.64.5.20` while its neighbour is `name@127.0.0.1` — the short name epmd hands
  back cannot tell them apart, so both spellings have to be tried.
  """
  @spec local_hosts() :: [String.t()]
  def local_hosts, do: Enum.uniq([@loopback, hostname()])

  @doc """
  The loopback address.
  """
  @spec loopback() :: String.t()
  def loopback, do: @loopback

  @doc """
  A host as an IP tuple, which is what `:inet_dist_use_interface` wants.

  A name rather than an address is resolved, so `EVA_HOST=devbox.example.com` works — but
  it has to resolve to something.
  """
  @spec ip(String.t()) :: {:ok, :inet.ip_address()} | {:error, term()}
  def ip(host) when is_binary(host) do
    charlist = String.to_charlist(host)

    case :inet.parse_address(charlist) do
      {:ok, address} -> {:ok, address}
      {:error, :einval} -> :inet.getaddr(charlist, :inet)
    end
  end

  @doc """
  The first `100.64.0.0/10` address in a `:inet.getifaddrs/0` result, or `nil`.
  """
  @spec tailscale_address([{charlist(), keyword()}]) :: String.t() | nil
  def tailscale_address(interfaces) do
    Enum.find_value(interfaces, fn {_name, options} ->
      Enum.find_value(options, fn
        {:addr, {100, b, _, _} = address} when b >= 64 and b <= 127 ->
          address |> :inet.ntoa() |> List.to_string()

        _other ->
          nil
      end)
    end)
  end

  # -- Private --

  defp configured do
    case Application.get_env(:eva_core, :host) do
      host when is_binary(host) and host != "" -> host
      _unset -> nil
    end
  end

  defp from_env do
    case System.get_env("EVA_HOST") do
      host when is_binary(host) and host != "" -> host
      _unset -> nil
    end
  end

  defp interfaces do
    case :inet.getifaddrs() do
      {:ok, interfaces} -> interfaces
      _other -> []
    end
  end
end
