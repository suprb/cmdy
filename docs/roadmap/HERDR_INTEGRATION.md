# Herdr-backed persistent workspaces

Status: proposed; implementation intentionally deferred

Approach: B first, with an evidence-gated path to C

Product boundary: cmdy remains the native terminal and presentation layer;
Herdr becomes an optional process and workspace runtime.

## Decision

Build **B: Persistent Workspace mode** as an opt-in backend for selected cmdy
workspaces. Do not make every terminal Herdr-backed yet.

The intended experience is:

1. The user chooses **New Persistent Workspace** in cmdy.
2. cmdy creates or attaches to a named Herdr session.
3. Herdr owns the PTYs and processes, so shells and agents continue running when
   cmdy closes, crashes, or moves to another machine through Herdr's SSH flow.
4. cmdy remains responsible for the native macOS windows, tabs, recursive
   splits, Window Grid, Navigator, themes, fonts, shaders, editor, Browser, Sim,
   Actions, Channels, and Extensions.
5. Closing cmdy detaches. Stopping a persistent workspace is a separate,
   explicit destructive action.

This is not a Herdr terminal embedded in a cmdy pane. It is cmdy's existing
terminal UI connected to a server-owned terminal.

## Why B before C

The attractive long-term idea is **C: make Herdr the default runtime behind
every cmdy terminal**. Starting there would combine three high-risk migrations:

- local PTY ownership moves out of cmdy;
- tab, split, and pane topology becomes distributed state;
- session lifecycle and updates gain a long-running background dependency.

B isolates those risks. Ordinary cmdy terminals continue to use
`CmdyPTY.LocalProcess`, while persistent workspaces exercise the new backend
with real users and a reversible choice. The UI and renderer do not fork.

## Product ownership

There must be one authority for each kind of state.

| State | Authority |
|---|---|
| PTYs, processes, persistent session lifecycle, agent identity | Herdr |
| Native windows, macOS tabs, Window Grid, rails, focus presentation | cmdy |
| Per-pane/tab theme, shader, font, and other visual appearance | cmdy |
| Herdr workspace/tab/pane topology while attached | Herdr, projected into cmdy |
| Named Workspace presentation snapshot | cmdy, with references to Herdr identities |

cmdy must never maintain an independently editable shadow topology. A user
split, move, resize, or close is sent to Herdr first; cmdy applies the
authoritative response/event. A mutation made by another Herdr client arrives
through the event stream and updates the native cmdy projection.

## Architecture

Keep `TerminalPane`, `TerminalModel`, `CmdyCore`, and the Metal renderer.
Introduce a transport seam beneath the pane:

```text
TerminalPane / CmdyTerminalSurface / TerminalModel / Metal renderer
                              │
                    TerminalSessionBackend
                       │              │
                       │              └── HerdrTerminalBackend
                       └── LocalProcessBackend
```

The first backend wraps today's `CmdyPTY.LocalProcess`. The Herdr backend
uses two channels:

- **Control plane:** Herdr's newline-delimited JSON socket API for session
  snapshots, workspace/tab/pane topology, agent state, mutations, and events.
- **Terminal data plane:** `herdr terminal session control` for the writable
  owner and `herdr terminal session observe` for read-only views. Control mode
  emits base64 ANSI frame records and accepts structured input, resize, scroll,
  and release commands over stdio.

`TerminalSessionBackend` is not only a process launcher. Every byte flowing in
either direction, parser-generated terminal response, input event, resize,
scroll request, process/session lifecycle transition, and detach/terminate
operation must pass through it. `TerminalModel` must not keep a second direct
reference to `LocalProcess`; otherwise the Herdr backend would be a cosmetic
adapter around a still-local ownership model.

Use the installed Herdr CLI to discover the matching protocol schema. Never
construct shell command strings; launch argv directly and encode control data as
bounded JSON.

### Identity

cmdy needs a stable internal binding record:

```text
HerdrBinding
  session name
  server/protocol version
  workspace id
  tab id
  terminal id
  current public pane id
  cmdy appearance id
```

Do not key appearance or saved workspace identity only by Herdr's public pane
ID. Herdr changes that ID when a live terminal moves across workspaces. Reconcile
the `previous_pane_id` and new pane record from the authoritative move response
while retaining cmdy's stable appearance identity.

### Writable control ownership

Herdr allows only one writable terminal-session controller. cmdy must model that
fact explicitly:

- **observing:** render frames read-only; input and resize are disabled;
- **requesting control:** ask the current owner to release where the protocol
  supports it, or explain that another client controls the terminal;
- **controlling:** cmdy owns input and resize for that terminal;
- **takeover available:** present a confirmation describing which client will be
  disconnected; never pass `--takeover` silently;
- **releasing:** send `terminal.release` and wait for acknowledgement/closure
  before treating control as available elsewhere.

Unexpected controller loss moves the pane to observing/reconnecting, never to an
automatic takeover loop.

### Topology projection

Herdr exports a binary BSP tree. cmdy's `NSSplitView` composition can represent
more than two children at one level. Before B2, define one canonical, reversible
mapping:

- preserve spatial leaf order and cmdy's stable appearance IDs;
- fold an N-child cmdy split into a deterministic same-axis binary chain;
- flatten only adjacent same-axis Herdr nodes whose ratios can be reconstructed
  without changing pixel geometry;
- store path-based split identities and ratios so an event update does not
  reshuffle unrelated views;
- reject or present a non-destructive preview when an exact conversion is not
  possible.

Golden tests must prove `cmdy -> Herdr BSP -> cmdy` returns the same ordered
leaves and pixel boundaries at representative window sizes.

### Named Workspaces

The existing cmdy Named Workspace remains a presentation snapshot. For a
persistent workspace it stores a typed Herdr reference plus cmdy's frame, grid,
rail, and appearance state. It does not duplicate PTY contents, credentials,
environment variables, authentication files, or commands.

Opening a saved persistent workspace attaches to the referenced Herdr session.
If it is unavailable, cmdy shows the saved layout in a disconnected state and
offers **Reconnect**, **Locate Herdr**, or **Open as new local shells**. It must
not silently create a replacement session under the same identity.

## Phase B delivery plan

### B0 — Contract spike

No product UI and no bundled binary.

- Pin a supported Herdr release range and capture `herdr api schema --json` as a
  test fixture.
- Prove local attach, detach, input, resize, scroll, reconnect, takeover, and
  event subscription against a real Herdr server.
- Feed `terminal.frame` ANSI records through `TerminalModel` and compare the
  resulting screen to direct Herdr attach.
- Audit feature fidelity: Unicode, alternate screen, mouse reporting, bracketed
  paste, titles, cwd, OSC 133 blocks, hyperlinks, notifications, clipboard, and
  Kitty/Sixel graphics.
- Determine which semantic data must come from socket metadata/events because a
  rendered ANSI frame is not the original PTY byte stream.
- Write a version/feature compatibility matrix. Unknown or incompatible
  protocol versions must fail safely.

**Exit gate:** one persistent pane survives cmdy termination and reconnects with
correct input, resize, and screen state; no loss or duplication occurs during a
forced reconnect. This is a hard go/no-go gate: if rendered ANSI cannot preserve
input modes, mouse behavior, or another cmdy-critical semantic feature, B does
not enter production. Continue only after an upstream-supported metadata or raw
transport closes the gap; an experimental flag is not a substitute for terminal
correctness.

### B1 — First-party adapter

- Add a small `HerdrClient` package with bounded request/response types,
  snapshot reconciliation, event subscription, reconnect backoff, and protocol
  fixtures.
- Detect a user-installed `herdr` binary and report its exact compatibility.
- Add read-only Herdr sessions and agent state to Navigator.
- Add **Attach Persistent Pane** and a connection badge with connected,
  reconnecting, incompatible, and stopped states.
- Keep cmdy's ordinary window/split model; attach one Herdr terminal per pane.

**Exit gate:** the adapter can be removed without changing local terminals, and
an unavailable or crashed Herdr process cannot block cmdy startup, typing, close,
or quit.

### B2 — Persistent Workspace mode

- Add **New Persistent Workspace**, **Attach Persistent Workspace**, **Detach**,
  and explicit **Stop Persistent Workspace** commands.
- Project Herdr workspaces/tabs/layouts into native cmdy tabs and splits.
- Route cmdy split, move, resize, focus, and close operations through Herdr.
- Apply server events from other clients without oscillation or duplicate
  mutations. Tag local operations and deduplicate their echo events.
- Preserve cmdy appearance while panes move between tabs, windows, splits, and
  Window Grid tiles.
- Save typed Herdr references through Named Workspaces.

**Exit gate:** two cmdy windows and a second Herdr client can concurrently move,
split, close, and focus terminals for a one-hour stress run without divergent
topology. Relaunching cmdy restores the same live processes and visual state.

### B3 — Distribution-quality integration

- Decide whether cmdy detects a separately installed Herdr or bundles a pinned
  executable. Start with user-installed Herdr; bundling is a separate release
  decision.
- If bundled, include the Apache-2.0 license and notices, checksum/SBOM, universal
  binary validation, nested code signing, notarization, and a reproducible fetch
  or build path.
- Add `cmdy doctor` diagnostics for Herdr path, version, protocol, socket
  ownership/mode, session health, and reconnect state.
- Coordinate updates. cmdy must not replace or stop a live Herdr server unless a
  compatible handoff is supported or the user explicitly accepts process loss.
- Add crash recovery, compatibility mode, migration, and uninstall tests.

**Exit gate:** the signed/notarized app passes a clean-machine install, update,
downgrade refusal, detach/reconnect, and uninstall rehearsal without weakening
either product's sandbox or code-signing policy.

### B4 — Remote persistence

- Treat native cmdy remote projection as a new feasibility gate. Herdr currently
  documents `herdr --remote` as a thin client that streams Herdr's own UI; that
  does not by itself establish a supported remote socket or terminal-session
  bridge for cmdy's native projection.
- First prove an upstream-supported remote control/data transport or a narrowly
  scoped SSH tunnel with authentication, host-key verification, bounded framing,
  reconnect, and cleanup semantics.
- Expose Herdr's SSH remote attach as a separate connection type.
- Use normal OpenSSH authentication and config; cmdy never stores private keys or
  copies credentials into a workspace file.
- Clearly display the execution host and treat remote output as sensitive.
- Keep local and remote feature matrices explicit; do not pretend graphics,
  clipboard, or filesystem integrations are identical until verified.

Remote support is valuable, but it is not required to declare local B complete,
and it must not ship by scraping or wrapping Herdr's full-screen TUI.

## Moving from B to C

C means Herdr becomes the default runtime for newly created cmdy terminal
workspaces. It does **not** initially remove the local backend.

Promotion is allowed only when all of these are true:

### Compatibility gates

- Input, resize/reflow, Unicode/IME, mouse, alternate screen, bracketed paste,
  hyperlinks, clipboard, titles/cwd, OSC 133 blocks, notifications, and supported
  terminal graphics match local cmdy behavior.
- Actions, Channels, Extensions, Browser, Sim, Swarm, editor splits, native tabs,
  pane/window conversion, themes, shaders, fonts, session restore, and Window
  Grid work for persistent panes.
- Current and previous supported Herdr protocol versions interoperate safely.
  Unknown versions never mutate or stop sessions.

### Reliability and performance gates

- At least two public cmdy releases have shipped opt-in B without a data-loss or
  process-loss incident.
- Persistent-workspace crash-free sessions are at least 99.9% over 30 days of
  opted-in use.
- Local reconnect p95 is below 500 ms and first usable frame p95 is below one
  second on the release hardware baseline.
- Key-to-frame and resize latency remain within cmdy's existing release budgets.
- Stress tests cover 100 panes, rapid open/close/move, cmdy crash/relaunch,
  Herdr crash/restart, version skew, sleep/wake, network loss, and concurrent
  clients with zero zombies, leaks, or topology divergence.
- Idle CPU returns to zero and per-pane memory remains within the local-backend
  budget plus an explicitly measured transport allowance.

### Product gates

- Users understand **detach** versus **stop** without losing work.
- At least 30% of newly created workspaces among eligible beta users choose
  Persistent Workspace, and fewer than 2% disable it because of reliability or
  latency problems.
- There is a one-click export/open-as-local escape hatch and a documented
  uninstall path.
- Herdr's protocol and release cadence are stable enough for cmdy to support a
  clear compatibility window without carrying a private fork.

## C rollout

1. **C0 — dogfood default:** persistent by default only in internal and nightly
   builds. Local remains one click away.
2. **C1 — beta default:** persistent by default for opted-in beta users and new
   workspaces only. Existing local workspaces never migrate automatically.
3. **C2 — new-install default:** stable new installs create persistent
   workspaces by default after an explanation of detach/stop semantics. Existing
   users keep their selected backend.
4. **C3 — broad default:** consider Herdr-backed terminals the normal path only
   after another two stable releases meet the gates. Keep the local backend as a
   safe mode until maintaining both is demonstrably worse than removing it.

Any process loss, session corruption, unbounded daemon lifetime, sustained input
latency regression, or upstream compatibility break immediately freezes the C
rollout and returns new workspaces to local mode. Existing Herdr sessions remain
attachable; rollback must never stop them.

## Test strategy

- Protocol fixture tests for schema changes, malformed frames, size limits,
  reconnect generations, stale responses, and moved pane identities.
- Golden terminal-frame tests comparing local cmdy, Herdr direct attach, and the
  native cmdy projection.
- State-machine tests for snapshot + subscription ordering, local mutation event
  echoes, reconnect gaps, takeover, and concurrent clients.
- UI tests for attach/detach/stop wording, disconnected state, first-pane chrome,
  native tab switching, split/window conversion, and Named Workspace restore.
- Lifecycle tests that kill cmdy, the controller process, and the Herdr server at
  every transition while asserting the documented process-survival behavior.
- Release tests for bundled/external binary discovery, license notices, signing,
  notarization, updates, downgrade refusal, and clean uninstall.

## Security and privacy

- Connect only to an expected Unix-domain socket whose owner and permissions
  match the current user. Bound every JSON line, frame, decoded payload, and
  queued event.
- Use structured argv and JSON; never interpolate pane text, cwd, labels, or
  commands into a shell string.
- Treat terminal output, agent metadata, pane history, and remote host names as
  sensitive. Do not automatically upload, index, or include them in crash logs.
- Stopping a server is destructive and always requires explicit confirmation
  listing the affected live processes.
- Remote sessions travel through SSH. Do not expose or forward the local socket
  as a network service.

## Explicit non-goals

- Embedding or reskinning Herdr's TUI inside cmdy.
- Replacing `CmdyCore` or the Metal renderer.
- Silently converting a running local PTY into a Herdr-owned process; arbitrary
  live processes cannot be migrated safely.
- Storing agent credentials, shell environments, or private SSH material in a
  Named Workspace.
- Requiring Herdr for ordinary cmdy use during B.
- Maintaining a private Herdr fork unless a narrowly scoped upstream proposal is
  rejected and the product benefit justifies the long-term cost.

## First implementation issue, when work resumes

Implement only B0. Produce a protocol fixture, a throwaway terminal-session
controller, fidelity results, and measured reconnect behavior. Do not add menu
items, persistence, bundled binaries, or production dependencies until the B0
exit gate is reviewed.

## Sources

- Herdr Socket API: <https://herdr.dev/docs/socket-api/>
- Herdr persistence and direct terminal sessions:
  <https://herdr.dev/docs/persistence-remote/>
- Herdr session survival semantics: <https://herdr.dev/docs/session-state/>
- Herdr agent automation: <https://herdr.dev/docs/agent-automation/>
- Herdr source and Apache-2.0 license: <https://github.com/herdrdev/herdr>
