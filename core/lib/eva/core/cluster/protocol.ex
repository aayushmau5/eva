defmodule Eva.Core.Cluster.Protocol do
  @moduledoc """
  What a node says about itself when asked, and why a host might not want it.

  ## Asked, not told

  Eva dials and asks; a node never goes looking for an Eva. So a `Description` is a reply,
  and the refusals below are checked by the host *after* asking.
  """

  use TypedStruct

  @protocol_version 1

  @typedoc """
  What a member claims to be.

  `:extension` contributes tools, hooks and commands to sessions. `:harness` is another Eva
  offering to run agent turns(not built yet).
  """
  @type role :: :extension | :harness

  @typedoc """
  Why a host would not take a member on.

  `:not_consented` is the only one decided by the *other* side — the node declining to
  serve this Eva.
  """
  @type refusal ::
          {:protocol_version, mine :: pos_integer(), theirs :: pos_integer()}
          | {:core_version, mine :: String.t(), theirs :: String.t()}
          | {:name_taken, node()}
          | :not_allowed
          | :not_consented
          | {:unknown_role, term()}
          | {:unreachable, term()}

  typedstruct module: Description do
    @moduledoc """
    What a node answers when Eva asks what it is.

    `pid` is the member's own process — the Eva host monitors it, and calls back to it to
    instantiate the member for a particular session.
    """

    field :protocol_version, pos_integer()
    field :role, Eva.Core.Cluster.Protocol.role()
    field :name, String.t()
    field :core_version, String.t()
    field :node, node()
    field :pid, pid()
  end

  @doc """
  The version of this protocol. Bumped when a shape here changes incompatibly.
  """
  @spec protocol_version() :: pos_integer()
  def protocol_version, do: @protocol_version

  @doc """
  Builds this node's description of itself.
  """
  @spec description(role(), String.t(), pid()) :: Description.t()
  def description(role, name, pid) when is_atom(role) and is_binary(name) and is_pid(pid) do
    %Description{
      protocol_version: @protocol_version,
      role: role,
      name: name,
      core_version: core_version(),
      node: node(),
      pid: pid
    }
  end

  @doc """
  The `eva_core` this VM is running.

  Structs are maps, so a member built against one version and a host running another
  produce maps with different keys — which surfaces as a pattern match failing somewhere
  unrelated to the cause. Comparing at the handshake is the cheapest place to catch it, and
  unlike a version recorded at build time this one cannot be stale.
  """
  @spec core_version() :: String.t()
  def core_version, do: Application.spec(:eva_core, :vsn) |> to_string()

  @doc """
  Turns a refusal into something worth reading in a terminal.
  """
  @spec describe_refusal(refusal()) :: String.t()
  def describe_refusal({:protocol_version, mine, theirs}),
    do: "cluster protocol #{theirs} cannot talk to #{mine} — upgrade whichever is older"

  def describe_refusal({:core_version, mine, theirs}),
    do: "built against eva_core #{theirs}, host is running #{mine}"

  def describe_refusal({:name_taken, node}),
    do: "another node (#{node}) is already serving that name"

  def describe_refusal(:not_allowed),
    do: "not in the host's allowlist — add it with mix eva.ext.add"

  def describe_refusal(:not_consented),
    do: "the node declined to serve this Eva — check its :serve list"

  def describe_refusal({:unknown_role, role}), do: "unknown role #{inspect(role)}"

  # A mismatched cookie looks exactly like a wrong port or a
  # node that is not running — the dialer is only told the connection failed.
  def describe_refusal({:unreachable, _reason}),
    do:
      "could not be reached — check it is running, the port matches, and both machines " <>
        "share a cluster cookie (mix eva.cluster.invite / join)"

  def describe_refusal(other), do: inspect(other)
end
