defmodule Eva.Cluster.Epmd do
  @moduledoc """
  Where a configured node lives, answered from the registry instead of from epmd.

  epmd is a phone book with one entry per machine. Nothing on another machine can
  read it, and nothing should have to: a registry entry already says the name, the host and
  the port, which is everything a dial needs.

  So this replaces the VM's epmd *client*. Names we have an entry for are answered from it;
  everything else falls through to `:erl_epmd`, so local extension nodes keep working
  exactly as they did.

  ## What Erlang actually calls

  Dialling goes through `address_please/3`. Returning `{:ok, ip, port, version}` ends it
  there — `port_please/2` is never reached. That is why the port can be per-name here,
  which `ERL_EPMD_PORT` could never do: it is one global "everybody is on this port".

  ## Two traps

  **The module has to be loaded before the first dial.** OTP checks
  `function_exported/3` before calling us, and that is `false` for a module that is merely
  loadable. It then falls back to `:erl_epmd` **silently** — the dial succeeds against the
  wrong port, or fails for no stated reason. `install/1` loads it first, deliberately.

  **Registering is still epmd's job.** We only answer questions; `register_node/3` is
  passed straight through, so this VM still appears in `epmd -names` like anything else.
  """

  alias Eva.Coding.Resources
  alias Eva.Core.Extension.Node, as: ExtensionNode
  alias Eva.Extension.Registry

  @routes {__MODULE__, :routes}

  # `ERL_DIST_VER_6` in kernel's `dist.hrl`, and both the low and high water mark since
  # OTP 23. A configured node has no epmd to tell us, so it is stated.
  @dist_version 6

  @doc """
  Makes this the VM's epmd client and loads the routes from the registry.

  Safe to call again — that is how a registry edited while Eva is running takes effect.
  """
  @spec install(Resources.t()) :: :ok
  def install(%Resources{} = resources) do
    {:module, __MODULE__} = Code.ensure_loaded(__MODULE__)

    # Erlang resolves node names via an :epmd_module.
    # Erlang gives you no way to say "connect to this IP at this port."
    # Every operation — Node.connect, :erpc.call, Process.monitor across nodes —
    # takes a name like :"mcp@100.64.5.20". The VM then has to resolve that name
    # into {ip, port} before it can dial, and the only mechanism it uses for that resolution is epmd.
    # There's no public API to dial by raw address.
    # So for a remote extension you have exactly one knob to turn: make the name→address resolution step
    # return the right port. And the one sanctioned extension point for that is the :epmd_module config
    # (swapping in your own module that implements address_please).
    Application.put_env(:kernel, :epmd_module, __MODULE__)

    put(routes_from(resources))
  end

  @doc """
  Replaces the routes: `%{{name, host} => port}`, both strings.
  """
  @spec put(%{{String.t(), String.t()} => :inet.port_number()}) :: :ok
  def put(routes) when is_map(routes) do
    # `:persistent_term.put` is no-op if the new values are same as previous values
    # FYI: this triggers global GC
    :persistent_term.put(@routes, routes)
  end

  @doc """
  The routes currently in force.
  """
  @spec routes() :: %{{String.t(), String.t()} => :inet.port_number()}
  def routes, do: :persistent_term.get(@routes, %{})

  @doc """
  The routes a registry implies. One per remote entry.
  """
  @spec routes_from(Resources.t()) :: %{{String.t(), String.t()} => :inet.port_number()}
  def routes_from(%Resources{} = resources) do
    for entry <- Registry.remote(resources),
        into: %{},
        do: {{ExtensionNode.epmd_name(entry["name"]), entry["host"]}, entry["port"]}
  end

  # -- epmd client callbacks --

  @doc false
  def address_please(name, host, family) do
    case Map.fetch(routes(), {stringify(name), stringify(host)}) do
      {:ok, port} ->
        case :inet.getaddr(host, family) do
          {:ok, ip} -> {:ok, ip, port, @dist_version}
          error -> error
        end

      :error ->
        :erl_epmd.address_please(name, host, family)
    end
  end

  @doc false
  def port_please(name, host), do: :erl_epmd.port_please(name, host)

  @doc false
  def names(host), do: :erl_epmd.names(host)

  @doc false
  def register_node(name, port), do: :erl_epmd.register_node(name, port)

  @doc false
  def register_node(name, port, family), do: :erl_epmd.register_node(name, port, family)

  # -- Private --

  # Erlang hands these over as charlists, and a host can arrive already resolved.
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_list(value), do: List.to_string(value)
  defp stringify(value) when is_tuple(value), do: value |> :inet.ntoa() |> List.to_string()
end
