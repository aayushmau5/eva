# Eva

A coding harness built in Elixir, inspired by [tau](https://twotimespi.dev/).

> Work in progress — things may move, break, and change.

# Idea

Idea & Current path, subject to change.

## Architecture

Eva is a distributed coding agent platform. It ships with a default terminal agent harness powered by `ex_ratatui` + BYO-FE, with a modular architecture that lets you swap out providers and frontends.

## Feature Checklist

- [x] Fork
- [ ] TUI (`ex_ratatui`) + BYO-FE
- [ ] Slash commands (`/usage`, `/providers`, `/login`, `/logout`, ...)
- [ ] Tool calls
- [ ] Q/A
- [ ] Compact
- [ ] Subagents
- [ ] Pretty lil animations
- [ ] Sharing
- [ ] Distributed architecture

## What Sets It Apart

- **Distributed by default** — designed for multi-node setups from the start.
- **Elixir-native** — fault tolerance, hot code reloading, and concurrency via the BEAM.
- **BYO-FE** — bring your own frontend; the default TUI is built with `ex_ratatui` but you can swap in anything.
- **Modular** — providers, tools, and agents are pluggable components.
