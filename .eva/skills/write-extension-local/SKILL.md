---
name: write-extension-local
description: Write an Eva extension that runs on the same machine as the session — a script (.exs) compiled into Eva's VM, or a Mix project on its own local node. Use when asked to create, modify, or debug a local Eva extension.
---

# Writing a local Eva extension

Two ways to ship one, both running on the same machine as the session:

| | | |
|---|---|---|
| **script** | one `.exs` file | Eva compiles it into its own VM at session start |
| **project** | a Mix project | its own BEAM node on this machine, which Eva finds and dials |

Everything about the contract — `setup/1`, the `%Spec{}` fields, every callback, the `API`
— is identical in both. A project only differs in packaging: it has its own `mix.exs` and
dependencies, starts `Eva.Core.Extension.Node` from its application, and you start it
yourself. Reach for a project when the extension needs libraries of its own, or when one
file has stopped being enough. See [Project extensions](#project-extensions).

An extension that runs on *another* machine is also a project — see the
`write-extension-remote` skill for what changes there.

## Where it goes (scripts)

`~/.eva/extensions/<name>.exs` for every project, or
`<project>/.eva/extensions/<name>.exs` for one. A directory works too, as
`<name>/extension.exs`, when the extension needs sibling files. The **filename is the
extension's name** — that name appears in diagnostics, namespaces its stored data, and is
how its own tools look up its process. A project file shadows a global one of the same name.

**Project extensions need approving.** `~/.eva/extensions` loads automatically — the user
put it there. `<project>/.eva/extensions` does not: it is code from whoever wrote the
repository, running before the first prompt, so Eva skips the whole directory and says so
until the user approves it (`Session.trust_extensions/1`). Approval covers the directory's
contents as they were, so editing or adding an extension asks again. A path passed
explicitly with `-e` is always loaded — naming it is the consent.

**The module name follows the filename.** `notes.exs` must define
`Eva.Extension.Notes`, and every other module in the file goes under it
(`Eva.Extension.Notes.Client`). Module names are global on the BEAM, so this is what keeps
two extensions from redefining each other's helpers; anything outside the namespace fails
to compile, and a module under the wrong extension's namespace is refused at load.

**The whole contract** is `setup/1` returning a `%Spec{}`:

```elixir
defmodule Eva.Extension.Notes do
  use Eva.Core.Extension

  @impl true
  def setup(_ctx) do
    {:ok, %Spec{guidelines: ["Record decisions as you make them."]}}
  end
end
```

`use Eva.Core.Extension` aliases `Spec`, `API`, `Messages`, and `Tools` for you, and injects
defaults for every optional callback.

---

## Decide first: does it need a process?

This determines everything else.

| Spec declares | Gets a process |
|---|---|
| `tools`, `guidelines` only | **No.** Pure data merged into the session. |
| any of `hooks`, `event_classes`, `commands` | **Yes.** A GenServer, alive for the session. |

An extension with no process cannot hold state between calls. Don't declare a hook you
don't use just to get one.

---

## The five Spec fields

```elixir
%Spec{
  tools:         [%Tools.AgentTool{}],              # callable by the model
  guidelines:    ["one line"],                      # appended to the system prompt
  commands:      [%Spec.Command{name: "hi"}],       # user types /hi
  hooks:         [:tool_call, :tool_result, :input],
  event_classes: [:lifecycle, :tools, :stream, :mcp, :extension]
}
```

Declare **only** the hooks you implement. Eva routes on this list, so an undeclared hook is
never called and a declared-but-unimplemented one falls to the injected default.

---

## Tools

Same `%Tools.AgentTool{}` struct the built-ins use. Copy the shape from
`Eva.Coding.Tools.read_tool/1`.

```elixir
@impl true
def setup(ctx) do
  {:ok, %Spec{tools: [note_tool(ctx.cwd)]}}
end

defp note_tool(cwd) do
  %Tools.AgentTool{
    name: "note",
    description: "Append a line to NOTES.md in the project root.",
    prompt_snippet: "Record a decision or finding",
    prompt_guidelines: ["Write one note per decision, not per file touched."],
    input_schema: %{
      type: "object",
      properties: %{text: %{type: "string", description: "The note to record"}},
      required: ["text"]
    },
    executor: fn arguments, _exec_ctx ->
      text = Map.fetch!(arguments, "text")
      if String.trim(text) == "", do: raise("note text cannot be empty")

      path = Path.join(cwd, "NOTES.md")
      File.write!(path, "- #{text}\n", [:append])

      %Tools.AgentToolResult{
        content: [%Messages.TextContent{text: "Noted in #{path}"}],
        details: %{path: path}
      }
    end
  }
end
```

**Four rules, all of them existing Eva conventions:**

1. **`arguments` has string keys.** It comes from `JSON.decode` and is never atomized.
2. **Raise to fail.** `AgentToolResult` has no error field; raising is the only way to mark a
   call failed, and the exception message becomes what the model sees.
3. **Capture what you need in `setup/1`.** The executor may run many turns later, in a
   process that didn't exist when `setup/1` ran. Close over `ctx.cwd`, don't re-derive it.
4. **Pick a name no one else has.** A tool whose name matches a built-in (`read`, `write`,
   `edit`, `bash`) or an earlier extension's tool is **silently dropped** with a diagnostic.
   An extension on another machine is exempt: its tools are prefixed with that machine, so
   they cannot collide with yours.

For slow tools, report progress — it reaches the UI without touching the transcript:

```elixir
Tools.report_update(exec_ctx, %Tools.AgentToolResult{
  content: [%Messages.TextContent{text: "scanning 400 files…"}]
})
```

---

## Hooks

One callback, dispatched on the hook name. **Return shapes differ per hook** — getting one
wrong is treated as a failure.

```elixir
@impl true
def handle_hook(:tool_call, tool_call, state) do
  # tool_call is %Messages.ToolCall{id:, name:, arguments:}
  cond do
    dangerous?(tool_call) -> {{:block, "reason shown to the model"}, state}
    needs_fixing?(tool_call) -> {{:rewrite, %{"command" => "safe"}}, state}
    true -> {:proceed, state}
  end
end

def handle_hook(:tool_result, {tool_call, result, is_error}, state) do
  {{redact(result), is_error}, state}
end

def handle_hook(:input, text, state) do
  cond do
    String.starts_with?(text, "/todo ") -> {{:handled, "Added."}, state}
    String.contains?(text, "sk-") -> {{:transform, redact_keys(text)}, state}
    true -> {:continue, state}
  end
end
```

| Hook | Payload | Return |
|---|---|---|
| `:tool_call` | `%Messages.ToolCall{}` | `:proceed` · `{:rewrite, arguments}` · `{:block, reason}` |
| `:tool_result` | `{tool_call, result, is_error}` | `{result, is_error}` |
| `:input` | the raw text | `:continue` · `{:transform, text}` · `{:handled, message}` |

Always wrapped as `{answer, new_state}`.

**How several extensions combine.** `:tool_call` is first-blocker-wins — the walk stops at
the first `{:block, _}` and later extensions are never asked; a `{:rewrite, _}` accumulates,
so the next extension sees your modified arguments. `:tool_result` and `:input` chain: every
extension runs, each transforming the previous one's output, except that the first
`{:handled, _}` on `:input` stops the chain and no turn starts.

**Constraints you must respect:**

- **5 second budget.** A hook that takes longer is treated as unreachable, and for
  `:tool_call` that means **blocked**. Never do slow I/O in a hook.
- **A raise is not neutral.** A crashing `:tool_call` hook blocks the tool — Eva can't tell
  whether you meant to deny it. Handle your own errors if "allow" is the right fallback.
- **`:input` hooks see raw text**, before `/skill:` expansion. You may return
  `/skill:foo` text and it will expand normally.

---

## Events

Declare classes, implement `handle_event/2`.

| Class | Delivers |
|---|---|
| `:lifecycle` | `AgentStart` `AgentEnd` `TurnStart` `TurnEnd` `MessageStart` `MessageEnd` |
| `:tools` | `ToolExecutionStart` `ToolExecutionUpdate` `ToolExecutionEnd` |
| `:stream` | `MessageUpdate` — **one per token**, only subscribe if you truly need it |
| `:extension` | `ExtensionEvent` — anything another extension published, MCP's server connect/disconnect among them — and `ExtensionsChanged` when the session's set of extensions changes |

```elixir
@impl true
def handle_event(%Eva.Core.Agent.Events.TurnEnd{}, count), do: {:ok, count + 1}
def handle_event(_event, state), do: {:ok, state}   # REQUIRED — see below
```

**You must write a catch-all clause.** `use Eva.Core.Extension` injects one, but defining any
`handle_event/2` clause of your own replaces *all* of the injected ones. Without a catch-all
you'll `FunctionClauseError` on the first event you didn't anticipate.

---

## Commands and state

Declare `%Spec.Command{name: "audit", description: "…", arg_hint: "[path]"}`, then:

```elixir
@impl true
def init(_ctx), do: {:ok, %{count: 0}}

@impl true
def handle_command("audit", args, state), do: {"checked #{args}", state}

@impl true
def handle_request(:bump, state), do: {state.count + 1, %{state | count: state.count + 1}}
```

`init/1` builds your state; every other callback receives and returns it. A command name
already taken by another extension is dropped, and the loser is named in the diagnostics —
first registered wins.

**What you reply with is shown to the user**, and three shapes are understood: `"text"`,
`{:text, "text"}`, and `{:error, reason}`. Anything else is `inspect`ed onto their screen —
which is the quickest way to spot a return you didn't mean.

**When a tool needs your state**, look the process up — `setup/1` runs before it exists, so
the executor can't capture the pid:

```elixir
executor: fn _args, _exec_ctx -> API.call(ctx, ctx.name, :bump) end
```

That reaches `handle_request/2`. Use `ctx.name`, not a hardcoded string, so renaming the
file doesn't break it.

---

## Talking back to the session

```elixir
API.send_user_message(ctx, "check the failing test")   # queues a real turn
API.send_custom_message(ctx, "done", "my_type", %{})   # shown, not sent to the model
API.append_entry(ctx, %{"key" => "value"})             # persisted, namespaced by extension
API.notify(ctx, "heads up", :warning)                  # transient notice
```

All fire-and-forget. `append_entry/2` data must be **JSON-safe with string keys** — atom
keys come back as strings on resume and won't match what you wrote.

---

## Context

Passed to `setup/1`, `init/1`, and whatever you close over:

```elixir
%Eva.Core.Extension.Context{
  name:            "notes",        # from the filename
  cwd:             "/path/to/project",
  model:           "deepseek-v4-pro",
  provider_config: %OpenAICompatible{},   # start your own provider (subagents)
  session_pid:     #PID<0.90.0>,
  extension_dir:   "/Users/…/.eva/extensions",  # find sibling files
  entries:         [%{"key" => "value"}],       # your own, from `API.append_entry/2`
  machine:         nil,                         # always nil locally
  capabilities:    Eva.Extension.Capabilities   # ask the user, spawn a subagent
}
```

`machine` is `nil` whenever the extension and the session are on the same machine, which is
every script and every project node you started yourself. It only becomes a label in the
remote case — see the `write-extension-remote` skill.

---

## Project extensions

A project is a normal Mix project that depends on `eva_core` and starts
`Eva.Core.Extension.Node` from its application. The module naming and contract rules above
apply unchanged.

**`mix.exs`** — depend on `eva_core`, and name the application module:

```elixir
defmodule MyExt.MixProject do
  use Mix.Project

  def project do
    [app: :eva_my_ext, version: "0.1.0", elixir: "~> 1.20", deps: deps()]
  end

  def application do
    [extra_applications: [:logger], mod: {Eva.Extension.MyExt.Application, []}]
  end

  defp deps do
    # The contract this extension is written against. `core/` is the `eva_core`
    # library inside the Eva repo; depend on it via a sparse git checkout, or set
    # `EVA_CORE_PATH` to point at a local checkout while developing.
    [{:eva_core, git: "https://github.com/you/eva.git", sparse: "core"}]
  end
end
```

**The application module** — start your own children, then `Eva.Core.Extension.Node`:

```elixir
defmodule Eva.Extension.MyExt.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # ...your own processes...
      {Eva.Core.Extension.Node, name: "my_ext", module: Eva.Extension.MyExt}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__.Supervisor)
  end
end
```

`name` must match the module's namespace (`Eva.Extension.MyExt` ↔ `"my_ext"`). `eva_core`'s
own application starts the bus, the process registry, the supervisor, and the tool registry
— `Application.ensure_all_started(:eva_core)` is the whole runtime, so there is no checklist.

**Register and start it** from the Eva project:

```bash
mix eva.ext.add ../my_ext       # register (path or git URL); also the trust decision
mix eva.ext.start my_ext        # start the node, detached
mix eva.ext.list                # registered, and whether each one is connected
mix eva.ext.stop my_ext
mix eva.ext.remove my_ext
```

The node `mix run --no-halt`s and sits there; a running Eva finds it on its next scan, a
second or two later. It keeps running across Eva restarts, and it can be started before Eva
is — there is nothing for it to wait for.

**In development, skip the commands.** `iex -S mix` in the extension's own project announces
on boot, and `r Eva.Extension.MyExt` recompiles a module into a live session. That loop is
the payoff a project has over a script.

The node is loopback-only by default — only this machine can reach it, which is exactly
right for a local extension. Running one on another machine is the `write-extension-remote`
skill.

---

## Before you finish

- **`@impl true` on every callback**, including `setup/1`. Mixing annotated and
  unannotated callbacks makes Elixir warn on load.
- **A unique module name.** Modules register globally, so two extensions both defining
  `Guard` collide and the second is rejected. Prefix with something specific.
- **Never crash `setup/1`.** It runs during session startup; a raise means the whole
  extension is dropped, tools included.
- **Verify it loaded** — don't assume:

```elixir
Eva.Coding.Session.list_extensions(session_pid)
```

Returns a row per extension with `running?`, `tool_count`, and `commands`. If yours is
missing, the reason is in the diagnostics. Common causes: no `use Eva.Core.Extension`, a compile
error, `setup/1` returned something other than `{:ok, %Spec{}}`, or a name already claimed.

Editing an extension needs `Session.reload_extensions/1` (or a new session) — the compiled
module is cached for the life of the VM. Reload is refused while the agent is running.
