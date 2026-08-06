---
name: write-extension
description: Write an Eva extension — an .exs file that adds tools, system-prompt guidelines, tool-call hooks, input rewriting, slash commands, or event handlers to a coding session. Use when asked to create, modify, or debug an Eva extension.
---

# Writing an Eva extension

Two ways to ship one, and the difference is where it runs:

| | | |
|---|---|---|
| **script** | one `.exs` file | Eva compiles it into its own VM at session start |
| **project** | a Mix project | its own BEAM node, which announces itself to Eva |

Everything below is about scripts, and **all of it applies unchanged to a project** — same
`setup/1`, same callbacks, same `API`. A project only differs in packaging: it has its own
`mix.exs` and its own dependencies, it starts `Eva.Extension.Node` from its application,
and you start it yourself (`mix eva.ext.start <name>`, or `iex -S mix` while developing).
Reach for one when the extension needs libraries of its own, or when one file has stopped
being enough. See [extension-nodes.md](../../../docs/extension-nodes.md).

An extension is one `.exs` file that Eva compiles into the running VM at session start.

**Where it goes.** `~/.eva/extensions/<name>.exs` for every project, or
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
  use Eva.Extension

  @impl true
  def setup(_ctx) do
    {:ok, %Spec{guidelines: ["Record decisions as you make them."]}}
  end
end
```

`use Eva.Extension` aliases `Spec`, `API`, `Messages`, and `Tools` for you, and injects
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
| `:mcp` | MCP server connect/disconnect/tools-changed |
| `:extension` | notices emitted by extensions |

```elixir
@impl true
def handle_event(%Eva.Agent.Events.TurnEnd{}, count), do: {:ok, count + 1}
def handle_event(_event, state), do: {:ok, state}   # REQUIRED — see below
```

**You must write a catch-all clause.** `use Eva.Extension` injects one, but defining any
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
already taken by another extension is dropped with a diagnostic.

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
%Eva.Extension.Context{
  name:            "notes",        # from the filename
  cwd:             "/path/to/project",
  model:           "deepseek-v4-pro",
  provider_config: %OpenAICompatible{},   # start your own provider (subagents)
  session_pid:     #PID<0.90.0>,
  resources:       %Resources{},
  extension_dir:   "/Users/…/.eva/extensions"   # find sibling files
}
```

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
missing, the reason is in the diagnostics. Common causes: no `use Eva.Extension`, a compile
error, `setup/1` returned something other than `{:ok, %Spec{}}`, or a name already claimed.

Editing an extension needs `Session.reload_extensions/1` (or a new session) — the compiled
module is cached for the life of the VM. Reload is refused while the agent is running.
