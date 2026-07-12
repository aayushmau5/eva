# Eva

![shinji](./shinji.jpg)

A coding harness built in Elixir, inspired by [tau](https://twotimespi.dev/).

> Work in progress — things may move, break, and change.

![under construction](https://cyber.dabamos.de/88x31/construction.gif)

# Idea

Current ideas, subject to change.

## Architecture

Eva is a distributed coding agent platform. It ships with a default terminal agent harness powered by `ex_ratatui` + BYO-FE, with a modular architecture that lets you swap out providers and frontends.

## Feature Checklist

- [ ] Distributed architecture
  - [ ] How do we discover & connect to Evas in different machines?
    - [ ] Tailscale?
      - [ ] Most of the work is already done(Security, Discovery & Connection)
      - [ ] Connections & Creds management
    - [ ] Iroh?
  - [ ] At what point do we handle external node messages?
    - [ ] Split between:
      - [ ] Providers
      - [ ] Harness
- [x] Very basic provider(currently LMStudio based API only)
  - [ ] Handle envs & config
  - [ ] Switch providers
- [ ] Agent Harness
  - [x] The agent loop
  - [ ] Handling distributed node messages
  - [ ] Context
    - [x] Sessions
    - [ ] Memory
    - [ ] Compaction
  - [x] Prompts
    - [x] Follow-up
    - [x] Queue
    - [ ] Assembling prompts
  - [ ] Tools
    - [ ] Tool calls
      - [ ] Elixir native?
      - [x] read
      - [x] write
      - [x] edit
      - [x] bash
        - [ ] Explore just-bash(https://github.com/elixir-ai-tools/just_bash) for bash interpreter(& virtual FS)
      - [ ] Q/A
      - [ ] Web search/fetch
  - [ ] Subagents
  - [ ] Modes or Characters(?)(like amp)
    - [ ] Deep
    - [ ] Librarian
    - [ ] Oracle
  - [ ] Extensions
    - [ ] Perhpas "sharing" as an extension
  - [ ] Ability to modify itself
    - [ ] With Hot reload?
  - [ ] Sharing(login?)
    - [ ] Atproto
      - [ ] PDS as sync layer(inspired by tiles.run)?
    - (Fun idea): Indieweb?
  - (Experiment): Explore with mob as distributed node connection?
- [ ] TUI (`ex_ratatui`) + BYO-FE
  - [ ] Slash commands (`/usage`, `/providers`, `/login`, `/logout`, ...)
  - [ ] Pretty lil animations
- [ ] Observability
  - [ ] Number of sessions, time taken, total token usage, failures etc.
- Explore https://github.com/elixir-vibe/vibe for further stuff
  - https://x.com/davydog187/status/2075320738261659775

## What Sets It Apart

- **Distributed by default** — designed for multi-node setups from the start.
- **Elixir-native** — fault tolerance, hot code reloading, and concurrency via the BEAM.
- **BYO-FE** — bring your own frontend; the default TUI is built with `ex_ratatui` but you can swap in anything.
- **Modular** — providers, tools, and agents are pluggable components.
