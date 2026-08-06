defmodule Eva.Extension.Trust do
  @moduledoc """
  Consent for running project-local extensions.

  A project extension directory is code from whoever wrote the repository, and it runs
  before the first prompt — so it does not load until the user says so. Consent is tied
  to the *contents*: editing an extension, or adding one, asks again.

  Global extensions (`<root>/extensions`, normally `~/.eva/extensions`) are exempt. The
  user put those there themselves, and so is an explicit `-e <path>`: naming a file on the
  command line is the consent.

  Example:
  ```
  {
    "extension_dirs": {
      "/Users/aayush/Code/my-project/.eva/extensions": {
        "content_hash": "a3f8b2c94d1e...",
        "approved_at": "2025-08-07T14:22:10.123456Z"
      },
      "/Users/aayush/Code/other-project/.eva/extensions": {
        "content_hash": "7d2e1f09a3b4...",
        "approved_at": "2025-08-06T09:15:30.654321Z"
      }
    }
  }
  ```
  """

  alias Eva.Coding.Resources

  @store "trust.json"
  @key "extension_dirs"

  @doc """
  Where consent is recorded — a sibling of `mcp.json` under the same root.
  """
  @spec store_path(Resources.t()) :: String.t()
  def store_path(%Resources{root: root}), do: Path.join(root, @store)

  @doc """
  Whether this directory may be loaded from.

  False for a directory that was never approved *and* for one whose contents changed
  since it was.
  """
  @spec trusted?(Resources.t(), String.t()) :: boolean()
  def trusted?(%Resources{} = resources, dir) do
    case get_in(read(resources), [@key, Path.expand(dir)]) do
      %{"content_hash" => hash} -> hash == content_hash(dir)
      _other -> false
    end
  end

  @doc """
  Records consent for a directory as it stands right now.
  """
  @spec trust(Resources.t(), String.t()) :: :ok | {:error, term()}
  def trust(%Resources{} = resources, dir) do
    dir = Path.expand(dir)

    entry = %{
      "content_hash" => content_hash(dir),
      "approved_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    resources
    |> read()
    |> put_in([@key, dir], entry)
    |> write(resources)
  end

  @doc """
  Forgets a directory, so it needs approving again.
  """
  @spec revoke(Resources.t(), String.t()) :: :ok | {:error, term()}
  def revoke(%Resources{} = resources, dir) do
    resources
    |> read()
    |> update_in([@key], &Map.delete(&1, Path.expand(dir)))
    |> write(resources)
  end

  @doc """
  A fingerprint of every extension file in the directory.

  Hashing contents rather than just the path is the point: approving
  `/repo/.eva/extensions` once must not silently approve whatever gets committed to it
  next week. Only `*.exs` counts — a README changing is not a reason to ask again.
  """
  @spec content_hash(String.t()) :: String.t()
  def content_hash(dir) do
    dir = Path.expand(dir)

    dir
    |> Path.join("**/*.exs")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.reduce(:crypto.hash_init(:sha256), fn file, acc ->
      relative = Path.relative_to(file, dir)

      case File.read(file) do
        {:ok, contents} -> :crypto.hash_update(acc, relative <> contents)
        # A file that vanished mid-hash still has to change the digest, or its removal
        # would go unnoticed.
        {:error, reason} -> :crypto.hash_update(acc, relative <> to_string(reason))
      end
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  # -- Private --

  defp read(%Resources{} = resources) do
    with {:ok, binary} <- File.read(store_path(resources)),
         {:ok, %{} = json} <- JSON.decode(binary) do
      Map.put_new(json, @key, %{})
    else
      _other -> %{@key => %{}}
    end
  end

  # Temp-then-rename
  defp write(store, %Resources{} = resources) do
    path = store_path(resources)
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, :json.format(store)) do
      File.rename(tmp, path)
    end
  end
end
