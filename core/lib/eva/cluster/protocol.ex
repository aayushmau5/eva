defmodule Eva.Cluster.Protocol do
  @moduledoc """
  What a node says when it joins, and what it can be told in reply.

  Both halves compile against this: the host runs the directory, the joining node runs the
  client, and neither names a module belonging to the other. As with `Eva.Extension.API`,
  **the shapes here are the contract** — changing one is a breaking change even when the
  function signature stays the same.

  The host's directory is addressed by registered name, so a joining node needs no pid and
  no module from the host — `{Protocol.directory(), eva_node}` is enough.
  """

  use TypedStruct

  @protocol_version 1

  @directory Eva.Cluster

  @typedoc """
  What a member claims to be.

  `:extension` contributes tools, hooks and commands to sessions. `:harness` is another Eva
  offering to run agent turns(not built yet).
  """
  @type role :: :extension | :harness

  @typedoc "Why the host refused to let a member join."
  @type refusal ::
          {:protocol_version, mine :: pos_integer(), theirs :: pos_integer()}
          | {:core_version, mine :: String.t(), theirs :: String.t()}
          | {:name_taken, node()}
          | :not_allowed
          | {:unknown_role, term()}

  typedstruct module: Announcement do
    @moduledoc """
    Sent once per node.

    `pid` is the member's own process — the host monitors it, and calls back to it to
    instantiate the member for a particular session.
    """

    field :protocol_version, pos_integer()
    field :role, Eva.Cluster.Protocol.role()
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
  The registered name of the host's directory.
  """
  @spec directory() :: atom()
  def directory, do: @directory

  @doc """
  Builds an announcement for this node.
  """
  @spec announcement(role(), String.t(), pid()) :: Announcement.t()
  def announcement(role, name, pid) when is_atom(role) and is_binary(name) and is_pid(pid) do
    %Announcement{
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
    do: "another node (#{node}) has already announced that name"

  def describe_refusal(:not_allowed),
    do: "not in the host's allowlist — add it with mix eva.ext.add"

  def describe_refusal({:unknown_role, role}), do: "unknown role #{inspect(role)}"
  def describe_refusal(other), do: inspect(other)
end
