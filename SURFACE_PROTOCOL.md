# cmdy Surface Protocol v1

Status: implemented, 2026-07-12

A normal command produces bytes. Those bytes remain the permanent, portable
truth. An extension may additionally attach structured state to that command.
cmdy renders the state as a native **Surface**.

```text
command -> stdout/stderr ----------------------> scrollback, pipe, log, SSH
        -> authenticated Surface document ----> native cmdy interface
```

A Surface is not a new stdout format, an HTML widget, or arbitrary drawing. It
is a small host-owned component vocabulary with predictable behavior.

## Compatibility rules

1. stdout and stderr remain useful without cmdy.
2. Surface failure never changes command execution or exit status.
3. Every Surface carries a useful plain-text `fallback`.
4. cmdy always provides an explicit **Text** representation.
5. Existing escape sequences, TUIs, Kitty graphics, shell pipelines, and SSH
   behavior remain unchanged.
6. Structured state travels over the extension API, never through the PTY.

## Open a Surface

The extension needs `ui.surfaces`:

```http
POST /v1/surfaces
Authorization: Bearer $CMDY_TOKEN
Content-Type: application/json

{
  "v": 1,
  "id": "tests",
  "kind": "task",
  "title": "Test run",
  "pane": "optional-pane-id",
  "block": "current",
  "fallback": "Core: running\nRenderer: pending",
  "tasks": [
    {"id": "core", "label": "Core", "status": "running"},
    {"id": "renderer", "label": "Renderer", "status": "pending"}
  ]
}
```

cmdy resolves `pane` to the focused pane when omitted. `block` may be:

- `current`: newest running or completed semantic command block
- `last`: newest completed block
- an explicit stable block ID from `command-started`, `command-finished`, or
  `GET /v1/panes`

The response returns the resolved attachment:

```json
{"ok":true,"surface":"tests","pane":"...","block":"...","sequence":0}
```

A Surface cannot attach to an unrelated or nonexistent pane or block.

## Document fields

| Field | Required | Meaning |
|---|---|---|
| `v` | no | Protocol version; defaults to `1` |
| `id` | yes | Stable owner-scoped ASCII identifier |
| `kind` | yes | `list`, `table`, `diff`, `task`, `form`, or `text` |
| `title` | yes | Visible native title |
| `pane` | no | Target pane; focused pane by default |
| `block` | no | `current` by default |
| `sequence` | no | Starts at `0` |
| `state` | no | `live`, `waiting`, `complete`, `failed`, `disconnected` |
| `summary` | no | Compact status or completed result |
| `fallback` | yes | Plain text that remains useful everywhere |
| Component fields | by kind | `columns`, `rows`, `tasks`, `diff`, `fields` |
| `actions` | no | Top-level semantic actions |

Unknown additive fields are ignored by the decoder. Unknown kinds reject rather
than silently creating executable or misleading UI.

The machine-readable schema is
[`Schemas/surface-v1.schema.json`](Schemas/surface-v1.schema.json).

## Native component vocabulary

### List

Rows have stable IDs and scalar cells. Without columns, cmdy displays
`label`, then `title`, then the first cell.

```json
{
  "kind":"list",
  "rows":[
    {"id":"staging","cells":{"label":"Staging"}},
    {"id":"production","cells":{"label":"Production"}}
  ]
}
```

### Table

Tables require typed column identities and bounded rows:

```json
{
  "kind":"table",
  "columns":[
    {"id":"state","title":"State","width":100},
    {"id":"path","title":"Path"}
  ],
  "rows":[
    {"id":"README.md","cells":{"state":"modified","path":"README.md"}}
  ]
}
```

Cells are strings, numbers, booleans, or null. Nested markup and executable
objects are rejected. Existing nested JSON can be serialized to a string by an
adapter.

### Diff

`diff` contains unified text. cmdy applies native addition, deletion, and
hunk colors while preserving selection and plain-text copy:

```json
{"kind":"diff","diff":"--- a/file\n+++ b/file\n-old\n+new"}
```

### Task

Tasks have stable IDs, status, optional progress, detail, duration, and actions:

```json
{
  "kind":"task",
  "tasks":[
    {"id":"build","label":"Build","status":"passed","durationMs":812},
    {"id":"deploy","label":"Deploy","status":"running","progress":0.4}
  ]
}
```

Status values are `pending`, `running`, `passed`, `failed`, `skipped`, and
`cancelled`. Progress is clamped visually to `0...1`.

### Form

Fields are `text`, `secure`, `toggle`, or `choice`:

```json
{
  "kind":"form",
  "fields":[
    {"id":"environment","label":"Environment","kind":"choice",
     "value":"staging","options":["staging","production"]},
    {"id":"confirm","label":"I reviewed the plan","kind":"toggle",
     "value":false,"required":true}
  ],
  "actions":[
    {"id":"deploy","title":"Deploy","effect":"mutate","style":"destructive",
     "confirmation":"Deploy the current commit to the selected environment?"}
  ]
}
```

Form values return with a `surface-action` event. cmdy never sends secure
field contents to any extension except the Surface owner.

### Text

Text is a host-owned selectable viewer for summaries that need no structured
rows. The canonical `fallback` still remains available.

## Sequenced patches

Updates are strictly monotonic:

```http
PATCH /v1/surfaces/tests

{
  "sequence": 1,
  "upsertTasks": [
    {"id":"core","label":"Core","status":"passed","durationMs":412}
  ]
}
```

Patch fields:

- Replace scalar state with `title`, `state`, `summary`, or `fallback`.
- Replace complete arrays with `columns`, `rows`, `tasks`, `fields`, or
  `actions`.
- Update stable items with `upsertRows` and `upsertTasks`.
- Remove stable items with `removeRows` and `removeTasks`.
- Replace unified diff text with `diff`.

The next sequence must equal current sequence plus one. A duplicate or gap
returns HTTP `409 Conflict` with the expected value. The producer should fetch
or reopen a full snapshot rather than guessing over a gap.

cmdy accepts at most 120 patches per Surface per second. Updates beyond that
return `429` and never delay PTY reads or Metal frames.

## Actions and authority

An action describes intent; it does not grant cmdy direct filesystem,
process, service, or network authority:

```json
{
  "id":"retry",
  "title":"Retry",
  "effect":"mutate",
  "style":"primary",
  "confirmation":"Run this failed task again?"
}
```

Effect classes:

| Effect | Meaning |
|---|---|
| `local-view` | A host-only representation interaction |
| `read` | Ask the producer for more information |
| `mutate` | Request a change to files, processes, services, or remote state |
| `approve` | Approve a separately described pending mutation |

`mutate` and `approve` actions are rejected unless they contain explicit
confirmation text. cmdy shows that text before delivering the event.

The owner receives:

```json
{
  "kind":"surface-action",
  "surface":"deploy",
  "action":"deploy",
  "effect":"mutate",
  "item":"optional-row-or-task-id",
  "values":{"environment":"production","confirm":true},
  "sequence":3
}
```

Only the originating extension receives it. The extension decides how to act
and reports new state through a patch.

## Representation and lifecycle

cmdy owns typography, colors, spacing, controls, keyboard focus, text copy,
and accessibility labels. The active Surface occupies a bounded drawer below
the terminal grid; the grid lends it rows instead of being covered. The Surface
remains semantically attached to its command block even while controls are in
that stable interaction area.

One Surface is visible per pane at a time. Documents remain owned and may be
shown again:

```http
POST /v1/surfaces/<id>/show
```

Updating a currently hidden Surface also brings its latest state back into the
pane. `GET /v1/surfaces` lists the caller's documents. The user-owned discovery
credential can inspect all of them.

Dismiss explicitly:

```http
DELETE /v1/surfaces/<id>
```

Closing from the UI emits private `surface-dismissed`. Disabling or terminating
an extension removes its live Surfaces and reveals the untouched terminal text.
Closing a pane invalidates the host and future show requests return not found.

## Resource limits

Surface v1 enforces:

- 16 MB maximum HTTP request body at transport level
- 2 MB combined fallback, summary, and diff text per document
- 10,000 rows
- 5,000 tasks
- 64 columns
- 64 top-level actions
- 16 actions per row or task
- 256 form fields and 256 choices per field
- unique column, row, task, and field IDs
- 120 patches per second per Surface
- owner-scoped IDs and lifecycle cleanup

Malformed or oversized documents return an error before native views are built.
No Surface state enters the PTY parser or Metal row cache.

## CLI adapter

Existing output can gain a Surface without changing the original program:

```sh
git diff | cmdy surface diff --id working-tree --title "Working tree"
jq -c '.[]' data.json | cmdy surface table --id records --title "Records"
my-test-json | cmdy surface task --id tests --title "Tests"
printf 'one\ntwo\n' | cmdy surface list --id choices --title "Choices"
```

The adapter writes its input to stdout first, unchanged except for adding a
missing final newline. If cmdy is unavailable or Surface attachment fails,
the command still succeeds with its text output.

Table and task adapters understand a JSON object, JSON array of objects, or
JSON Lines. Plain lines become list/table rows or pending tasks.

## Swift SDK

```swift
let surface = CmdySurfaceDocument(
    id: "tests",
    kind: .task,
    title: "Tests",
    fallback: "Core: running",
    tasks: [
        CmdySurfaceTask(id: "core", label: "Core", status: .running)
    ])

cmdy.openSurface(surface)
cmdy.updateSurface("tests", patch: CmdySurfacePatch(
    sequence: 1,
    upsertTasks: [
        CmdySurfaceTask(id: "core", label: "Core", status: .passed)
    ]))
```

The SDK is a typed convenience wrapper, not a separate protocol.

## Intentionally outside v1

These are possible additive future protocols, not incomplete v1 behavior:

- arbitrary HTML or extension-provided JavaScript
- unbounded canvas, video, microphone, or camera surfaces
- remote Surface forwarding over SSH
- long-term record/replay and restored interactive producers
- placing variable-height native views directly inside historical grid rows
- hidden direct host powers behind action labels

The small v1 vocabulary is the point: enough structure to make command output
interactive while keeping cmdy predictable, native, fast, and auditable.
