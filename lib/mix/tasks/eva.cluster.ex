defmodule Mix.Tasks.Eva.Cluster.Invite do
  @shortdoc "Prints a token another machine can join this cluster with"

  @moduledoc """
  Prints a join token for this machine's cluster.

      mix eva.cluster.invite

  The token carries the cluster cookie, which is the credential for running code on any
  member that listens. Hand it over the way you would a password — not in a pull request,
  not in a chat channel that logs.

  It does *not* carry an address. Where an extension lives is a separate decision, made on
  the Eva that wants to use it with `mix eva.ext.remote <name> <host>:<port>`. Keeping them
  apart means an invite can be reused for a second extension without re-issuing anything.
  """

  use Mix.Task

  alias Eva.Core.Cluster.Cookie

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    case Cookie.ensure() do
      {:ok, cookie} ->
        Mix.shell().info([IO.ANSI.bright(), token(cookie), IO.ANSI.reset()])

        Mix.shell().info([
          IO.ANSI.faint(),
          "\non the other machine: mix eva.cluster.join <token>",
          IO.ANSI.reset()
        ])

      {:error, reason} ->
        Mix.raise("could not read the cluster cookie: #{inspect(reason)}")
    end
  end

  defp token(cookie) do
    Base.url_encode64(JSON.encode!(%{"cookie" => Atom.to_string(cookie)}), padding: false)
  end
end

defmodule Mix.Tasks.Eva.Cluster.Join do
  @shortdoc "Joins the cluster an invite token came from"

  @moduledoc """
  Writes the cluster cookie from an invite token.

      mix eva.cluster.join <token>

  Replaces whatever cookie this machine had for Eva. That is the point — two machines are
  in one cluster exactly when they hold the same secret.

  Nothing connects as a result. This machine's extension nodes become *joinable* by the
  Eva that issued the invite, once that Eva is told where they are.
  """

  use Mix.Task

  alias Eva.Core.Cluster.Cookie

  @impl true
  def run([token]) do
    Mix.Task.run("app.start")

    with {:ok, json} <- Base.url_decode64(token, padding: false),
         {:ok, %{"cookie" => cookie}} <- JSON.decode(json),
         :ok <- Cookie.write(cookie) do
      Mix.shell().info("joined — cookie written to #{Cookie.path()}")

      Mix.shell().info([
        IO.ANSI.faint(),
        "anyone who can read that file can run code here\n",
        "restart any extension node already running: the cookie is read once, at startup",
        IO.ANSI.reset()
      ])
    else
      {:error, reason} -> Mix.raise("could not join: #{inspect(reason)}")
      _other -> Mix.raise("that does not look like an invite token")
    end
  end

  def run(_args), do: Mix.raise("usage: mix eva.cluster.join <token>")
end
