# PLAN — swarm as an agent orchestration control-plane

> **Status:** DESIGN (2026-07-09). Not started. This is the build plan for the
> #1 competitive-gap feature from the killer-features research: promote **swarm**
> from a session *lister/switcher* into a *control plane* where a lead agent (or
> the user, or a script) can **spawn, drive, read, and coordinate a fleet** of
> agent panes over the existing HTTP/SSE SDK.
>
> **Audience:** a fresh session with cmdy context. Read `project-swarm-plugin`,
> `project-plugin-sdk`, and `PLUGINS.md` first. Everything builds on the public
> `/v1` API — no private hooks.

## Why this, why us

Every serious rival moved from *observing* agents to *orchestrating* them (Warp
Oz's message bus, cmux's socket CLI `new-split`/`read-screen`/`wait-for`, Claude
Code Agent Teams). cmdy's swarm lists and focuses sessions but can't spawn or
drive a fleet. **That's the frontier, and cmdy's HTTP/SSE SDK is a more open
substrate than anything they ship** — none expose a language-agnostic plugin API.
The whole feature is additive endpoints + one MCP shim + swarm UI. No engine
rewrite.

## The safety model (non-negotiable, decide first)

cmdy's rule is "AI only types into the user's pane, never auto-runs." This
feature does NOT weaken that:

- Orchestration drives **worker panes the orchestrator spawned** — never the
  user's own primary pane. The spawn endpoint marks a pane `orchestrated: true`;
  drive/send endpoints refuse a pane that isn't orchestrated (or is the caller's
  own pane) unless the user opted a pane in.
- A spawned worker is itself an agent (a `claude`/`codex` session) with its OWN
  approval model. The lead sends it a *prompt* (types + Enter to launch the
  agent); it does not bypass the worker's own tool gates.
- Every orchestrated pane wears a visible badge (swarm shows it, the pane shows a
  chip) and there is a global **kill-switch** (⌃⌥A → "Stop fleet", `cmdy swarm
  kill --all`). Nothing runs invisibly.
- The control endpoints are token-gated like the rest of `/v1`, and (per the
  robustness audit) the HTTP server's DoS surface is being hardened separately.

## What already exists (reuse, don't rebuild)

- `GET /v1/panes` — every pane with `windowIndex`/`paneIndex`/`ai`/`attention`/
  `focused` (swarm already consumes this).
- `POST /v1/panes/<id>/type|run|focus`, `GET .../output`, `POST .../feed`.
- `GET /v1/events` (SSE): `pane-opened`/`pane-closed`, `command-finished
  {pane,command,exitCode,cwd}`, `command`, `hotkey`, `ui`.
- `PluginManager.splitProvider` / `closeProvider` (split a pane → new pane id;
  close a pane) — exist in-process; **not yet HTTP-exposed.**
- swarm plugin (⌃⌥A list + menu-bar ◆/● monitor) — the natural UI home.
- The attention system (OSC 9/99/777 → amber dot) — a ready "needs-you" signal.
- Bridge's MCP runtime — precedent for shipping MCP tools from a plugin.

## The gaps to build

Five capabilities, each a thin addition:

| Need | New surface |
|---|---|
| **Spawn** a pane running a command | `POST /v1/panes` `{command, where, cwd}` → `{paneId}` |
| **Send** to a pane | already have `/type` + `/run` |
| **Read** a pane | already have `/output`; add `/screen` (visible grid, not scrollback) |
| **Signal / wait** | `cmdy signal <name> [--data k=v]` → SSE `task {pane,name,data}`; `GET /v1/panes/<id>/wait?signal=done` (long-poll) |
| **Status / progress** | `POST /v1/panes/<id>/status` `{state,progress,label}`; surfaced in swarm |

## Phases

### Phase 0 — the signal + status substrate (no UI yet)
The primitive everything else composes: workers must be able to say "I'm working
/ I need you / I'm done," and orchestrators must be able to block on it.
1. **`cmdy signal <name> [--data ...]`** shell helper → `POST /v1/signal`
   `{name, data}` (pane inferred from the caller's tty/pid). Emits SSE
   `task {pane, name, data, ts}`.
2. **`POST /v1/panes/<id>/status` `{state: working|waiting|done|error,
   progress?: 0..1, label?}`** — stored per pane, added to the `/v1/panes`
   payload, emitted as `pane-status` SSE.
3. **`GET /v1/panes/<id>/wait?signal=<name>&timeout=<s>`** — long-poll that
   resolves when the named signal (or `command-finished`, or `state=done`)
   arrives; 204 on timeout. (Server-side: park on the event bus, not a busy
   loop — respect the audit's "no blocking the shared queue" rule; handle these
   off the accept queue.)
Gate: from two panes, one `cmdy signal done`, the other's `/wait` returns it;
status shows in `/v1/panes`. Pure curl test.

### Phase 1 — spawn a driven worker
1. **`POST /v1/panes` `{command, where: split-right|split-down|tab|window,
   cwd?, label?}`** → `{paneId}`. App support: create a pane whose shell runs
   `command` (or types+runs it after the shell is ready), tag it
   `orchestrated:true` + `label`. Reuse `splitProvider` for the split cases.
2. Drive-guard: `/type` `/run` on an `orchestrated` pane are allowed; on a
   non-orchestrated pane they stay allowed for the user's own tooling but the
   orchestration MCP only targets panes it spawned.
3. **`GET /v1/panes/<id>/screen`** — the visible grid as text (distinct from
   `/output` scrollback), for "read what the worker sees now."
Gate: curl spawns a `claude`-less worker (`bash -lc 'echo hi; cmdy signal done'`)
in a split, `/wait` returns, `/screen` shows `hi`, `close` removes it.

### Phase 2 — swarm becomes the fleet console
1. swarm's ⌃⌥A list + menu bar show orchestrated panes as a **fleet group** with
   live `state`/`progress`/`label` (◆ working 60% · ● waiting · ✓ done · ✗
   error), driven by the `pane-status`/`task` SSE.
2. Controls: "Stop fleet" (kill all orchestrated), per-worker "Focus / Stop",
   and a one-line fleet summary in the menu-bar title (e.g. `◆ 3 · ✓ 1`).
3. The kill-switch + visible badges satisfy the safety model.
Gate: spawn 3 workers by curl; swarm shows 3 with live progress; "Stop fleet"
removes them.

### Phase 3 — the orchestration MCP shim (`cmdy-swarm`)
So a **lead Claude Code session drives the fleet in natural language**:
1. New MCP stdio shim (like sim/chromium) registered at user scope, tools:
   `spawn(command, where)`, `send(paneId, text, enter)`, `read_screen(paneId)`,
   `wait_for(paneId, signal, timeout)`, `list()`, `status(paneId)`,
   `stop(paneId)` / `stop_all()`.
2. A `cmdy swarm` CLI mirror (`spawn`/`send`/`read`/`wait`/`ls`/`kill`) for
   shell scripts and non-MCP agents.
Gate: from a lead session, `spawn` 3 workers, `send` each a subtask, `wait_for`
all `done`, `read_screen` each, merge — visible as live panes.

### Phase 4 — patterns + isolation
1. Ship example orchestrations (fan-out/gather, judge-panel, loop-until-done) as
   docs + a `Plugins/swarm/examples/` dir.
2. **Worktree-per-worker** (optional `isolation: worktree` on spawn): each worker
   gets its own git worktree + branch so parallel agents don't collide; swarm
   shows branch + diff stats; "merge winner" from the panel. (Mirrors the fork
   model's worktree isolation.)

## Acceptance demo (the "oh damn")
One lead session: "split into three, each fixes one failing test suite." swarm
shows three ◆ workers with progress bars; each `cmdy signal done` flips it ✓; the
lead reads all three screens and reports which passed — all visible, all
scriptable, all over the public SDK.

## Sequencing with the other two flagships
- **C1 grep-your-past** and **C2 time-travel scrubber** both need the
  **event-log-on-disk** substrate (persist `/v1/events` + command output). Build
  that persistence once and all three benefit: orchestration gets durable task
  history, grep gets its index, the scrubber gets its timeline. Recommend: land
  Phase 0-1 here (cheap, high-wow), then invest in the event-log store, which
  unlocks C1/C2 next.

## Files this will touch (estimate)
- `Kit/…/PluginKit.swift` — new routes (`/v1/panes` POST, `/signal`, `/status`,
  `/wait`, `/screen`); expose split/close/spawn providers.
- `App/AppDelegate.swift` — spawn-with-command provider, status store, wait bus.
- `Core/…` — none (this is platform + app, engine untouched).
- `Plugins/swarm/` — fleet UI + the new `cmdy-swarm` MCP shim + `mcp/`.
- `cmdy` CLI — `signal` + `swarm` subcommands.
- `PLUGINS.md` — document the orchestration surface (additive to the frozen ABI).
