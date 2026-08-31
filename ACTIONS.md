# Build cmdy Actions

A **cmdy Action** is a one-shot script, command, or pane workflow that appears
in the native **Actions** menu and command palette. Actions are the small,
personal automation layer; Extensions are resident programs that listen to
events and contribute ongoing behavior. Channels bring reviewable work
in from other applications and retain the address for an optional result.

```text
Action    = run something when the user invokes it
Extension = keep running, listen, change behavior, or host a mini app
Channel   = receive, route, and optionally reply to external work
```

See [PLATFORM.md](PLATFORM.md) for the complete model and
[CHANNELS.md](CHANNELS.md) for the Channel SDK and Work Inbox.

Actions can be personal:

```text
~/.config/cmdy/actions/
```

or checked into a project:

```text
.cmdy/actions/
```

Project Actions are invisible until the user explicitly trusts that project.
The same project trust covers `.cmdy/extensions`, including programs added
later, so the prompt states that boundary clearly.

## Start with one file

Drop an executable or a supported script directly into the personal Actions
folder:

```sh
mkdir -p ~/.config/cmdy/actions
cp ./clear-preview-cache.sh ~/.config/cmdy/actions/
```

Files ending in `.sh`, `.bash`, `.zsh`, `.py`, `.js`, `.mjs`, or `.swift` work
without a manifest. Executables with any extension work too. The filename
becomes the title and id.

Or scaffold the full form:

```sh
cmdy action new ~/.config/cmdy/actions/deploy-preview
cmdy action validate ~/.config/cmdy/actions/deploy-preview
cmdy action list
```

Use **Actions → Create Sample Action**, **Save Last Command as Action…**, or
**Open Actions Folder** for the same authoring loop without leaving cmdy.

## Starter Actions

Choose **Actions → Install Starter Actions…** or run:

```sh
cmdy action install-starters
```

cmdy installs five ordinary personal Actions. They are not privileged or
hidden: every `action.json` lands in `~/.config/cmdy/actions/`, can be edited
or deleted, and is never reinstalled over an existing Action or folder.

| Action | What it does |
|---|---|
| **cc — Continue Claude** | Runs `claude --continue` for the focused directory. |
| **Project Pulse** | Opens Git status/diff statistics and recent history in two splits. |
| **Local Preview** | Serves the focused folder on loopback and opens the chosen port. |
| **Port Watch** | Refreshes the local TCP listener table in a right split. |
| **Copy Handoff Note** | Copies branch, status, recent commits, and diff statistics after confirmation. |

The installer validates every manifest and rolls back newly created folders if
the pack is invalid. A matching Action id or target folder is reported as
`kept`; its contents are never replaced.

## Manifest

An Action folder contains `action.json` and, optionally, scripts beside it:

```json
{
  "manifestVersion": 1,
  "id": "project.deploy-preview",
  "title": "Deploy Preview",
  "description": "Build and publish a preview environment",
  "guide": {
    "whatItDoes": [
      "Builds the selected branch, deploys a preview, and opens a log watcher in a right split."
    ],
    "safety": [
      "Deployment commands run only after the confirmation below.",
      "The deploy CLI runs with your normal shell authority and whatever credentials it already has."
    ],
    "setup": [
      "Requires the repository's deploy script and a configured deployment CLI."
    ]
  },
  "group": "Release",
  "shortcut": "cmd+shift+r",
  "confirmation": "Deploy {{input.branch}} to {{input.environment}}?",
  "inputs": [
    {
      "id": "branch",
      "label": "Branch",
      "kind": "text",
      "default": "main",
      "required": true
    },
    {
      "id": "environment",
      "label": "Environment",
      "kind": "choice",
      "options": ["staging", "production"],
      "default": "staging"
    },
    {
      "id": "announce",
      "label": "Post announcement",
      "kind": "toggle",
      "default": "false"
    }
  ],
  "steps": [
    {
      "command": "./scripts/deploy {{input.branch}} {{input.environment}}",
      "pane": "focused",
      "mode": "run",
      "cwd": "project"
    },
    {
      "entrypoint": "watch-logs.sh",
      "pane": "right",
      "mode": "run",
      "cwd": "action"
    }
  ],
  "whenFiles": ["Package.swift"]
}
```

Use exactly one top-level `command`, `entrypoint`, or `steps` array. Workflow
steps are dispatched in order, but they are not completion-dependent: use `&&`
inside one command when a later operation must wait for an earlier one.

### Factual guide

`guide` uses the same **What it does / Safety / Setup** explanation shown for
Extensions and Channels. Write concrete behavior and boundaries: what is read
or changed, which step needs review, what can leave the machine, and what must
already be configured. Do not repeat the title or add promotional copy.

The guide is optional. When it is absent, cmdy derives one from the Action's
real steps, panes, input kinds, confirmation, context files, and personal or
project scope. It is visible from **Actions → Action Details** and in the
command palette.

### Inputs

Input kinds are `text`, `secure`, `toggle`, and `choice`. Values supplied by
the UI or CLI replace `{{input.<id>}}`; `{{cwd}}` and `{{project}}` provide the
focused directory and project root. Every replacement is shell-quoted before
it enters a command template.

The process also receives:

```text
CMDY_ACTION_ID
CMDY_ACTION_CWD
CMDY_ACTION_PROJECT
CMDY_ACTION_SOURCE
CMDY_ACTION_INPUT_<UPPERCASE_ID>
```

The equivalent legacy `TERMITE_*` and `TERM64_*` names remain compatibility aliases
for existing Actions. New Actions should use `CMDY_*`.

### Panes and execution

`pane` is `focused`, `right`, or `down`. A right/down step creates a real split
and keeps its shell alive like any other cmdy pane. `mode: run` submits the
command; `mode: type` places it at the prompt for review. `cwd` is `focused`,
`project`, or `action`.

Actions pass through the normal terminal input path. Their commands therefore
remain visible, produce ordinary stdout, create command blocks, and participate
in history and Extension hooks.

### Shortcuts and context

`shortcut` accepts descriptors such as `cmd+shift+r`, `option+control+k`, or
`cmd+1`. It is app-scoped and appears on the generated menu item. Avoid a key
combination already owned by cmdy or macOS.

`whenFiles` contains safe relative paths that must exist in the current project
or working directory. This keeps project-specific Actions out of unrelated
contexts.

## CLI

```sh
cmdy action new ./release --command "make release"
cmdy action validate ./release/action.json
cmdy action list
cmdy action run project.deploy-preview \
  --input branch=feature/actions \
  --input environment=staging
```

`run` uses the authenticated local discovery connection and executes in the
focused cmdy window. Missing inputs open the same native prompt used by the
menu. Confirmation text is always shown when the manifest declares it.

User-owned local tools may also call `GET /v1/actions` and
`POST /v1/actions/run` with the discovery credential from
`~/.config/cmdy/extension-api.json`. Per-Extension tokens cannot invoke
personal Actions.

## Security boundary

An Action is executable code. Personal Actions are under the user's config
directory. Project Actions require explicit project trust, entrypoints may not
escape their Action folder (including through symlinks), manifests and values
are bounded, and confirmation is available for consequential work. Incoming
messages or external content should never be turned directly into an Action;
they should become reviewable Work Items first. The Channels layer defines that
Inbox and explicit Outbox boundary in [CHANNELS.md](CHANNELS.md).

The machine-readable contract is
[`Schemas/action-manifest-v1.schema.json`](Schemas/action-manifest-v1.schema.json).
