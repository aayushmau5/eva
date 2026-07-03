# Eva

A coding harness built in Elixir, inspired by [tau](https://twotimespi.dev/).

> Work in progress — things may move, break, and change.

![under construction](https://cyber.dabamos.de/88x31/construction.gif)

# Idea

Current ideas, subject to change.

## Architecture

Eva is a distributed coding agent platform. It ships with a default terminal agent harness powered by `ex_ratatui` + BYO-FE, with a modular architecture that lets you swap out providers and frontends.

## Feature Checklist

- [ ] Distributed architecture
  - [ ] At what point do we handle external node messages?
    - [ ] Split between:
      - [ ] Providers
      - [ ] Harness
- [x] Very basic provider(currently LMStudio based API only)
  - [ ] Handle envs & config
  - [ ] Switch providers
- [ ] Agent Harness
  - [ ] The agent loop
  - [ ] Handling distributed node messages
  - [ ] Sessions
  - [ ] Memory
  - [ ] Prompts
    - [ ] Follow-up
    - [ ] Queue
  - [ ] Tools
    - [ ] Tool calls
      - [ ] Elixir native?
      - [ ] read/write/edit/bash tools
      - [ ] Q/A
  - [ ] Compaction
  - [ ] Subagents
  - [ ] Extensions
    - [ ] Perhpas "sharing" as an extension
  - [ ] Sharing(login?)
    - [ ] Atproto
      - [ ] PDS as sync layer(inspired by tiles.run)?
    - (Fun idea): Indieweb?
  - (Experiment): Explore with mob as distributed node connection?
- [ ] TUI (`ex_ratatui`) + BYO-FE
  - [ ] Slash commands (`/usage`, `/providers`, `/login`, `/logout`, ...)
  - [ ] Pretty lil animations

## What Sets It Apart

- **Distributed by default** — designed for multi-node setups from the start.
- **Elixir-native** — fault tolerance, hot code reloading, and concurrency via the BEAM.
- **BYO-FE** — bring your own frontend; the default TUI is built with `ex_ratatui` but you can swap in anything.
- **Modular** — providers, tools, and agents are pluggable components.
