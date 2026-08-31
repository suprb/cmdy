# cmdy Extension Protocol v1

Status: implemented, updated 2026-07-17

The Extension Protocol is the public contract between cmdy and programs that
extend it. An extension is a separate process. It may be written in any language
that can make authenticated HTTP requests and read Server-Sent Events (SSE).

The product model is deliberately small:

> **Listen. Change. Show.**

- **Listen** to semantic events such as commands, panes, windows, and themes.
- **Change** supported decisions through short, bounded hooks.
- **Show** commands, transient panels, native Surfaces, or companion tools.

The SDK is optional convenience code. HTTP/JSON is the ABI.

## Core boundary

Extensions never link into the PTY parser, terminal model, Metal renderer, or
input hot path. cmdy launches each extension as a child process and gives it
a short-lived identity token. If an extension exits, crashes, or is disabled,
cmdy revokes the token and removes everything that launch registered.

This is the platform rule:

> Open the policy plane. Protect the hot loop.

## Installation scopes

cmdy supports three scopes with the same protocol:

| Scope | Location | Lifetime |
|---|---|---|
| Installed | `~/.config/cmdy/extensions/<name>/` | Every cmdy launch while enabled |
| Project | `<project>/.cmdy/extensions/<name>/` | While a pane is in a trusted project |
| Development | Any file or directory passed to `cmdy extension dev` | While the development client sends heartbeats |

The previous `~/.config/cmdy/plugins` directory migrates automatically. The
old path and `plugin-api.json` discovery file remain compatibility aliases for
v0 clients.

Project code never runs merely because a repository was opened. cmdy shows
one trust prompt naming every extension and its capabilities. Trust is stored
outside the repository in `~/.config/cmdy/extension-trust.json`.

## Manifest v1

Every installed or project extension has a `manifest.json` beside its
entrypoint:

```json
{
  "manifestVersion": 1,
  "id": "dev.example.deploy",
  "name": "Deploy",
  "version": "1.0.0",
  "entrypoint": "bin/deploy",
  "enabled": true,
  "capabilities": [
    "events.read",
    "panes.read",
    "commands",
    "ui.surfaces"
  ]
}
```

Rules:

- `id` is a stable reverse-DNS identifier.
- `entrypoint` is relative and cannot leave the extension directory.
- v1 requires an explicit capability array, including an empty one.
- Unknown capabilities reject the manifest. They never widen authority.
- Duplicate IDs cannot run from two locations simultaneously.
- `enabled: false` prevents launch and immediately stops a running installed
  extension when changed from cmdy's Extensions window.

The machine-readable schema is
[`Schemas/extension-manifest-v1.schema.json`](Schemas/extension-manifest-v1.schema.json).

Legacy `{name, exec, enabled}` manifests still launch with their historical
full access and are visibly labeled **legacy full access**. That frozen grant
does not grow when later capabilities such as `channels` are introduced. This
prevents an upgrade from silently breaking existing installations or broadening
their authority while giving authors a clear migration target. New examples
never generate legacy manifests.

## Capabilities

| Capability | Authority |
|---|---|
| `events.read` | Subscribe to semantic events and private callbacks |
| `panes.read` | Read pane metadata, current block identity, and recent output |
| `panes.type` | Type, run, or display-feed text in a pane |
| `panes.manage` | Focus, scroll, split, close, or gather panes into a new window |
| `commands` | Register command-palette and Extensions-menu commands |
| `hotkeys` | Register system-wide hotkeys |
| `ui.panels` | Open transient list, input, text, or editor panels |
| `ui.surfaces` | Attach and update native Surface Protocol documents |
| `ui.companion` | Reserve a cmdy window edge for a companion application |
| `notifications` | Post a native notification |
| `channels` | Register owned external work sources, ingest Work Items, and receive only host-approved queued replies |
| `hooks` | Register bounded decision hooks |
| `marketplace.install` | Request marketplace installation with user consent |
| `debug` | Read renderer diagnostics and hit-test information |

The Extensions window displays declared capabilities. A token contains exactly
the manifest's set. Route authorization is enforced by cmdy, not by SDK
convention.

## Launch environment

cmdy sets:

| Variable | Meaning |
|---|---|
| `CMDY_PORT` | Local HTTP port on `127.0.0.1` |
| `CMDY_TOKEN` | Per-launch bearer token |
| `CMDY_EXTENSION_ID` | Manifest identity |
| `CMDY_EXTENSION_NAME` | Display name |
| `CMDY_EXTENSION_VERSION` | Manifest version |
| `CMDY_EXTENSION_SCOPE` | `global`, `project:<path>`, or `dev:<id>` |
| `CMDY_MANIFEST_VERSION` | Parsed manifest version |
| `CMDY_CAPABILITIES` | Sorted comma-separated grant set |

The equivalent legacy `TERMITE_*` and `TERM64_*` names remain compatibility aliases
for existing v1 Extensions. New code should use `CMDY_*`.

All requests except `GET /health` use:

```http
Authorization: Bearer $CMDY_TOKEN
Content-Type: application/json
```

`GET /v1` returns the live endpoint index, caller identity, and exact grants.

## Ownership and private delivery

Every command, hotkey, panel, Surface, inset, hook, and event subscription is
owned by the token that created it. An extension cannot update, dismiss, or
answer another extension's resource, even if it guesses an ID.

Channels add a durable two-level identity. The stable manifest Extension ID
owns Channel records across restarts; the current short-lived token owns the
live connection. A Channel ID must equal or extend the Extension ID, and only
one launch may connect it at a time. Disconnect removes runtime authority but
retains the host-owned Inbox and Outbox. Launch tokens are never persisted.

Semantic events such as `pane-opened` are broadcast to subscribed extensions.
Callbacks such as `command`, `hotkey`, `ui`, `surface-action`, and `hook` are
delivered only to their owner. The user-owned discovery credential may inspect
all resources but cannot be acquired through an extension token.

## Events

`GET /v1/events` is an SSE stream. Each frame contains one JSON object:

```text
data: {"kind":"command-started","pane":"...","block":"...","command":"make"}
```

Stable event kinds include:

- `pane-opened`, `pane-updated`, `pane-closed`
- `panes-composed`
- `command-started`, `command-finished`
- `window-frame`, `window-state`, `app-activation`
- `theme-changed`, `attention`
- private `command`, `hotkey`, `ui`, `surface-action`, `surface-dismissed`
- private `hook`
- private `channel-reply` after a user queues a draft

Events are semantic. Raw PTY bytes and rendered cells are never mirrored through
the extension bus.

## Decision hooks

An extension with `hooks` registers:

```http
POST /v1/hooks

{"id":"protect-main","boundary":"command.submit","priority":20}
```

Implemented boundaries:

- `command.submit`
- `paste`
- `pane.split`
- `pane.close`
- `notification`

cmdy sends a private event containing `request`, `hook`, `boundary`, payload,
and `deadlineMs`. The extension answers on a background-safe route:

```http
POST /v1/hook-responses/<request>

{"decision":"cancel","reason":"Deploy from a feature branch instead."}
```

Decisions are `continue`, `replace`, or `cancel`. `replace` requires `value`.
For `pane.split`, the replacement is `right` or `down`. For `notification`,
the replacement becomes the notification body while its title is preserved.

Conflict and failure rules are deterministic:

1. Higher numeric priority runs first (`-100...100`).
2. Ties sort by extension ID, then hook ID.
3. The first non-`continue` answer wins.
4. Each hook receives at most 60 ms inside one 120 ms boundary budget.
5. Missing, late, malformed, disconnected, or crashed hooks mean `continue`.
6. The total budget is capped at 500 ms by the host API even for internal use.

Thus an extension can influence policy without making normal terminal input
depend on its health.

## API groups

The live `GET /v1` index is authoritative. Stable groups are:

- `/v1/panes` for reading and controlled pane operations
- `/v1/windows/compose` for gathering selected live panes into a new grid window
- `/v1/commands` and `/v1/hotkeys` for user entry points
- `/v1/ui/panel` for transient UI
- `/v1/control-bars` for a companion's persistent terminal-owned command row
- `/v1/surfaces` for durable structured UI
- `/v1/hooks` and `/v1/hook-responses` for decisions
- `/v1/channels`, `/v1/channel-work-items`, and `/v1/channel-replies` for the
  capability-scoped Receive / Route / Reply contract
- `/v1/ui/inset` for external companion windows
- `/v1/theme`, `/v1/notify`, and `/v1/marketplace/install`

Routes are versioned. Additive fields may appear within v1 and must be ignored
when unknown. A semantic breaking change receives `/v2` and a new manifest
compatibility declaration.

## Development loop

```sh
cmdy extension new ./my-extension
cmdy extension validate ./my-extension
cmdy extension dev ./my-extension
```

`dev` may also receive one `.py`, `.js`, `.mjs`, `.swift`, or shell file with no
manifest. cmdy synthesizes a temporary scoped manifest, captures stdout and
stderr, watches source modification time and size, restarts on save, removes
old registrations before relaunch, and expires the session four seconds after
heartbeats stop.

Optional grants are explicit:

```sh
cmdy extension dev ./tool.py \
  --capability events.read \
  --capability hooks
```

Other commands:

```sh
cmdy extension install ./my-extension
cmdy extension list
cmdy extension enable dev.example.tool
cmdy extension disable dev.example.tool
cmdy extension trust ./project
cmdy extension untrust ./project
cmdy extension trusted
```

## Lifecycle guarantees

- The terminal core remains usable when every extension is disabled.
- Process exit revokes its credential and closes its SSE sockets.
- Owned commands, hotkeys, hooks, panels, Surfaces, and insets are cleaned up.
  Channels are disconnected; their durable Work Items and replies remain.
- A stopped process receives `SIGTERM`; cmdy uses `SIGKILL` only if it remains
  alive after two seconds.
- An SDK extension also watches its parent PID so a cmdy crash does not leave
  companion processes orphaned.
- Extension work never executes in the Metal frame or PTY read callbacks.

## Host resource budgets

Per launch, cmdy accepts at most 256 commands, 64 hotkeys, 64 hooks, 64
Surfaces, 16 transient panels, and 16 Channels per stable Extension. Panel text is limited to 2 MB and a list to
2,000 items. HTTP bodies are capped at 16 MB before decoding. Exceeding a live
rate or ownership budget returns `429`; malformed identifiers and values return
`400`. These limits keep an Extension from turning AppKit registration or
layout work into unbounded terminal latency.

## Security position

Capabilities constrain cmdy API authority. They are not an operating-system
sandbox: an executable launched as the user may still use permissions the OS
gives that process. Marketplace and project installation therefore require
clear trust. Future sandbox profiles may reduce OS authority without changing
this protocol.

cmdy never claims that a native executable is safe merely because its API
token is scoped.

The `channels` grant does not permit pane input, Action execution, agent launch,
or sending host-private drafts. Those remain user-owned operations. See
[CHANNELS.md](CHANNELS.md) for route authority, bounds, reply states, SDK types,
and the Marketplace connector format.
