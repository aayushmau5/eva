---
name: write-extension-remote
description: Write an Eva extension that runs on another machine — a Mix project node offered to your tailnet with a port and a serve list. Use when asked to create, modify, or debug an Eva extension that runs remotely.
---

# Writing a remote Eva extension

A remote extension is a project extension that runs on another machine. The contract is
identical to a local one — same `setup/1`, same `%Spec{}`, same callbacks, same `API`, same
module namespace. Read the `write-extension-local` skill for all of that. This skill covers
what is different about running one elsewhere:

1. how the node offers itself to other machines (`:port`, `:serve`)
2. how the two machines agree on a secret (the cluster cookie)
3. how the session's Eva is pointed at it (`mix eva.ext.remote`)
4. what changes in the code you write (paths, and tool/command names)

## When it is remote

Only projects, and only if you ask for it. A script (`.exs`) always compiles into the
session's own VM and can never run on another machine. A project node is loopback-only
until you pass `:port`, so "remote" is one option, not a different kind of extension.

The scaffolding is the same as any project — a `mix.exs` depending on `eva_core`, and an
application that starts `Eva.Core.Extension.Node` (see `write-extension-local`). Only the
node's options change:

```elixir
children = [
  {Eva.Core.Extension.Node,
   name: "gpu",
   module: Eva.Extension.Gpu,
   port: 9001,                                   # offer this node to your tailnet
   serve: [:"eva_4711_100_64_5_20@127.0.0.1"]}   # ...to these Evas only
]
```

**`:port` is the whole of "another machine may dial me".** It picks the interface, the port,
and the node's name together — the node names itself for this machine's address and listens
on exactly that port. Without it, the node listens on loopback and only its own machine can
see it.

**`:serve` is your veto over who gets answered.** Being dialable means anything reaching the
cookie can ask this node to instantiate an extension; `:serve` names the Evas that get an
answer. It defaults to `:any`, which is right for a loopback-only node — everything able to
reach it is already you, on your own machine. Being listed in someone else's config cannot
open a socket here. Eva names itself `eva_<pid>@<host>`, which is what an entry here matches.

### Which address the node uses

To be reachable, the node has to name itself for an address another machine can reach. It
resolves one in this order: `config :eva_core, :host`, then the `EVA_HOST` environment
variable, then the first Tailscale address (`100.64.0.0/10`). If none of those exist,
starting with `:port` fails and says so — there is no address to be reachable at.

## The cookie — the trust boundary

Two machines are in one cluster exactly when they hold the same secret, and that secret is
Eva's own cluster cookie at `~/.eva/cookie` (mode 0600) — deliberately **not** the Erlang
cookie in `~/.erlang.cookie`, which every BEAM on the machine can read. **Anyone with the
cookie can run code on any member that listens.** Treat it like a password: not in a pull
request, not in a logged chat.

Share it by issuing an invite on one machine and joining on the other:

```bash
mix eva.cluster.invite          # prints a token
mix eva.cluster.join <token>    # on the other machine; restart nodes already running
```

The token carries the cookie and nothing else — not an address. Where an extension lives is
a separate decision (below), so one invite serves every extension between those two
machines.

## Pointing Eva at it

On the machine whose Eva will use the extension:

```bash
mix eva.ext.remote gpu 100.64.5.20:9001
mix eva.ext.remote gpu 100.64.5.20:9001 --machine devbox
```

That records where to dial — a `{"name" => "gpu", "kind" => "remote", "host" => …,
"port" => …}` entry — and nothing else. `--machine` is optional and names the machine in a
way a person can read; without it Eva slugs the address, so commands are typed
`/100_64_5_20__deploy` rather than `/devbox__deploy`. Nothing is started or checked; the
other machine may be asleep. There is no epmd to ask on another machine, which is why the
port has to be written down: Eva dials that address directly.

Two things on the Eva side have to be true for the dial to happen:

- **Distribution must be on.** `config :eva, distribution: true`. It is off by default — a
  user with no node extensions should never have a socket.
- **The name must be registered.** The registry is the allowlist: a node nobody registered
  never gets taken on, even if it reaches the cookie. `mix eva.ext.add` (local) and
  `mix eva.ext.remote` (remote) are both the registration *and* the trust decision.

`mix eva.ext.start` and `stop` refuse a remote entry — running commands on a machine you
don't own is not something Eva does. Start the node *there*, yourself.

## The two things that change for your code

### Your paths are not the session's paths

`ctx.cwd` describes the machine the *session* runs on. On a remote node, opening it will not
fail — it will open a different file with the same name, or nothing, and the model will
reason confidently about the wrong contents. So check rather than assume:

```elixir
alias Eva.Core.Extension.Context

executor: fn args, _exec_ctx ->
  unless Context.same_machine?(ctx) do
    raise "this tool reads the project directory, and #{ctx.name} runs on #{ctx.machine}"
  end

  File.read!(Path.join(ctx.cwd, args["path"]))
end
```

`Context.same_machine?/1` is true only when `ctx.machine` is `nil`. `cwd` and `entries` are
still populated on purpose — an extension may legitimately want to know what the session is
*about* — they are just not yours to open. `extension_dir` is `nil` on a remote node.

To genuinely reach the session's machine, go through `ctx.capabilities`, which forwards to
wherever the session is — that is how `ask` and `spawn_agent` already work.

### Your tool and command names get a prefix

A remote extension's `read_file` is offered to the model as `<machine>__read_file`, and
`/deploy` is typed `/<machine>__deploy`. You write them unqualified; Eva adds the machine
label — a slug of the host (`100.64.5.20` becomes `100_64_5_20`), or a friendlier
`"machine"` value you give to `mix eva.ext.remote --machine` (or put straight in the
registry entry). The far side never sees the prefix.

This is deliberate even when nothing collides — a name is what the model actually types, so
it is where "this runs somewhere else" has to be said. It also means the same extension on
two machines is two separate extensions, with no collision between them.

## If Eva won't take the node on

A refused node is logged once, with the reason:

| Refusal | Meaning |
|---|---|
| built against eva_core X, host is running Y | the node was compiled against a different contract — rebuild it |
| another node is already serving that name | two VMs on the *same* machine claim one name |
| not in the host's allowlist | `mix eva.ext.add` / `mix eva.ext.remote` was never run |
| could not be reached | it is not running, the port is wrong, or the cookies don't match |
| the node declined to serve this Eva | this Eva is not in the node's `:serve` list |

## Before you finish

- **Verify it was taken on.** `Eva.Cluster.members(:extension)` lists connected members with
  a `machine` label; `Eva.Cluster.refusals/0` shows what was refused and why.
- **`@impl true` on every callback**, a unique module name, and never crash `setup/1` — the
  same rules as any extension.
- **Restart the node after joining a cluster.** The cookie is read once, at startup.
