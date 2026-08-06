# eva_mcp

MCP servers for Eva, as an extension.

This was part of Eva itself until the extension contract could carry it. It is an
**inline project extension**: a real Mix project, compiled ahead of time, loaded from its
prebuilt beams into Eva's VM.

## Install

```bash
mix eva.ext.add ext/mcp
```

Then restart the session. `mix eva.ext.list` shows it; `mix eva.ext.build mcp` rebuilds it
after a change (project extensions do not hot-reload — Eva will tell you when a rebuild is
waiting for a restart).

## Use

Servers are configured exactly as before, in `~/.eva/mcp.json` or `<project>/.eva/mcp.json`:

```json
{
  "mcpServers": {
    "filesystem": { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "."] },
    "docs": { "url": "https://example.com/mcp" }
  }
}
```

```
/mcp                              list servers, status and tool counts
/mcp enable <server>              for this session
/mcp disable <server>
/mcp enable <server> --persist    write it back to the mcp.json it came from
```

A session-scoped toggle is remembered in the transcript, so it survives a resume and
leaves other sessions alone. `--persist` edits the config file instead.

## Why it is `inline` and not a node

`finch` and `erlexec` are declared so this compiles, but they are *peer* dependencies: the
host has both loaded, and only this project's own `ebin` goes on the code path, so there
is one copy of each. `eva: [isolation: :inline]` in `mix.exs` is that assertion — without
it, the isolation inference would see third-party deps and ask for a node.

The usual reason for a node does not apply here anyway: MCP servers are already separate
OS processes under erlexec, so the isolation is where it matters.

## Layout

| | |
|---|---|
| `mcp.ex` | the extension — commands, tool publishing, event republishing |
| `servers.ex` | the servers one session is using, and the `:pg` refcount |
| `client.ex` | one MCP server connection, shared across sessions |
| `config.ex` | `mcp.json`, both scopes |
| `protocol.ex`, `transport/` | JSON-RPC, stdio and streamable HTTP |
| `application.ex` | Finch, task supervisor, registry, client supervisor |
