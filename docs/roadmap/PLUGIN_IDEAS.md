# cmdy Extension ideas

Plugins for the third-party world. Almost all are buildable **today** against
the v1 HTTP API (`GET /v1` for the self-describing index, or
[`PLUGINS.md`](../../PLUGINS.md)) — in
any language, no Swift required. Grouped loosely; ⚡ = high excitement-per-effort.

> **Already shipped as first-party examples** (`Plugins/`, installed by
> `plugins.sh`): **swarm** (the session switcher — every AI pane across windows
> in one ⌃⌥A list + a menu-bar colony monitor), **Sim** (iOS Simulator as a
> split / live mirror, agent-driven), **Browser** (docked Chromium, MCP-drivable),
> **Bridge** (the MCP engine), **Detox** (live-coding synth). Read those before
> building — they're the reference for everything below.

## Control surfaces
- ⚡ **Stream Deck / Raycast bridge** — physical buttons or launcher commands
  that `run`/`type` into a chosen pane. Basically pure HTTP.
- **Phone beam** — an `ntfy` / Apple Shortcuts relay so you can send text from
  your phone straight to a pane's prompt.
- **Voice commander** — dictation → `type` into the focused pane.

## Awareness / monitoring
- ⚡ **CI watcher** — poll GitHub Actions for each pane's repo; notify on red,
  and `type` the log-fetch command so the fix is one keystroke away.
- **Docker / K8s live board** — a pane that self-updates with container/pod
  status via `run` + `output` polling.
- **Cost meter** — track AI-feature token spend, post a daily summary via
  `/v1/notify`.
- **Secrets guard** — watch `output` for leaked tokens/keys; warn instantly.

## Workflow
- **Team snippets** — a shared command library synced from a git repo,
  injected via `type` (never auto-run).
- **Circadian themes** — rewrite the config theme by time of day; live-reload
  does the rest.
- **Project profiles** — on `cd`, apply a per-repo theme/font/shader from a
  `.term64` file.

## Built on the block/output model (bigger)
- **Session polaroids** — export a block as a share card (command + output +
  theme). A good API stress test using `output`.
- **Total recall** — a searchable local archive of everything ever run;
  "that docker DNS fix from October" → jump back into that cwd.
- **Live dashboards** — pin `run` outputs that refresh on an interval.

## Notes for us
- The heavyweight ideas in [`IDEAS.md`](IDEAS.md) (shadow runs, semantic zoom, ambient
  shader weather) stay *core* — they need the renderer/PTY, not the plugin API.
- Anything that only needs list-panes / type / run / output / notify should be
  a plugin, to keep the core small and prove the API in anger.
