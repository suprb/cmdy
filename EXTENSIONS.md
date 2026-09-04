# Build cmdy Extensions

cmdy is a native GPU terminal that can be reprogrammed while it is running.
An **Extension** is the thing a person installs. The **cmdy SDK** is an
optional toolbox for building one. A **Surface** is a native interface an
extension can show inside cmdy. Extensions are one of the three layers in
the [cmdy platform model](PLATFORM.md), beside one-shot Actions and
bidirectional Channels.

```text
Extension = behavior or mini app
SDK       = developer convenience library
Surface   = native UI rendered by cmdy
Action    = user-invoked script, command, or pane workflow
Channel   = external work in and explicitly approved results out
```

The complete author model is:

> **Listen. Change. Show.**

You do not need Swift or the SDK. An extension is any executable that can send
HTTP JSON and read an event stream.

## Start in one minute

```sh
cmdy extension new ./hello-cmdy
cmdy extension dev ./hello-cmdy
```

The first command creates:

```text
hello-cmdy/
  manifest.json
  extension.py
```

The second command launches it with temporary credentials, watches its files,
prints its logs, and restarts it whenever you save. Press Control-C to end the
session; cmdy removes everything the launch registered.

You may also develop one file without a manifest:

```sh
cmdy extension dev ./idea.py
```

## Manifest

```json
{
  "manifestVersion": 1,
  "id": "dev.example.hello",
  "name": "Hello",
  "version": "0.1.0",
  "entrypoint": "extension.py",
  "enabled": true,
  "guide": {
    "whatItDoes": ["Adds a Hello command that posts a local notification."],
    "safety": ["Reads semantic events; it cannot inspect or type into panes."],
    "setup": ["No account or credential is required."]
  },
  "capabilities": [
    "events.read",
    "commands",
    "notifications"
  ]
}
```

The optional `guide` is the factual **What it does / Safety / Setup** text shown
from the Extensions window. Keep it concrete and consistent with the declared
capabilities. Marketplace copy can provide the same fields; an installed local
manifest takes over when there is no registry entry.

The capability list says exactly which cmdy APIs the process may call.
Validate before installing:

```sh
cmdy extension validate ./hello-cmdy
cmdy extension install ./hello-cmdy
cmdy extension disable local.hello-cmdy
cmdy extension enable local.hello-cmdy
```

If cmdy is running, `install` launches the new Extension immediately. The
copy is staged and validated before it becomes visible to the host.

Installed extensions live in `~/.config/cmdy/extensions`. Open
**View > Extensions** to start or stop them immediately.

The exact manifest, security, hook, lifecycle, and compatibility contract is in
[EXTENSION_PROTOCOL.md](EXTENSION_PROTOCOL.md).

## Connect without an SDK

cmdy launches the program with:

```text
CMDY_PORT=4664
CMDY_TOKEN=<short-lived secret>
CMDY_EXTENSION_ID=dev.example.hello
CMDY_CAPABILITIES=commands,events.read,notifications
```

Every request except `/health` uses the token:

```python
#!/usr/bin/env python3
import json, os, urllib.request

base = f"http://127.0.0.1:{os.environ['CMDY_PORT']}"
headers = {
    "Authorization": f"Bearer {os.environ['CMDY_TOKEN']}",
    "Content-Type": "application/json",
}

def post(path, body):
    request = urllib.request.Request(
        base + path, json.dumps(body).encode(), headers, method="POST")
    return json.load(urllib.request.urlopen(request))

post("/v1/extensions/register", {
    "commands": [{
        "id": "dev.example.hello.say-hi",
        "title": "Hello: Say hi",
    }],
    "hotkeys": [],
    "hooks": [],
})

request = urllib.request.Request(base + "/v1/events", headers=headers)
with urllib.request.urlopen(request) as events:
    for line in events:
        if not line.startswith(b"data: "):
            continue
        event = json.loads(line[6:])
        if event.get("kind") == "command" and \
           event.get("id") == "dev.example.hello.say-hi":
            post("/v1/notify", {
                "title": "Hello",
                "body": "The extension is running.",
            })
```

That is a complete extension: register, listen, react. The batch route is the
preferred startup path when an extension contributes several commands,
hotkeys, or hooks; the individual `/v1/commands`, `/v1/hotkeys`, and
`/v1/hooks` routes remain available for registrations added later at runtime.

## Listen

`GET /v1/events` is a Server-Sent Events stream. Common events:

| Event | Useful fields |
|---|---|
| `command-started` | `pane`, `block`, `command`, `cwd` |
| `command-finished` | `pane`, `block`, `command`, `exitCode`, `cwd` |
| `pane-opened`, `pane-updated`, `pane-closed` | `pane`, `cwd` |
| `window-frame` | `window`, `x`, `y`, `width`, `height`, `liveResize` |
| `window-state` | `window`, `state` |
| `theme-changed` | theme name and native colors |
| `command`, `hotkey` | private invocation ID |
| `surface-action` | private Surface action and form values |

The stream contains meaning, not every output byte. This keeps extensions away
from rendering and PTY throughput.

## Compose a pane workspace

An Extension with `panes.manage` can gather two or more existing panes into a
new terminal window:

```python
post("/v1/windows/compose", {
    "panes": ["pane-id-one", "pane-id-two", "pane-id-three"]
})
```

cmdy moves the live pane views and automatically arranges a compact grid.
The PTYs, child processes, scrollback, and pane IDs do not restart or change.
Donor windows close only when no terminal pane or attached editor remains. The
Swift SDK exposes the same operation as `composePanes`.

## Built in or an Extension?

cmdy keeps universal terminal behavior in the host: command boundaries,
exit status, failed-row presentation, private error explanation, user approval,
PTY ownership, and GPU rendering. These must remain fast and trustworthy even
when every Extension is disabled.

Specialized behavior belongs in Extensions. The same `command-finished` event
lets an Extension build a project-specific debugger, incident workflow, test
report, or alternate model integration. It may show a Panel or attach a Surface,
but stdout remains canonical and cmdy still owns execution approval.

That boundary keeps the product simple:

```text
cmdy core = meaning, speed, safety, fallback
Extension    = opinionated workflow or mini app
Provider     = replaceable intelligence behind a core action
Action       = one-shot user invocation
Channel      = connected Inbox and explicit Outbox
```

A Channel connector is packaged as an Extension because it needs a
resident process, events, and provider credentials. The connected account is a
Channel in the UI, while the installed executable remains an Extension. See
[CHANNELS.md](CHANNELS.md) for the shipped `channels` capability, typed SDK,
HTTP routes, connector scaffold, and Marketplace format.

## Change

Decision hooks can continue, replace, or cancel a supported user action:

```python
post("/v1/hooks", {
    "id": "protect-main",
    "boundary": "command.submit",
    "priority": 20,
})

# In the event loop:
if event.get("kind") == "hook":
    command = event.get("command", "")
    if command.startswith("git push --force"):
        post(f"/v1/hook-responses/{event['request']}", {
            "decision": "cancel",
            "reason": "Force push was blocked by this project extension.",
        })
    else:
        post(f"/v1/hook-responses/{event['request']}", {
            "decision": "continue",
        })
```

Hooks have one 120 ms total budget. If your extension is slow, disconnected, or
broken, cmdy continues normally. Declare both `events.read` and `hooks`.

Implemented boundaries are `command.submit`, `paste`, `pane.split`,
`pane.close`, and `notification`.

## Show a transient panel

Panels are temporary UI for a picker, prompt, text response, or editor:

```python
response = post("/v1/ui/panel", {
    "mode": "list",
    "placeholder": "Choose an environment",
    "items": [
        {"id": "staging", "title": "Staging"},
        {"id": "production", "title": "Production"}
    ]
})
```

Interactions return as private `kind: "ui"` events. Panels use the user's
cmdy font, colors, keyboard behavior, and focus model.

## Contribute to the Adaptive Frame

The Adaptive Frame keeps the current tab group to the left, the terminal in
the center, and contextual tools to the right. The left column replaces the
native tab bar while open. An Extension can add a bounded, declarative section
to either native column:

```python
post("/v1/ui/contributions", {
    "id": "deployments",
    "location": "inspector",
    "title": "Deployments",
    "contexts": ["pane", "command"],
    "priority": 20,
    "sequence": 0,
    "items": [
        {
            "id": "staging",
            "title": "Staging",
            "detail": "healthy · v142",
            "badge": "LIVE",
            "status": "success",
            "action": "open-staging"
        }
    ]
})
```

Clicking an actionable row sends a private event:

```json
{"kind":"ui","event":"action","contribution":"deployments","item":"staging","action":"open-staging"}
```

Use `navigator` for tab-adjacent sessions, projects, queues, or pages; those
sections appear beneath the host's tabs. Use `inspector` for the focused pane,
command, selection, Surface, or project. `contexts` is
optional; supported values are `pane`, `command`, `selection`, and `surface`.
Optional `window` and `pane` fields scope a section more narrowly.

Update with `POST /v1/ui/contributions/<id>/update` and an increasing
`sequence`; remove with `DELETE /v1/ui/contributions/<id>`. Each Extension may
own 16 sections with at most 64 rows each and 128 KB per request. Process exit
removes all of its sections automatically. Extensions provide meaning and
actions—not AppKit views, HTML, fonts, colors, or layout—so the SwiftUI columns
stay native, themed, accessible, and responsive. Declare `ui.panels`.

## Attach a persistent control row

Companion Extensions can keep a small command row at the bottom of their exact
terminal window without putting controls inside the companion window:

```python
post("/v1/control-bars", {
    "id": "browser-42",
    "window": 42,
    "actions": [
        {"id": "annotate", "title": "[ annotate ]"},
        {"id": "back", "title": "←"},
        {"id": "forward", "title": "→"}
    ],
    "placeholder": "enter URL",
    "value": "localhost:3000"
})
```

Actions emit private `kind: "ui"`, `controlBar`, `event: "action"`, and
`value` fields. Submitting the text field emits `event: "submit"`. Update or
focus the row with `POST /v1/control-bars/<id>/update`; remove it with
`POST /v1/control-bars/<id>/dismiss`. A pane exposes one row at a time, owned
by the creating Extension. It temporarily yields to a palette or Surface and
returns afterward. The row uses the configured terminal cursor. `Cmd+L`
focuses it, `Tab` and `Shift+Tab` move between actions and input, `Return`
activates the current target, and `Esc` returns to the shell. Declare
`ui.panels`.

## Show a Surface

A Surface is structured UI attached to a semantic command block. It is not a
replacement for text. The command's stdout remains in scrollback and every
Surface must include a useful `fallback`.

```python
post("/v1/surfaces", {
    "v": 1,
    "id": "tests",
    "kind": "task",
    "title": "Test run",
    "block": "current",
    "fallback": "Core: running\nRenderer: pending",
    "tasks": [
        {"id": "core", "label": "Core", "status": "running"},
        {"id": "renderer", "label": "Renderer", "status": "pending"}
    ]
})
```

Update stable items without rebuilding everything:

```python
request = urllib.request.Request(
    base + "/v1/surfaces/tests",
    json.dumps({
        "sequence": 1,
        "upsertTasks": [
            {"id": "core", "label": "Core", "status": "passed",
             "durationMs": 412}
        ]
    }).encode(), headers, method="PATCH")
json.load(urllib.request.urlopen(request))
```

Surface kinds in v1:

- `list`
- `table`
- `diff`
- `task`
- `form`
- `text`

cmdy renders them with native controls. Extensions cannot provide HTML,
JavaScript, arbitrary styles, or filesystem-capable widgets.

Read [SURFACE_PROTOCOL.md](SURFACE_PROTOCOL.md) for the schema, actions,
sequence rules, budgets, and Swift SDK examples.

## Upgrade ordinary tools

The `cmdy surface` adapter preserves stdin on stdout and adds a Surface when
cmdy is available:

```sh
git diff | cmdy surface diff --id working-tree --title "Working tree"
jq -c '.[]' data.json | cmdy surface table --id data --title "Data"
my-test-json | cmdy surface task --id tests --title "Tests"
```

Run the same pipeline in another terminal, redirect it to a file, or use it in
CI and the text still works.

## Project extensions

A repository may carry team behavior:

```text
project/
  .cmdy/
    extensions/
      protect-production/
        manifest.json
        extension.py
```

cmdy asks before running it. Trust can also be managed explicitly:

```sh
cmdy extension trust ./project
cmdy extension untrust ./project
cmdy extension trusted
```

An approved project extension starts while any pane is inside the project and
stops after the last pane leaves it.

## Swift SDK

`Plugins/CmdySDK` is an optional typed client. It does not have extra
authority; it calls the same public routes.

```swift
import CmdySDK

guard let cmdy = Cmdy() else { exit(1) }

cmdy.registerCommand(id: "dev.example.tests", title: "Show Tests")
cmdy.openSurface(CmdySurfaceDocument(
    id: "tests",
    kind: .task,
    title: "Tests",
    fallback: "Core: running",
    tasks: [
        CmdySurfaceTask(id: "core", label: "Core", status: .running)
    ]
))
cmdy.listen()
RunLoop.main.run()
```

Registrations made before `listen()` are sent as one startup batch, then the SDK
opens its event stream. The SDK also exposes `updateSurface`, `dismissSurface`,
`openWorkspaceContribution`, `updateWorkspaceContribution`,
`dismissWorkspaceContribution`, `registerHook`, `respondToHook`, and typed Channel registration, ingestion,
queued-reply decoding, and delivery acknowledgement. Channel connectors request
`channels` and normally `events.read`; see [CHANNELS.md](CHANNELS.md).

## First-party references

Most cmdy examples are ordinary external extensions using the same public API:

- **Detox**: commands and a live native editor panel.
- **Swarm**: an always-current Agents section in the Tabs sidebar, plus hotkeys,
  agent-session UI, and selected/all live-agent workspaces.
- **Browser**: sandboxed Chromium rendered as a real split inside cmdy. Its
  Marketplace install downloads and verifies the signed CEF-bearing app
  variant, then restarts cmdy.
- **Sim**: Apple Simulator tooling plus a serve-sim mirror opened in that same
  in-window Browser split.
- **Bridge**: a product-scale integration and MCP runtime.

Extensions can be enabled, disabled, replaced, or removed. Ordinary Extension
entrypoints are not compiled into the terminal core. Browser is the narrow
allow-listed exception: cmdy owns its embedded view host and keeps Chromium's
runtime bytes sealed in the signed Browser app variant for sandboxing. Removing
its Extension swaps to the signed lean variant, closes every Browser split, and
deletes the Chromium code while preserving the browsing profile.
The source installer registers Bridge and Sim's neutral stdio MCP shims with
installed Claude Code and Codex clients at user scope; an explicitly ad-hoc
Browser local builds register its shim as well.

## Rules worth keeping

- Prefer `panes.type` to automatic execution when the user should press Enter.
- Ask only for capabilities you use.
- Treat stdout as the permanent truth and Surfaces as an additive view.
- Use stable IDs and sequenced patches.
- Keep hook work under the deadline.
- Assume process exit can happen at any time; cmdy owns cleanup.
- Do not poll rendered cells or stream every PTY byte.

The aim is not to turn cmdy into a desktop shell. The aim is to keep a fast,
clean terminal while making its behavior and native interface programmable.
