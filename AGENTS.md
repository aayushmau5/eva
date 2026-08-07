# AGENTS.md

## Before Committing / After Writing Code

Always run `mix precommit` after code changes are complete and before committing. This catches compile warnings, unused deps, formatting issues, and test failures in one pass.

## Packages

Two Mix projects live here, and the boundary between them is a namespace:

| | | |
|---|---|---|
| `.` | `:eva` | the host — sessions, the agent loop, providers, tools, extension loading |
| `core/` | `:eva_core` | the contract an extension is written against |

Everything in `core/` is `Eva.Core.*` and lives under `core/lib/eva/core/`. Everything in
the host is `Eva.*`. So `Eva.Core.Bus` and `Eva.Core.Extension.Spec` are contract;
`Eva.Extension.Loader` and `Eva.Cluster` are host. **The two interleave** — `Eva.Agent.*`,
`Eva.Cluster.*` and `Eva.Extension.*` each have modules on both sides — so when renaming or
moving anything in those trees, check which package owns it rather than matching a prefix.

The one namespace that is neither: `Eva.Extension.<Name>` is where an *extension itself*
must live (`Eva.Core.Extension.namespace/1` enforces it). Third-party code, not core's.

Extensions are separate repos. MCP is at `../eva-mcp` and depends on `eva_core` through a
sparse git checkout of `core/`; set `EVA_CORE_PATH` there to build it against a local Eva.
`test/eva/mcp_node_test.exs` is the only test that crosses into it, and skips if it is
absent.

## Architecture

Keep modules cohesive — each module does one thing well. `StreamState` owns SSE buffering and delta accumulation; `OpenAICompatible` owns the GenServer lifecycle and HTTP streaming for Open-AI compatible APIs; `Sse` owns raw SSE line parsing. Don't cram unrelated concerns into one module.

Code flows through functions. Prefer Elixir's control-flow constructs — `with`, `case`, `cond`, `Enum.reduce/3`, and the pipe operator — over deeply nested `if`/`else`.
