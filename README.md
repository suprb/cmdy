# cmdy

**A GPU terminal you can build on.** cmdy is fast and native to macOS, with its
own VT engine and every frame rendered through Metal. Its public platform has
resident Extensions and one-shot Actions; Channels complete the loop by
bringing work in from other applications and optionally sending the result back.
Detox, Swarm, Sim, Bridge, and Browser are first-party reference Extensions.
Browser activates Chromium in a real cmdy window split; its sandbox runtime is
already sealed inside the one signed macOS app.

## Quick start

Requires macOS 26+ on Apple silicon. Open the
[latest release](https://github.com/suprb/cmdy/releases/latest), download the
cmdy DMG, then drag `cmdy.app` to Applications. Install Browser and any other
optional capability from **View → Extensions…** (⌘⇧L).

If you installed cmdy 1.0.0, download 1.0.1 or newer manually once: 1.0.0
embedded the wrong GitHub owner, so that version cannot discover its own update.
Automatic updates resume after the manual upgrade.

To build from source, install Swift 6.2 / Xcode 26 and run:

```sh
git clone https://github.com/suprb/cmdy.git
cd cmdy
./package.sh
open cmdy.app
```

Read the complete [build and Browser release guide](BUILDING.md), then the
[architecture guide](docs/ARCHITECTURE.md) before changing a layer and
[CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request. Maintainers
should use [RELEASING.md](RELEASING.md) for signed builds and the
[open-source release checklist](docs/OPEN_SOURCE_RELEASE_CHECKLIST.md) for the
first public launch. Security reports follow [SECURITY.md](SECURITY.md).

## Platform

cmdy keeps its author-facing model to three layers
([overview](PLATFORM.md)):

| Layer | Status | Use it to |
|---|---|---|
| **Extensions** | Shipped | Listen continuously, change bounded behavior, and show native interfaces. |
| **Actions** | Shipped | Run a script, command, or multi-pane workflow from the menu, palette, or shortcut. |
| **Channels** | Shipped | Receive reviewable work from another app and explicitly return a reviewed result. |

```text
Extensions add capabilities.
Actions perform work.
Channels move work in and out.
```

Surfaces, live pane composition, Swarm, and the Marketplace support those layers
without becoming overlapping authoring systems. Read [Build cmdy Extensions](EXTENSIONS.md),
[Build cmdy Actions](ACTIONS.md), and [Build cmdy Channels](CHANNELS.md).

## Features

**Rendering**
- GPU (Metal) rendering, patched for crisp grid-snapped glyphs, a correctly-tracking
  cursor, and translucent backgrounds; ligatures are disabled so fonts like Geist
  Mono can't collapse `...` runs and break the cell grid; the grid is centered so
  left/right margins stay equal at any width; rendering pauses for occluded
  windows (no background GPU burn, instant re-focus)
- **Full-screen TUIs scroll**: the wheel is forwarded as SGR mouse events to apps
  that ask for it (Claude Code, htop, `vim`), and as arrow keys in the alternate
  screen (`less`, `man`) — plus classic scrollback in the primary buffer
- **Programmable shaders** — an optional gallery of Metal post-process passes,
  plus one-function user shaders that compile and hot-reload at runtime. Static
  passes repaint only with the terminal; animated passes throttle in the background
  and stop when occluded, under thermal pressure, or in Low Power Mode
- **Smooth cursor**: the cursor glides between cells, with configurable chase
  speed and a maximum animated jump (`smooth-cursor`, `cursor-glide-speed`,
  `cursor-glide-max-distance`)
- **Inline images**: iTerm2 (`imgcat`), Kitty graphics, and sixel all render on the GPU;
  `cmdy show photo.png` works out of the box via shell integration
- Chromeless C64 window: uniform border, small macOS-style traffic lights,
  compact title (`cwd · cols×rows`), and a complete configurable window inset
- Native macOS tabs retain system selection, reordering, tear-off, overview,
  keyboard navigation, and accessibility in every chrome configuration
- Window **opacity + blur** (frosted glass over whatever's behind)
- Native View-menu presets for window inset and opacity, plus live toggles for
  blur, border, compact toolbar, and window buttons
- **35 bundled fonts** (all redistributable — OFL / UFL / CC / public domain): the full
  Monaspace family (Neon, Argon, Xenon, Radon, Krypton), Martian Mono, Geist Mono,
  JetBrains Mono, Fira Code, Cascadia Mono, Iosevka Term, JuliaMono, Intel One Mono,
  Server Mono, Fragment Mono, M+ 1 Code, Ubuntu Sans Mono, Commit Mono, iA Writer
  Mono/Duo/Quattro, Departure Mono, Pixel Code, Monocraft — plus the retro pack:
  Fixedsys Excelsior, Glass TTY VT220, and nine Ultimate Oldschool PC faces
  (IBM BIOS, IBM VGA, Phoenix EGA, AST, Sanyo, Toshiba, Nix8810, DOS/V…).
  `--fonts` lists them all; adjustable line spacing
- **SID sounds** (optional): keypress blips + a falling error buzz, synthesized square waves

**Themes**
- 17 built-ins: the C64 originals (C64, Dark, Amber, Green, Light), pure monochrome
  B/W and W/B, plus faithful ports of Dracula, Nord, Catppuccin Mocha, Gruvbox Dark,
  Tokyo Night, Solarized Dark & Light, Monokai, Rosé Pine, One Dark
- **User themes**: drop a JSON file in `~/.config/cmdy/themes/` and it appears in the
  Theme menu (and overrides a built-in of the same name)
- **Pane-owned appearance**: right-click any terminal pane to give it its own
  theme, shader, and font. The spatial first pane drives that tab's complete
  native window chrome, so switching tabs switches the whole window look;
  split, tear-out, grid, and window conversions retain each live pane's look

**Configuration**
- Ghostty-style plain-text config at `~/.config/cmdy/config` (`key = value`)
- **Live reload**: save the file and every open terminal updates instantly
- **Two-way sync**: menu/palette changes are written back into the file in
  place (comments preserved) — what you pick is what comes back after relaunch
- `Settings…` (⌘,) opens it (writing a commented template on first use); the
  View-menu pickers show their current value in the title ("Font — Geist Mono")

**Text editor**
- cmdy includes a focused native editor for config, Markdown, source, and
  plain-text files: the terminal font and theme, soft word wrapping, vertical
  scrolling, undo, find, atomic UTF-8 saves, and unsaved-change protection
- It opens as its own cmdy-style window or directly beside a shell with
  **File → Open in Terminal Split…**. Attach/detach moves the same document view,
  so it resizes synchronously with the terminal and never needs a sidecar window.
  Drag an editor's title band onto a terminal to choose its split edge; standard
  Cut, Copy, Paste, Select All, Undo, Redo, and Find commands stay with the editor
- There is deliberately no file tree: files still come from the shell, `⌘O`,
  Finder's **Open With**, or drag/open workflows. Set `editor = system` or an
  editor command such as `code --wait` to replace the built-in default

**Splits, tabs & windows**
- **Split panes**: ⌘D right, ⌘⇧D down, arbitrarily nested; ⌘] / ⌘[ cycle focus
  spatially (top-to-bottom, left-to-right); ⌘W closes the focused pane (the window
  when it's the last one)
- **Drag-to-dock**: drag any window — or a tab torn out of a tab bar — over
  another cmdy window and drop zones light up: left/right/top/bottom edges
  split, center adds a tab. Shells keep running through every merge
- **Merge windows**: Window ▸ Merge With picks a specific window + direction;
  Merge All pulls everything together as tabs or as splits in one window
- **Float on top** (⌥⌘F): keep a terminal above every other app; survives restart
- Tabs (⌘T) & windows (⌘N) — panes, tabs and windows all inherit the current directory
- Drag a file/folder in → its shell-escaped path is inserted

**Adaptive Frame**
- A restrained **Tabs sidebar** on the left shows one row per native tab,
  including pane counts and running or waiting state
- Tabs have exactly one visible home: opening the sidebar hides AppKit's tab
  bar; closing the sidebar restores the native bar for multi-tab windows
- A contextual **Inspector** on the right follows the focused pane, selection,
  last command, exit/duration, and Git branch/working tree, with direct copy,
  rerun, explain, status, and refresh actions
- AppKit's native sidebar/content/inspector split shell owns resizing, dividers,
  materials, and accessibility; SwiftUI renders the two contextual columns.
  The Inspector yields first on a narrow window, and expanding restores it
  without changing preferences
- **Focus Mode** hides both columns and gently recedes non-focused splits while
  preserving every live process and layout
- Extensions can add host-rendered Tabs-sidebar or Inspector sections through a
  bounded declarative API. They inherit the current theme, terminal typography,
  keyboard model, native layout behavior, ownership, and process-exit cleanup

**Command blocks** (the "more than a terminal" part, via OSC 133 shell integration)
- Jump between commands (⌘↑ / ⌘↓); clicking a marker types that command at
  your prompt (nothing runs until you press Enter)
- **Minimal status**: success is silent (just a faint separator); failed rows use
  the theme's failure background and text colors without adding a permanent gutter
- **Ambient fix hints**: use a failed row's fix action and the corrected
  command (AI) is typed at your prompt
- Markers, separators and per-command durations **survive font zoom and window
  resizes** — anchors ride the reflow through logical-line indices
- Blocks menu lists recent commands with status → click to jump
- Copy last command's output (⌘⇧C)
- **Finished-while-away notifications**: a command over 5s that ends while you're in
  another app bounces the dock / posts a banner

**Smart input**
- **Ghost-text autocomplete**: fish-style dimmed suggestion from your history
  (~/.zsh_history + everything you run), drawn inline at the cursor — accept with →
- **Session restore**: quit and relaunch, and every window, split, working directory
  and recent scrollback comes back (`restore-session`)
- **Named Workspaces**: File → Workspaces can save a new snapshot, update it,
  reopen it beside the current windows, rename it, or delete it. Workspaces keep
  tab groups, split geometry, Window Grid, pane appearance, directories, and
  capped scrollback without copying credentials or implicit commands

**Command palette** (⌘⇧P)
- Fuzzy search over every action, theme, font, cursor style, toggle — and the current
  pane's recent commands (re-run straight from the palette)
- Settings preview as you move. Return keeps a setting without closing its section,
  Escape goes back (or closes at the root), and one-shot actions run and close

**Command intelligence**
- **Ask from the prompt** — type `what time is it` and press Return. Clear
  natural-language requests route to cmdy instead of zsh; ⌘Return inserts
  the proposed command and ordinary Return runs it. Prefix an ambiguous request
  with `#` only when you explicitly want cmdy to translate it.
- **Automatic error help** — on by default; set `automatic-error-help = false`
  to disable it. A failed
  command gets a soft text-only explanation directly below its output, before the next
  prompt. It is part of the terminal transcript, with no panel, icons, or mouse step.
  Use ⌘⇧X when you want a proposed fix inserted for review.
- Common failures resolve instantly; unfamiliar ones use Apple Intelligence
  on-device, then an explicitly configured Anthropic model.
- **Agent mode** (⌘⇧A) — give it a goal; it proposes one command at a time, typed at
  your prompt. *You* press Enter to run each step (edit it first if you like); output
  and exit codes feed back automatically until the goal is done. Nothing auto-executes.
- **Explain last command** (⌘⇧E) — command + output + exit code → what happened
- **Compose** (⌘⇧K) — describe what you want; the command is typed at your prompt
  for review (never run for you)
- **Fix last failed command** (⌘⇧X) — the corrected command, typed at your prompt

**Actions** — personal scripts, commands, and pane workflows
([ACTIONS.md](ACTIONS.md))
- Drop a supported script in `~/.config/cmdy/actions/` and it appears in the
  native Actions menu and command palette; add `action.json` for inputs, choices,
  confirmation, context rules, app-scoped shortcuts, and multi-pane workflows
- Project Actions live in `.cmdy/actions/` and require the same explicit project
  trust as Extensions. Entrypoints cannot escape their Action folder
- Install five editable workflows with **Install Starter Actions…**, build from
  the UI with **Create Sample Action** or **Save Last Command as Action…**, or
  use `cmdy action install-starters`, `new`, `validate`, `list`, and `run`
- Actions execute through real pane input, so commands remain visible and keep
  ordinary stdout, command blocks, history, and Extension hooks

**Channels** — selected work in, reviewed results out
([CHANNELS.md](CHANNELS.md))
- Install a capability-scoped connector Extension, or scaffold one with
  `cmdy channel new`; the typed Swift SDK and language-neutral HTTP API both
  cover registration, idempotent Work Item ingestion, replies, and delivery acks
- Review external work in the native Channels menu or command palette, then read,
  ignore, complete, start Agent Mode, or stage one shell command without running it
- Agent summaries and shell command-block results become private drafts. Sending is
  a separate confirmation, and only the owning connector receives the queued reply
- Marketplace installs expose a native guided setup form. Ordinary settings go to
  a private connector config file, secrets go to Keychain, and **Skip Setup** keeps
  the connector stopped until you are ready. **Configure Installed Channel** is
  always available later; it tests provider health and enables only a healthy setup
- **Channel Doctor** separates connector-process state from provider health and
  shows retries, failures, and replies whose delivery must be verified before a
  duplicate-risk retry
- Channel connectors can be shared with `kind: channel` in the Marketplace.
  First-party packages cover chat, issue trackers, mail, feeds, webhooks, local
  folders, Git, the clipboard, commands, iMessage, and Apple Reminders; provider
  accounts and credentials are never bundled or silently connected
- The Marketplace's credential-free **Demo Inbox** exercises Receive, Route,
  and Reply without connecting an external account
- There are no Automations or automatic replies in v1

**Detox — a live-coding modular synth, inside the terminal** (a first-party Extension,
included as an example of what the SDK can carry — remove or disable it like any other)
- ⌘⇧P → "Detox Editor…": an inline multi-line editor over your shell. Write a
  pattern in the codio DSL (`seq([C3,..,E3,G3], 8) -> osc(sine) -> lpf(1200) ->
  reverb(0.3) -> out` — oscillators, step sequencers, LFOs, named mixer buses,
  effects), hit **⌘⏎**, and generative audio plays behind your work; esc hides
  the editor while the music keeps going. The buffer autosaves
  (`~/.config/cmdy/audio/session.detox`). The engine is the author's own
  codio/DETOX WebAudio engine, embedded verbatim. Toggle the Extension off like
  any other.

**Extensions** — cmdy is open without putting third-party code in the hot loop
([EXTENSIONS.md](EXTENSIONS.md), [protocol](EXTENSION_PROTOCOL.md))
- An Extension is any executable that speaks authenticated HTTP/JSON. A v1
  `manifest.json` declares its entrypoint and exact capabilities; cmdy mints a
  scoped token and enforces every route. Installed Extensions live in
  `~/.config/cmdy/extensions/<name>/`
- The model is **Listen. Change. Show.** Listen to semantic events; influence
  command submission, paste, splits, close, and notifications through bounded,
  fail-open decision hooks; show Adaptive Frame contributions, transient panels,
  native Surfaces, or attached apps
- **Native Surfaces** ([SURFACE_PROTOCOL.md](SURFACE_PROTOCOL.md)): live lists,
  tables, diffs, tasks, forms, and text attached to command blocks. cmdy owns
  rendering and accessibility while stdout remains canonical and pipeable
- **Project Extensions** live in `.cmdy/extensions/`, run only after explicit
  project trust, and stop after the last pane leaves the project
- **Development loop**: `cmdy extension new`, `validate`, `dev`, and `install`;
  `dev` captures logs and restarts on save. The Swift SDK is optional
- **Extensions window** (⌘⇧L): see each Extension's purpose, creator, installed
  version, runtime state, and public source; download, update, or remove it from the same row, or
  install every first-party Extension in one consented action. Enable or disable each
  live process immediately with no relaunch
- **Bridge**: an external, product-scale MCP runtime with **93 tools** across
  Chrome, macOS, iOS Simulator, and native-app targets. It reconciles panes over
  `/v1/panes`, registers commands, consumes lifecycle events, and proves that a
  Extension can be an entire product without private host access
- **swarm** (⌃⌥A): every AI session across every window and split in one list —
  which agent runs where (◆), who's waiting for you (●), pick one to jump there.
  Plus a menu-bar presence (`◆ 3`, amber `● 2` when a session needs you) that
  tracks the whole colony from any app or Space. **Gather Agent Sessions…** lets
  you select agents—or take all of them—and moves their live panes into one new,
  automatically arranged terminal window without restarting a process
- **Sim**: control iOS Simulator directly, or stream serve-sim as a resizable
  live mirror in the same built-in Browser split—an agent builds, runs, taps,
  and screenshots a real SwiftUI app in a loop while you watch it change
- **Browser**: an installable, disableable, and removable Extension that opens
  sandboxed Chromium as a real split inside the cmdy window. CEF and its signed
  workers stay sealed in the notarized app; the Extension controls whether the
  runtime loads. Install it from Extensions or the Browser toolbar, and remove
  or reinstall it from the same place.

**Marketplace** ([MARKETPLACE.md](MARKETPLACE.md)) — a public registry of shaders,
themes, rigs (whole-look presets), and Extensions; browse and install from the palette
("Browse the Marketplace…"), use **Install All…** in the Extensions window, or run
`cmdy marketplace install-all --yes`. Marketplace-installed Extensions are checked
for new registry versions at most daily; badges and a one-time notification point to
the existing reviewed update flow. Disable this with `marketplace-update-checks = false`.
Registry: `github.com/suprb/cmdy-registry`

**Find**
- ⌘F searches the scrollback (Enter next, ⇧Enter previous, Esc closes) with a
  current/total match counter and case-sensitivity (`Aa`) + regex (`.*`) toggles

## First-party Extensions (external, SDK-built)

None of the first-party Extensions are compiled into the app — they're external
processes built purely on the public SDK, exactly like a third party would ship
them. They're bundled as **examples of what the SDK can carry**, not as features
of the terminal; remove or disable any of them like any other Extension:

```sh
./plugins.sh    # builds Plugins/{detox,bridge,swarm,sim} (+ Browser/chromium
                # only for an explicitly ad-hoc source build) and installs into
                # ~/.config/cmdy/extensions/ (manifest.json + executable).
                # Bridge and Sim (plus an ad-hoc local Browser) register MCP shims with
                # installed Claude Code and Codex clients so an agent in ANY
                # directory can drive them (user scope; restart the agent).
```

Before an interactive `claude`, `codex`, or `pi` launch, cmdy checks every
enabled first-party integration. The same preflight runs when a local Browser, Sim /
Sim Mirror, or Bridge opens after an agent is already running. Missing MCP
registration, stopped Extensions, and Claude `dontAsk` permission rules are
reported separately; selecting **Fix setup** makes only the named changes and
backs up edited config files. Pi support uses the optional
`npm:pi-mcp-adapter`, which cmdy names before offering to install it.
Open **Integration Doctor…** from the command palette, or ask cmdy to
“check Browser MCP setup,” to run the checks at any time.

`Plugins/CmdySDK` is the optional Swift client library they're built on. It
has no private authority; use it for your own Extension, or speak the public HTTP
API directly from any language ([EXTENSIONS.md](EXTENSIONS.md)).

## Internal embedding experiment: lib_cmdy

> **Status: internal only.** `lib_cmdy` is unreleased, is not distributed as
> a supported public library, and is not part of the public Extension SDK. Its C ABI
> currently has no compatibility or binary-stability guarantee.

The Extension SDK changes a running cmdy application. `lib_cmdy` explores a
different problem: embedding cmdy's headless terminal model inside another
product through a plain C ABI.

The host creates a grid, feeds it raw VT bytes, and reads back text, styled
cells, cursor position, scrollback, dimensions, and OSC 133 command blocks.
`lib_cmdy` owns parsing, terminal state, resize/reflow, and semantic blocks;
the host owns the shell or remote process, PTY I/O, keyboard input, rendering,
and synchronization. That makes it suitable for IDE terminals, agent runtimes,
remote-session viewers, deterministic test harnesses, and custom renderers.

```c
cmdy_t t = cmdy_create(80, 24);
cmdy_feed(t, bytes, len);
cmdy_resize(t, 120, 40);
cmdy_cell(t, row, col, &cp, &width, &fg, &bg, &style);
cmdy_free(t);
```

The production CmdyCore engine sits behind this boundary, but the internal C
ABI remains a deliberately small, single-threaded, macOS-only spike. See
`Core/include/cmdy.h` and the complete
`Core/Demos/cat-grid.c` example.

## Development builds

Run directly without assembling an app bundle:

```sh
swift build -c release && .build/release/cmdy
```

cmdy runs unsandboxed because it spawns a PTY. `./package.sh` remains the
authoritative local app-bundle build.

The packaged app checks GitHub's latest stable Release at most every 12 hours.
When a newer numeric version exists, cmdy automatically downloads the matching
macOS ZIP into its cache and keeps it only when the release's SHA-256 checksum
passes. **cmdy → Check for Updates…** shows download, retry, and ready states and
reveals the verified ZIP in Finder. cmdy never executes the archive, replaces
the running app, or relaunches without the user.

Publish a committed version through the signed and notarized GitHub Actions
path with one command:

```sh
./publish-release.sh 1.2.0
```

The command requires a public release repository, dispatches the workflow,
watches it finish, and prints the new GitHub Release URL. See
[Releasing cmdy for macOS](RELEASING.md) for certificate and notary setup.

### Product identity and future renames

For the complete name, logo, repository, migration, packaging, notarization,
and rollback procedure, follow [Rebranding cmdy safely](docs/REBRANDING.md).

The canonical public name lives in exactly one manifest:

```text
Identity/Sources/ProductIdentity/Resources/product-identity.json
```

App/executable names, config and project directories, environment prefixes,
MCP server names, first-party Extension installers, updater URLs, GitHub release
assets, DMG names, and package metadata derive from that manifest. Internal
Swift module/type names stay stable so a marketing rename does not become an
unrelated engine or API migration.

Use the migration-aware command rather than editing scattered files:

```sh
./scripts/rename-product.sh "New Name"
./scripts/check-product-identity.sh
./test.sh
./package.sh
```

The command records the former name as a compatibility alias. Existing config
folders and old Extension environment variables therefore continue to work.
The bundle and code-signing identifier namespaces are intentionally explicit,
stable fields in the same manifest: keeping them stable preserves macOS
preferences, Accessibility permissions, install receipts, and update identity.

## Website

The public home, documentation, and Marketplace pages are a React/Vite project
in `site/`. Durable static inputs live in `site/public/`; each production build
replaces the ignored local `site/dist/` directory with a clean generated
artifact. GitHub Pages performs the same verified build during deployment. The
three public routes remain `index.html`, `docs.html`, and `marketplace.html`.

```sh
cd site
npm ci
npm run dev       # http://127.0.0.1:4173
npm run build     # type-checks, then cleanly regenerates ./dist
```

Full-length recording masters stay local under the ignored `site/media/`
directory; only optimized public clips are committed. Selected terminal UI
patterns are adapted from
[SRCL / Sacred Computer](https://github.com/internet-development/www-sacred)
under MIT; see `site/THIRD_PARTY_NOTICES.md`.

**Error explanations** always have a private built-in fallback. Command translation,
Compose, and fix proposals prefer Apple Intelligence on-device, then use Anthropic
only when a key is explicitly configured. Agent mode still needs that key: put
`anthropic-api-key = sk-ant-…` in `~/.config/cmdy/config` (works for Finder/Dock
launches), or export `ANTHROPIC_API_KEY`. Its model is configurable via `ai-model`.

## Configuration

`~/.config/cmdy/config` (created by ⌘,):

```ini
theme = Light
font-family = FragmentMono-Regular
font-size = 13
line-height = 1.15
text-rendering = high-contrast
editor = cmdy            # cmdy | system | a command such as code --wait
scroll-speed = 1.5
cursor-style = block        # block | bar | underline
cursor-blink = true
option-as-meta = true
shell-integration = true
clean-prompt = true
hide-traffic-lights = false # AppKit's native window controls
margin = 10
workspace-navigator = false
workspace-inspector = false
opacity = 1.0               # 0.3 (glass) … 1.0 (solid)
blur = false                # frost what's behind the window
shader = None               # 68 to pick from — CRT | VHS | Matrix | Fire | Grid |
                            # Starfield | Copper | Tunnel | Drift | Breath | … the
                            # text-only Databloom reacts only while scrolling;
                            # the calm set drifts slow and cheap; View ▸ Shader ▸
                            # Browse with Preview… to try them live
smooth-cursor = true        # cursor glides between cells (GPU only)
cursor-glide-speed = 1.6    # 0.1 slow ... 8.0 nearly instant
cursor-glide-max-distance = 0 # largest animated jump in cells; 0 = unlimited
smooth-scroll = true
ghost-text = true           # inline history suggestion, → to accept
sounds = false              # SID keypress blips + error buzz
restore-session = true      # bring everything back on launch
automatic-error-help = true # inline explanation + keyboard-reviewed fix
marketplace-update-checks = true # daily only after a marketplace Extension install
anthropic-api-key = sk-ant-…   # optional cloud fallback + Agent
ai-model = claude-sonnet-4-6
```

Save and watch every open terminal restyle itself. A user theme at
`~/.config/cmdy/themes/mytheme.json`:

```json
{
  "name": "My Theme",
  "background": "#1e1e2e", "foreground": "#cdd6f4",
  "cursor": "#f5e0dc", "border": "#313244",
  "ansi": ["#45475a", "#f38ba8", "#a6e3a1", "#f9e2af",
           "#89b4fa", "#f5c2e7", "#94e2d5", "#bac2de",
           "#585b70", "#f38ba8", "#a6e3a1", "#f9e2af",
           "#89b4fa", "#f5c2e7", "#94e2d5", "#a6adc8"]
}
```

## Keybindings

cmdy carries the current standard Ghostty macOS keymap as a compatibility
layer. “Performable” shortcuts such as copy, selection adjustment, search
navigation, and undo fall through to the running program when cmdy has no
app action to perform. Native tab behavior remains AppKit-owned.

**Tools → Keybindings** imports Ghostty, tmux, iTerm2, or macOS Terminal
maps. A complete preview marks ready translations, unsupported actions,
malformed rows, and native/imported conflicts before Apply. Imports never
replace macOS or existing cmdy shortcuts and have Undo and Reset. See the
[keybinding import reference](docs/KEYBINDING_IMPORT.md).

| Key | Action | Key | Action |
|-----|--------|-----|--------|
| ⌘N / ⌘T | New window / tab | ⌘W | Close pane / window |
| ⌘O / ⌥⌘O | Open text file / open in split | ⌘S / ⇧⌘S | Save / Save As |
| ⌥⌘N | New text file | File menu | Attach or detach editor |
| ⌘D / ⌘⇧D | Split right / down | ⌘] / ⌘[ | Next / previous pane |
| ⌘⇧P | Command palette | ⌘F | Find in scrollback |
| ⌘↑ / ⌘↓ | Prev / next command | ⌘⇧C | Copy last output |
| ⌘⇧A | Agent mode (AI) | ⌘⇧K | Compose command (AI) |
| ⌘⇧E | Explain last (AI) | ⌘⇧X | Fix last failed (AI) |
| `# request` + ↩ | Propose a command | ⌘↩ | Insert proposed command |
| → | Accept ghost suggestion | ⌘K | Clear |
| ⌘, | Settings (config file) | ⌘+ / ⌘- / ⌘0 | Font size |
| ⌃⇧Tab / ⌃Tab | Previous / next tab | ⌘1…⌘8 / ⌘9 | Tab by index / last tab |
| ⌘⇧[ / ⌘⇧] | Previous / next tab | ⌘⌥W | Close current tab |
| ⌘⇧W / ⌘⌥⇧W | Close tab group / all windows | ⌘Z / ⌘⇧Z | Undo / redo recent close |
| ⌘↩ / ⌃⌘F | Fullscreen | ⇧⌘↩ | Zoom focused split |
| ⌥⌘←↑↓→ | Focus split by direction | ⌃⌘←↑↓→ | Resize split 10 points |
| ⌃⌘= | Equalize splits | ⇧←↑↓→ | Extend an existing selection |
| ⇧Home / ⇧End | Extend to row edge | ⇧Page Up / Down | Extend by one page |
| ⌘Home / ⌘End | Scroll top / bottom | ⌘Page Up / Down | Scroll one page |
| ⌘E | Search selected text | ⌘G / ⇧⌘G | Next / previous match |
| ⇧⌘F / Esc | End active search | ⌘J | Scroll selection into view |
| ⌘← / ⌘→ | Shell line start / end | ⌥← / ⌥→ | Shell word back / forward |
| ⌘⌫ | Delete shell input line | ⇧⌘V | Paste selected terminal text |
| ⇧⌘J | Export screen and insert path | ⌃⇧⌘J / ⌥⇧⌘J | Copy path / open export |
| ⌥⌘N / ⌥⌘I | Tab Sidebar / Inspector | ⌥⇧⌘F | Focus Mode |
| ⌘A | Select all terminal content |  |  |

Themes, fonts, line spacing, cursor, and toggles also live in the **View** menu.

## Record a feature tour

Open and focus the cmdy pane you want to film, start a macOS window recording,
then drive it from another terminal:

```sh
scripts/record-tour.sh --list
PACE=1.15 scripts/record-tour.sh
CHAPTERS=terminal,surfaces,platform scripts/record-tour.sh <pane-id>
```

The tour uses the authenticated local Extension API, preserves and restores the
config file, and skips unavailable optional tools. Set `SIDECARS=1` to include
the companion-app chapter.

## Architecture

Ghostty-shaped: a platform-free core, packages around it, a thin app shell.

```
cmdy/
├─ Core/       CmdyCore — the VT engine, pure Swift (parser · buffer ·
│              reflow · BLOCKS and INSETS as native structures · record/replay)
│              + CmdyPTY (fork/exec + read loop) + lib_cmdy (internal C ABI experiment + demo)
├─ Renderer/   CmdyGPU — the Metal two-pass pipeline, 68-shader gallery,
│              user-shader runtime; consumes any engine via MetalRenderSource
├─ Kit/        CmdyKit — inline panels, Surfaces, palette, config engine,
│              capability-scoped Extension bus, sessions, themes, bundled fonts
├─ App/        the shell: windows/tabs/splits, menus, panes, engine surfaces
├─ Plugins/    CmdySDK + detox + bridge + swarm + sim (external Extensions),
│              chromium host-component source, and the parked appdock
├─ site/       React/Vite source for the public home, docs, and Marketplace;
│              generated Pages output lives in the ignored site/dist/
└─ Tests/      parked differential oracle (Tests/ORACLE.md, DIVERGENCES.md) ·
               replay corpus · TUI-zoo driver · perf-gate.sh (frame budgets)
```

CmdyCore is the engine — grown against a vendored SwiftTerm oracle
(differential-tested byte for byte, 79 fixtures + recorded sessions + seeded
fuzzing) until the reference could be deleted; every divergence ever found
is locked into `Tests/corpus/regressions/` and replayed by the Core tests.
Key modules: `TerminalWindowController` (window chrome + split-pane tree),
`TerminalPane` (one session: view + blocks + ghost text + OSC wiring), `Blocks` +
`ShellIntegration` (OSC 133 + access to the `cmdy` CLI), `ConfigFile` (parse/apply/watch),
`SessionStore` (persistence), `Theme` (registry + user themes), `HistoryStore`
(ghost-text suggestions), `CommandPalette`, `FindBar`, `AIKit` + `AIComposePanel` +
`AgentKit` (Anthropic Messages API), `Notifier`, `Retrobleeps` (sound synthesis),
`FontLoader`, `IconGenerator`.
Diagnostics: `--selftest` (35+ unit checks), `--scroll-test` (scrollback holds under
streaming output), `--wheel-test` (wheel → SGR mouse / arrows / scrollback routing),
`--reflow-test` (block anchors survive zoom + resize reflows), `--graphics-test`
(kitty + sixel decode and placement), `--ai-test`, `--make-iconset`.
Engine verification: `./test.sh` runs every suite; the Core tests replay the
full regression corpus (every fuzz divergence ever caught, plus recorded real
sessions) deterministically; `Tests/zoo.sh` drives vim/htop/less/man/tmux/
Claude Code in a live window over the Extension SDK and screenshots every
station. The retired SwiftTerm differential oracle lives on as a parked
binary (`Tests/ORACLE.md`); its last 3.8-day soak found zero core bugs
(`Tests/DIVERGENCES.md`). Performance is defended by `Tests/perf-gate.sh` —
an isolated instance driven over the Extension API, asserting frame budgets
(idle = 0 frames, a prompt edit rebuilds 1 row, shaders ride their fps bands).

## Roadmap

cmdy's thesis: a fast GPU terminal can expose a programmable policy and interface
layer without giving up the terminal's byte-stream contract or hot-loop isolation.
Landed: the dedicated CmdyCore VT engine, Metal rendering, the capability-scoped
HTTP/SSE Extension Protocol, deterministic decision hooks, project trust, live
development, native Surface Protocol, programmable Actions, the Channels SDK and
durable Work Inbox/Outbox, marketplace, four external first-party reference
Extensions plus the Browser app edition,
live pane composition, command blocks, splits, palette, live config, themes,
ghost text, agent mode, session restore, and a defended performance gate.

The first-party registry now exercises nineteen credential-free, provider, and
local-workflow Channel packages through a permanent fake-provider integration
suite. Delivery attempts are persisted before the provider call, ambiguous
timeouts require verification instead of blind retries, and provider health is
reported separately from connector-process state. The next Channel work is
field testing and community connectors, not an Automations layer. Other future
work remains additive: richer Surface adapters, remote
forwarding that preserves SSH portability, record/replay, configurable keybindings,
live session sharing, stronger OS sandbox profiles, and continued PTY/Metal
throughput work. The deliberate replacement of the remaining SwiftTerm-derived
implementation is tracked in
[`docs/roadmap/INDEPENDENT_TERMINAL_STACK.md`](docs/roadmap/INDEPENDENT_TERMINAL_STACK.md),
with the current file-level inventory in
[`docs/roadmap/SWIFTTERM_PROVENANCE_AUDIT.md`](docs/roadmap/SWIFTTERM_PROVENANCE_AUDIT.md).
