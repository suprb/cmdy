# Terminal Demand and Product Direction, 2026

Research snapshot: 2026-07-11

## Method and limits

This is a product signal map, not a population survey. It combines:

- GitHub issue reactions and comments from major terminal emulators and terminal agents.
- Current official documentation for shipped terminal protocols and UI models.
- Cross-project repetition: a request is stronger when it appears independently in several products.

Reaction counts below are a point-in-time measure of visible demand, not comparable market share. Vendor feature pages prove that a capability exists; they do not prove that everyone wants it. The final section is explicitly an inference for Termite.

## What terminal-emulator users repeatedly ask for

### 1. Semantic scrollback, search, and navigation

The strongest conventional signal is that users no longer accept scrollback as an undifferentiated text dump.

- Ghostty's scrollback search request received 1,219 reactions: [ghostty#189](https://github.com/ghostty-org/ghostty/issues/189).
- Clickable file paths received 227 reactions: [ghostty#1972](https://github.com/ghostty-org/ghostty/issues/1972).
- Restoring scrollback with session state remains requested: [ghostty#1847](https://github.com/ghostty-org/ghostty/issues/1847).
- Warp groups a command and its output into an atomic block that can be copied, shared, bookmarked, and navigated: [Warp Blocks](https://docs.warp.dev/terminal/blocks).
- iTerm2 shell integration similarly makes commands selectable and exposes duration, status, resend, copy, and share actions: [iTerm2 command selection](https://iterm2.com/documentation-command-selection.html).

Product requirement: command-aware search, marks, failure navigation, durable command history, and scrollback restoration are baseline UX, not decoration.

### 2. Sessions, multiplexing, and workspace continuity

Users want the terminal to remember working state and interoperate with existing multiplexers.

- tmux control mode is Ghostty's largest open feature request, with 714 reactions: [ghostty#1935](https://github.com/ghostty-org/ghostty/issues/1935).
- The equivalent WezTerm request has 152 reactions: [wezterm#336](https://github.com/wezterm/wezterm/issues/336).
- WezTerm users also request saved layouts and draggable tabs/panes: [wezterm#3237](https://github.com/wezterm/wezterm/issues/3237), [wezterm#549](https://github.com/wezterm/wezterm/issues/549).

Product requirement: persistent windows, panes, working directories, running processes, and scrollback should restore as one workspace. tmux compatibility remains valuable even if Termite eventually provides a better native model.

### 3. Native ergonomics and direct manipulation

Requests repeatedly concern ordinary window behavior rather than exotic rendering.

- A drop-down/quick terminal is WezTerm's most reacted user feature request: [wezterm#1751](https://github.com/wezterm/wezterm/issues/1751).
- Tab/pane drag and drop, split layout control, window placement restoration, command palettes, and popup windows all recur in WezTerm and Ghostty issue lists.
- Smooth scrolling remains an explicit request: [wezterm#3812](https://github.com/wezterm/wezterm/issues/3812).

Product requirement: resize, scroll, selection, drag/drop, tabs, splits, fullscreen, and macOS conventions must feel native at every frame rate. GPU acceleration is only useful when these interactions are measurably smooth.

### 4. Correct text for every user

Unicode, IME, bidi/RTL, font shaping, DPI changes, and accessibility remain unfinished across the ecosystem.

- Ghostty has active requests for RTL, Indic shaping, and macOS accessibility correctness: [ghostty#1442](https://github.com/ghostty-org/ghostty/issues/1442), [ghostty#5637](https://github.com/ghostty-org/ghostty/issues/5637), [ghostty#9932](https://github.com/ghostty-org/ghostty/issues/9932).
- A Japanese IME defect was among Gemini CLI's most reacted UI issues: [gemini-cli#1796](https://github.com/google-gemini/gemini-cli/issues/1796).
- Kitty's current Unicode RFC tries to standardize terminal grapheme and cell-width behavior: [kitty#8533](https://github.com/kovidgoyal/kitty/issues/8533).

Product requirement: correctness across scripts, input methods, VoiceOver, multiple displays, and font fallback is part of performance and robustness, not a later accessibility pass.

### 5. Rich media and newer terminal protocols

Programs increasingly expect the terminal to carry more than same-size text cells.

- WezTerm's Kitty graphics protocol request received 107 reactions: [wezterm#986](https://github.com/wezterm/wezterm/issues/986).
- Kitty's graphics protocol supports images that scroll with text, alpha compositing, local shared-memory transport, and capability queries: [Kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/).
- Kitty now specifies multicell and fractionally scaled text while retaining the grid model: [Kitty text sizing protocol](https://sw.kovidgoyal.net/kitty/text-sizing-protocol/).
- Kitty is also defining drag/drop, file transfer, multiple cursors, notifications, pointer shapes, and richer clipboard data: [Kitty protocol extensions](https://sw.kovidgoyal.net/kitty/protocol-extensions/).

Product requirement: Kitty graphics/placeholders, image animation, OSC 8 links, OSC 133 semantics, modern keyboard reporting, and capability negotiation should compose correctly rather than exist as isolated checkboxes.

### 6. Customization without sacrificing speed

Background images, opacity controls, cursor trails, shaders, tab styling, and programmable status surfaces receive substantial demand. Examples include [ghostty#3645](https://github.com/ghostty-org/ghostty/issues/3645), [ghostty#5047](https://github.com/ghostty-org/ghostty/issues/5047), and [wezterm#7387](https://github.com/wezterm/wezterm/issues/7387).

Product requirement: visual expression matters, but every effect needs an explicit GPU budget and an off switch. Customization cannot regress latency, battery, text contrast, or accessibility.

## What agent-terminal users ask for in 2026

The important signal is not merely "put chat in the terminal." Users are asking for control over long-running, fallible software agents.

### 1. Hooks and automation

- Codex event hooks accumulated 689 reactions: [codex#2109](https://github.com/openai/codex/issues/2109).
- Gemini CLI's hooks request accumulated 103 reactions: [gemini-cli#2779](https://github.com/google-gemini/gemini-cli/issues/2779).

Need: typed lifecycle events for task start, tool use, approval, output, failure, completion, and notification. A terminal should expose these without scraping ANSI output.

### 2. Planning, review, and permission gates

- Plan mode requests received 503 reactions in Codex and 204 in Gemini CLI: [codex#2101](https://github.com/openai/codex/issues/2101), [gemini-cli#4666](https://github.com/google-gemini/gemini-cli/issues/4666).
- Excluding sensitive files received 458 reactions: [codex#2847](https://github.com/openai/codex/issues/2847).

Need: visible plans, scoped permissions, diff review, provenance, policy, and explicit transitions between read-only and mutating work.

### 3. Remote control and parallel agents

- Codex remote control received 535 reactions: [codex#9224](https://github.com/openai/codex/issues/9224).
- Codex subagent support received 414: [codex#2604](https://github.com/openai/codex/issues/2604).
- Gemini CLI has shipped local and remote subagent management and isolated tool registries: [Gemini CLI subagents](https://github.com/google-gemini/gemini-cli/blob/main/docs/core/subagents.md).

Need: a mission-control view showing parallel work, ownership, progress, blocked approvals, resource use, and a clean handoff between human and agent.

### 4. Reversibility and durable history

- Restoring `/undo` received 359 reactions, while a combined conversation-and-filesystem checkpoint request received 183: [codex#9203](https://github.com/openai/codex/issues/9203), [codex#11626](https://github.com/openai/codex/issues/11626).

Need: task checkpoints that bind transcript, commands, diffs, files, and process state. "Undo" must say exactly what it can and cannot restore.

### 5. Language intelligence and editor bridges

- Codex LSP integration has 493 reactions: [codex#8745](https://github.com/openai/codex/issues/8745).
- iTerm2 already exposes a broad Python API for controlling sessions, tabs, screens, selections, status components, and custom control sequences: [iTerm2 Python API](https://iterm2.com/python-api/).

Need: terminals should expose editor-quality symbols, diagnostics, diffs, and file locations without becoming a second-rate IDE.

### 6. Model choice, local execution, cost, and status

- Local/other model support received 159 reactions in Codex: [codex#26](https://github.com/openai/codex/issues/26).
- Notifications on completion received 203: [codex#3962](https://github.com/openai/codex/issues/3962).
- Visible context/token usage and unexpected token consumption also produce heavily reacted issues.

Need: model-independent sessions, local-first options, clear token/cost/resource meters, background completion notifications, and exportable histories.

## Existing approaches to UI inside terminals

The market currently has four layers:

1. **Character UI:** Ink, Textual, Bubble Tea, and Ratatui create component-like TUIs but still paint a cell grid.
2. **Semantic byte-stream extensions:** OSC 133 identifies prompt/command/output boundaries. Windows Terminal documents the same command-finished marker carrying an exit code: [Windows Terminal shell integration](https://learn.microsoft.com/en-ca/windows/terminal/tutorials/shell-integration).
3. **Rich paint protocols:** Kitty graphics and text sizing add images and typography while preserving the byte stream.
4. **Host widgets:** Wave places terminals, browsers, previews, editors, AI, and system views in resizable blocks. Its `wsh` command controls these graphical blocks from the shell: [Wave widgets](https://docs.waveterm.dev/widgets), [wsh overview](https://docs.waveterm.dev/wsh).

Warp's command blocks and Wave's host widgets are useful, but neither makes ordinary stdout a durable, typed object that another terminal can render consistently.

## The opportunity for Termite: living output with a fallback

The "fifth row" is credible, but replacing stdout with a component tree would discard the terminal's greatest strengths: pipes, logs, SSH, scripts, and fifty years of compatibility. The migration path should be additive.

### Proposed Termite Surface Protocol v0

The concrete transport, message model, native components, security boundary,
SSH behavior, replay rules, CLI shape, and staged implementation are specified
in [SURFACE_PROTOCOL.md](../../SURFACE_PROTOCOL.md).

1. **Text remains canonical.** Every command still emits useful stdout/stderr. Plain terminals, log files, and pipes continue to work.
2. **Negotiate capability.** `TERM_PROGRAM`, a capability query, and shell integration tell a client whether living surfaces are available.
3. **Keep bulk data out of the PTY.** A short escape sequence or environment token announces a surface ID. JSON Lines or CBOR patches travel over an authenticated Unix socket locally and a bounded forwarded channel remotely.
4. **Use a small host-owned vocabulary.** Start with table, tree, diff, form, timeline, task, media, and canvas. Termite renders these natively; arbitrary remote HTML is not the default security model.
5. **Preserve identity.** Stable node IDs let clients patch a row or progress value without repainting a screen. Events return to the originating process with surface ID, node ID, and action.
6. **Make semantics accessible.** Labels, roles, focus order, value/state, keyboard actions, and VoiceOver descriptions are part of the protocol.
7. **Bind trust and provenance.** Every surface shows its process, host, command block, permissions, and connection state. Remote content cannot silently gain local filesystem or browser access.
8. **Record and replay.** The command block stores the text fallback plus a bounded event log/snapshot so a surface can be restored without keeping its producer alive forever.

Termite already has useful foundations: OSC 133 command blocks, a GPU renderer, Kitty image placement, native plugin panels, Bridge, and docked Chromium/Simulator/app windows. The shortest prototype is not a general web runtime. It is a native live table/diff/task surface attached to a command block, with a CLI that reads JSON Lines and prints a text fallback when the protocol is unavailable.

Example direction:

```sh
git status --porcelain=v2 | termite surface table --id git-status --fallback=table
pytest --json-report | termite surface task --id tests --fallback=summary
terraform plan -json | termite surface diff --id infra-plan --require-approval
```

## New terminal uses this could unlock

1. **Agent mission control:** parallel agents become task lanes with plans, live tools, diffs, costs, permissions, and checkpoints instead of interleaved transcripts.
2. **Disposable interfaces:** an agent or CLI can materialize a purpose-built table/form/timeline for one task, while its text fallback remains scriptable.
3. **Live development objects:** a server, simulator, browser, test run, and logs stay attached to the command that created them and restore as a workspace.
4. **Data work without notebook lock-in:** pipelines return inspectable plots and tables, but the underlying commands and data remain reproducible shell artifacts.
5. **Rehearsable operations:** deployments and migrations expose a typed plan, policy checks, approvals, execution, and rollback as one replayable command object.
6. **Shared operational rooms:** collaborators and agents can join a workspace with scoped control and a durable, attributable event history.

## Recommended order for Termite

1. Keep latency, scrolling, resize behavior, Unicode/IME, accessibility, and compatibility as release gates.
2. Finish durable semantic blocks: search, restore, command metadata, links, failure navigation, and export.
3. Add typed agent lifecycle events, task lanes, approvals, cost/status, hooks, and checkpoints.
4. Prototype Surface Protocol v0 with native table, diff, and task components plus text fallback.
5. Only then add generated/custom components, remote forwarding, and multiplayer workspaces.

The defensible product thesis is not "a terminal with AI" or "a terminal with widgets." It is: **the fastest native terminal for text, plus the safest control plane for living processes and agents.**
