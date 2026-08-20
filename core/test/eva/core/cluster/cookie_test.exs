defmodule Eva.Core.Cluster.CookieTest do
  @moduledoc """
  Eva's cluster secret: generated once, kept private, replaceable from an invite.
  """

  use ExUnit.Case, async: false

  import Bitwise, only: [&&&: 2]

  alias Eva.Core.Cluster.Cookie

  setup do
    dir = Path.join(System.tmp_dir!(), "cookie_#{System.unique_integer([:positive])}")
    path = Path.join(dir, "cookie")
    previous = Application.get_env(:eva_core, :cookie_path)
    previous_env = System.get_env("EVA_COOKIE_PATH")

    Application.put_env(:eva_core, :cookie_path, path)
    System.delete_env("EVA_COOKIE_PATH")

    on_exit(fn ->
      File.rm_rf!(dir)

      if previous,
        do: Application.put_env(:eva_core, :cookie_path, previous),
        else: Application.delete_env(:eva_core, :cookie_path)

      if previous_env,
        do: System.put_env("EVA_COOKIE_PATH", previous_env),
        else: System.delete_env("EVA_COOKIE_PATH")
    end)

    %{path: path}
  end

  test "is generated on first use and kept afterwards", %{path: path} do
    assert {:ok, first} = Cookie.ensure()
    assert is_atom(first)
    assert File.exists?(path)

    assert {:ok, ^first} = Cookie.ensure()
  end

  test "can take an isolated cookie path from the environment" do
    Application.delete_env(:eva_core, :cookie_path)
    path = Path.join(System.tmp_dir!(), "cookie_env_#{System.unique_integer([:positive])}")
    System.put_env("EVA_COOKIE_PATH", path)

    assert Cookie.path() == path
    assert {:ok, _cookie} = Cookie.ensure()
    assert File.exists?(path)

    File.rm!(path)
  end

  test "is not the machine's Erlang cookie" do
    # The whole reason this exists. Sharing `~/.erlang.cookie` between machines would hand
    # every unrelated BEAM on both of them code execution inside Eva.
    {:ok, ours} = Cookie.ensure()

    assert Atom.to_string(ours) != File.read!(Path.expand("~/.erlang.cookie")) |> String.trim()
  end

  test "is unguessable, and long enough to stay that way" do
    {:ok, cookie} = Cookie.ensure()

    assert String.length(Atom.to_string(cookie)) >= 32
  end

  test "is written so only its owner can read it", %{path: path} do
    {:ok, _cookie} = Cookie.ensure()

    assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
    assert (mode &&& 0o077) == 0
  end

  describe "write/1" do
    test "replaces what was there, which is how two machines end up in one cluster",
         %{path: path} do
      {:ok, generated} = Cookie.ensure()

      :ok = Cookie.write("handed-over-secret")

      assert {:ok, :"handed-over-secret"} = Cookie.ensure()
      refute Atom.to_string(generated) == File.read!(path)
    end

    test "narrows the permissions on what it writes too", %{path: path} do
      :ok = Cookie.write("handed-over-secret")

      assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
      assert (mode &&& 0o077) == 0
    end

    test "refuses something that could not be a cookie" do
      # Cookies are atoms. Anything with whitespace in it would have been mangled by the
      # file round-trip rather than failing outright, which is worse.
      assert Cookie.write("") == {:error, :not_a_cookie}
      assert Cookie.write("two words") == {:error, :not_a_cookie}
      assert Cookie.write("with\nnewline") == {:error, :not_a_cookie}
    end
  end

  test "a file with nothing usable in it is an error, not a silent default", %{path: path} do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "   \n")

    assert {:error, {:not_a_cookie, ^path}} = Cookie.ensure()
  end
end
