# Named workspaces

A named workspace is a user-invoked snapshot of cmdy's existing session model.
It is separate from `session.json`, which checkpoints during use and on quit.
Automatic recovery keeps a previous good snapshot and shows a notice if the
latest snapshot cannot be restored. Both files are written with mode `0600`.

## What is saved

- Every cmdy terminal window and native/sidebar tab group, including selection
  and order.
- Window frames and the optional Window Grid state.
- The exact recursive split tree for every tab.
- Pane working directories and the recent, capped scrollback already produced
  by `TerminalWindowController.serializeLayout()`.
- Tab- and pane-scoped appearance fields. The workspace encoding preserves
  unknown JSON fields, so newer theme, shader, font, and layout settings survive
  round trips through an older store implementation.

`Save As New Workspace` creates a new identity. `Update Current Workspace`
replaces only the snapshot for the currently named workspace. Opening a
workspace adds its windows beside the live workspace by default. Replacing the
current live windows is a separate, explicit mode and must run through cmdy's
normal dirty-editor and active-process confirmation path.

Workspace files live in `~/.config/cmdy/workspaces` (or the active
`CMDY_CONFIG_DIR`). Each snapshot is an atomic, owner-readable `0600` JSON file;
one interrupted write cannot damage another workspace or the automatic session.

## Agent and credential boundary

Workspaces do not save credentials, environment variables, keychain material,
process memory, authentication files, or implicit shell commands. Codex,
Claude, and Pi remain ordinary terminal programs. cmdy saves their pane's cwd
and visible capped scrollback just like any other shell.

Use **File → Workspaces → Remember Agent Session…** with an ID explicitly
supplied by the agent. Running an explicit `codex resume ID`,
`claude --resume ID`, or `pi --session ID` command also associates that ID with
the pane. `WorkspaceLaunchHint` accepts only a known tool and a short, restricted
identifier, not an arbitrary command or file path. Invalid optional hints are
ignored without discarding the saved layout.

Opening a workspace always starts fresh shells. The Navigator and Inspector
distinguish restored transcripts from available agent sessions; live commands
keep their existing running/attention state. **Resume** in the Inspector or
palette stages a fixed resume command only at a positively identified empty
shell prompt. It neither submits the command nor replaces an edited prompt.
The user presses Return to run it. **Forget Agent Session** removes the hint.

## App integration

`NamedWorkspaceCoordinator` owns storage and the current-workspace identity. Its
two app callbacks should be thin adapters around the existing implementation:

1. Capture with `AppDelegate.serializedSessionLayouts()` plus the four
   `WorkspacePresentation` values from `Preferences` and explicit hints keyed
   by window/recursive-child path.
2. Apply valid hints to `SavedWorkspace.foundationLayouts()` using
   `WorkspaceResume.applying`, then restore through the existing
   `restoreSession(_:)` path. `.additionalWindows` is the default;
   `.replaceCurrentWorkspace` is allowed only after close approval succeeds.

Menus and the command palette should call `saveAsNew(named:)`,
`updateCurrent()`, and `open(id:mode:)`. Rename, delete, and deterministic list
operations are available on the same coordinator.
