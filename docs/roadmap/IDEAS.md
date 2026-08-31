# cmdy — future ideas

Ideas approved for the future shelf (2026-07-02).

1. **Shadow runs** — ⌘-Enter executes a command against an instant APFS
   clone of the cwd, shows the REAL filesystem diff (created/modified/
   deleted), then [Run for real] / [Discard]. A true dry-run for rm -rf,
   migrations, codemods. macOS-only advantage via clonefile().
2. **Semantic zoom** — pinch / ⌘-scroll out: text → block cards (command,
   status, duration) → session timeline → multi-day overview. Spatial
   navigation of history; GPU-rendered thumbnails.
3. **Ambient shader weather** — feed repo/system/host state into the
   shader uniforms: dirty repo = amber edge breathing, tests running =
   slow pulse, prod ssh = red-warm surface, pegged CPU = heat shimmer.
   Peripheral-vision status, only possible when you own the renderer.
4. **Live blocks** — right-click a block → "keep alive": re-runs on an
   interval in place with diff-highlighted output. `watch` as a
   first-class notebook cell; terminal becomes a dashboard.
5. **Terminal polaroids** — one keystroke exports a block as a share
   card: command + output, theme + CRT shader baked in, cmdy wordmark.
6. **Total recall** — searchable local archive of every session ever;
   find "that docker DNS fix from October", jump back into that moment's
   cwd/context in a new pane.
7. **Two-cursor collaboration** — share a session natively; two colored
   cursors in one PTY, multiplayer-doc presence. Biggest lift.

## Shipped from this shelf

- **Pane-owned appearance + saved Workspaces** — pane → tab → global
  theme/shader/font precedence, first-spatial-pane chrome, stable appearance
  through live moves, and atomic named snapshots with save/update/open/rename/delete.
  Credentials and implicit commands are intentionally excluded.
- **Keybinding import** — Ghostty, tmux, iTerm2, and macOS Terminal parsers,
  previewable translations, explicit conflict/unsupported states, atomic apply,
  bounded undo, reset, and runtime dispatch without native shortcut replacement.
