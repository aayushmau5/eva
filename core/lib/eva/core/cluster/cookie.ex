defmodule Eva.Core.Cluster.Cookie do
  @moduledoc """
  Eva's own cluster secret, kept apart from the machine's Erlang cookie.

  Erlang's trust boundary is the cookie. On one machine `~/.erlang.cookie` is fine — both
  VMs run as the same user. Across machines that sentence is false: different files,
  possibly different users.

  The obvious fix is to copy `~/.erlang.cookie` between machines, and it is a bad one. That
  file is every BEAM's cookie, so sharing it hands *every* unrelated Erlang program on both
  machines full code execution inside Eva. So Eva keeps its own:

      ~/.eva/cookie   mode 0600, generated the first time distribution comes up

  Set `config :eva_core, :cookie_path` or `EVA_COOKIE_PATH` when several OS processes
  need an isolated shared cookie, such as an integration test.

  **anyone with this file can run code on any member that listens.**
  The tailnet is the perimeter; this is the credential.

  ## Set after distribution, not before

  `:erlang.set_cookie/1` raises `:distribution_not_started` on a VM that is not yet a node,
  so it cannot be done first. `Eva.Core.Cluster.Listener` sets it immediately after
  `:net_kernel.start` returns.
  """

  import Bitwise, only: [&&&: 2]

  require Logger

  @dir "~/.eva"
  @filename "cookie"

  @doc """
  Where the cookie lives.
  """
  @spec path() :: String.t()
  def path do
    case Application.get_env(:eva_core, :cookie_path) do
      path when is_binary(path) and path != "" -> path
      _unset -> configured_path()
    end
  end

  @doc """
  Reads the cluster cookie, writing a fresh one if there is not one yet.
  """
  @spec ensure() :: {:ok, atom()} | {:error, term()}
  def ensure do
    path = path()

    case File.read(path) do
      {:ok, contents} -> from_file(path, contents)
      {:error, :enoent} -> generate(path)
      {:error, reason} -> {:error, {:unreadable, path, reason}}
    end
  end

  @doc """
  Makes the cluster cookie(present in a file) this VM's cookie. Requires distribution to be up already.
  """
  @spec apply() :: :ok | {:error, term()}
  def apply do
    with {:ok, cookie} <- ensure() do
      Node.set_cookie(cookie)
      :ok
    end
  end

  @doc """
  Writes a cookie handed over from another machine, replacing any already here.

  Replacing is the point — two machines only share a cluster if they share this.
  """
  @spec write(String.t()) :: :ok | {:error, term()}
  def write(cookie) when is_binary(cookie) do
    if valid?(cookie), do: store(path(), cookie), else: {:error, :not_a_cookie}
  end

  # -- Private --

  defp configured_path do
    case System.get_env("EVA_COOKIE_PATH") do
      path when is_binary(path) and path != "" -> Path.expand(path)
      _unset -> @dir |> Path.expand() |> Path.join(@filename)
    end
  end

  defp from_file(path, contents) do
    cookie = String.trim(contents)

    if valid?(cookie) do
      warn_if_readable(path)
      {:ok, String.to_atom(cookie)}
    else
      {:error, {:not_a_cookie, path}}
    end
  end

  defp generate(path) do
    cookie = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)

    with :ok <- store(path, cookie) do
      Logger.info("wrote a new cluster cookie to #{path}")
      {:ok, String.to_atom(cookie)}
    end
  end

  defp store(path, cookie) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, cookie),
         :ok <- File.chmod(path, 0o600) do
      :ok
    else
      {:error, reason} -> {:error, {:unwritable, path, reason}}
    end
  end

  # Cookies are atoms, so anything that is not printable would be unusable as one. Length
  # is bounded because atoms are.
  defp valid?(cookie) do
    cookie != "" and byte_size(cookie) <= 255 and String.printable?(cookie) and
      not String.contains?(cookie, ["\n", " "])
  end

  defp warn_if_readable(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} when (mode &&& 0o077) != 0 ->
        Logger.warning("#{path} is readable by others — anyone reading it can run code here")

      _fine ->
        :ok
    end
  end
end
