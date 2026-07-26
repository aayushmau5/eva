# AGENTS.md

## Before Committing / After Writing Code

Always run `mix precommit` after code changes are complete and before committing. This catches compile warnings, unused deps, formatting issues, and test failures in one pass.

## Architecture

Keep modules cohesive — each module does one thing well. `StreamState` owns SSE buffering and delta accumulation; `OpenAICompatible` owns the GenServer lifecycle and HTTP streaming for Open-AI compatible APIs; `Sse` owns raw SSE line parsing. Don't cram unrelated concerns into one module.

Code flows through functions. Prefer Elixir's control-flow constructs — `with`, `case`, `cond`, `Enum.reduce/3`, and the pipe operator — over deeply nested `if`/`else`.
