# Changelog

All notable changes to cmdy will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project intends to follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Public APIs and protocols follow semantic versioning. Breaking changes should
be called out here with a migration path before a versioned release.

## [Unreleased]

### Added

- A small badge in the window's corner when a newer version is available.
- Restart to update: the downloaded, checksum-verified release is checked for
  the same Developer ID and Gatekeeper acceptance, installed in place and
  reopened, with the old version restored if the new one doesn't start.

## [1.0.11] - 2026-10-15

### Changed

- The pane, tab and window keys are built in and always on; the separate
  keymap setting and its View → Terminal menu items are gone. The 1.0.10
  modifier setting is now `pane-key-modifier = command` to hold ⌘ instead
  of Alt.
- While tmux, herdr, zellij or screen runs in a pane, the pane keys and the
  Ctrl+Space prefix pass through to it.
- Session restore is off by default: cmdy starts with one fresh window. Set
  `restore-session = true` to bring windows, splits and scrollback back.

## [1.0.10] - 2026-10-15

### Added

- tmux-style pane, tab and window keys with the Ctrl+Space prefix, including
  breaking a pane into a tab (`prefix !`) and joining it back (`prefix @`),
  moving and renaming tabs, and switching windows; the Alt keys can move to ⌘.
- Copy on select, on by default: a dragged, double-clicked or
  triple-clicked selection goes straight to the clipboard. Turn it off in
  View → Terminal → Copy on Select, or with `copy-on-select = false`.

### Fixed

- A click reliably dismisses a text selection, including small trackpad
  movement, clicks in apps that use the mouse, and clicks in the padding.
- Update checks find new releases when the GitHub API is rate-limited or
  blocked, and say so when they cannot check.

## [1.0.9] - 2026-10-13

### Fixed

- Images from terminal multiplexers such as herdr are drawn at their intended
  size and crop instead of oversized, and an image that moves while a pane
  scrolls no longer leaves stale copies behind.
- Failed-command highlighting and command separators no longer paint over
  full-screen apps on the alternate screen, so TUIs inside cmdy stay clean.

## [1.0.8] - 2026-10-11

### Changed

- Faster terminal response across the board. Keystrokes, full-screen apps,
  scrolling, paste and resize now reach the display sooner: a keystroke lands in
  about 10 ms and a resize redraws in about 49 ms on a 120 Hz MacBook Pro.
- The first window and its login shell start during app launch, and launch work
  stays off the first frame's path; the first complete frame appears in about
  0.33 s.
- Animated shaders tick from the display link and run at the display rate in a
  focused window, removing stutter on 120 Hz displays.
- Lower idle cost: cursor frames reuse exact cached pixels, temporary cursor
  backing is released, and an idle window uses about 0.09% of one core.
- Session recovery, settings and command workflows are more reliable.

### Fixed

- The bottom terminal row is no longer clipped.
- Browser component swaps no longer call the GitHub API.

## [1.0.7] - 2026-09-05

### Fixed

- Browser installation and removal now resolve stable-named ZIPs under the
  matching immutable app release instead of calling GitHub's unauthenticated,
  rate-limited latest-release API, preventing `HTTP 403 for latest` on managed
  networks while preserving compatibility with stale Marketplace caches.
- Manual release-workflow dispatches now default to a prerelease candidate, so
  a notarized work-Mac build can be accepted before it is promoted to latest.

## [1.0.6] - 2026-09-04

### Fixed

- Browser downloads now show persistent byte and percentage progress, followed
  by an explicit restart notice instead of disappearing without explanation.
- If the replacement Browser app exits before startup confirmation, cmdy now
  detects it promptly, restores the previous app, retries reopening it, and
  preserves an explanation for the next manual launch if macOS refuses.
- Cancelling a Browser restart to protect unsaved editor work now shows the
  paused state and clears the Extensions UI after the safe rollback.
- The embedded Browser divider now has a real 16-point drag target above the
  native Chromium child view instead of an effectively one-pixel target.

## [1.0.5] - 2026-09-04

### Fixed

- Browser installation now recognizes the hardened-runtime flag in Apple's
  real Developer ID `codesign` output, so a valid notarized Browser app is no
  longer falsely rejected during the restart-safe app swap.

## [1.0.4] - 2026-09-04

### Added

- Installing Browser now downloads the complete notarized Browser app, verifies
  its release checksum, version, bundle identity, Developer ID Team, hardened
  runtime, Gatekeeper assessment, and exact CEF layout, then restarts cmdy.
- Browser removal transactionally restores the verified lean app, deletes the
  Chromium-bearing app after startup confirmation, and preserves the browsing
  profile. Failed launches roll back both the app and Extension activation.

### Changed

- The canonical cmdy download is lean again and contains no Chromium. Every
  release publishes matching lean and Browser variants of the same app.
- Browser 2.2.0 uses the same download, install, disable, remove, update, CLI,
  deep-link, direct-package, and agent API surfaces as other Extensions.

### Security

- Release qualification and packaging now fail if a lean artifact contains any
  Browser marker or payload, or if a Browser artifact lacks CEF, its signed host,
  four helper apps, or Browser MCP adapter.

## [1.0.3] - 2026-09-03

### Added

- Extensions and Channels are now shareable `.cmdyext` packages that install
  by double-click, file picker, HTTPS URL, CLI, or one-click `cmdy://` link.
- The Extension CLI now packs, installs, updates, disables, enables, and removes
  packages; the Extensions window exposes the same complete lifecycle.

### Changed

- There is one canonical cmdy app. Browser is a normal installable and removable
  Extension that activates sandboxed Chromium as a real split inside the cmdy
  window; CEF and its signed workers remain sealed in the notarized app.
- Sim's serve-sim mirror opens in the same built-in Browser split for the
  originating cmdy window and never falls back to an external browser.
- The public Marketplace offers one-click install plus direct `.cmdyext`
  downloads, so Extension authors can distribute packages without a second
  installer or app edition.

### Security

- Package extraction rejects traversal, symlinks, duplicate paths, oversized
  archives, unsafe URLs, and mismatched hashes before install consent.
- Only the canonical Browser manifest may activate cmdy's allow-listed embedded
  Chromium host component.

## [1.0.2] - 2026-09-03

### Fixed

- Browser now remains visible in Extensions on lean installations, where its
  row offers the signed Browser-edition DMG instead of disappearing when no
  legacy Chromium Extension folder exists.
- Clicking Browser in the toolbar or menu on a lean installation now explains
  that Browser is not installed and offers the same Browser-edition download.
- Browser chrome now inherits the active tab's theme and restores the themed
  toolbar immediately when Browser is opened or closed.
- Closing the final Browser window no longer blocks AppKit for up to ten
  seconds while Chromium shuts down; unfinished Chromium cleanup is safely
  left to process exit.
- The Browser component version is now 2.0.1.

### Removed

- The startup boot banner and its menu, command-palette, config, diagnostic,
  and rebranding surfaces have been removed.

## [1.0.1] - 2026-09-02

### Fixed

- Release packaging now fails closed unless the canonical source checkout,
  GitHub release repository, checked-in product identity, and identity embedded
  in the finished app all agree on `suprb/cmdy`.
- Marketplace Extension and Channel rows now provide direct reviewed ZIP
  downloads, while Browser has a direct signed Browser-edition DMG instead of
  the incompatible retired standalone Chromium package.
- Stable latest-release DMG aliases provide version-independent direct download
  URLs for both lean and Browser installers.
- The legacy Marketplace endpoint now routes cmdy 1.0.0 installations to the
  current public Extension and Channel archives.

### Upgrade note

- cmdy 1.0.0 embedded the wrong GitHub owner, so its app updater cannot discover
  this repair. Install the 1.0.1 DMG once manually; automatic updates use the
  canonical public repository after that.

### Changed

- The public website now has one canonical project under `site/`; verified
  production output is generated into ignored `site/dist/`, and CI, Pages,
  Dependabot, documentation, and repository checks use the same layout.
- Ordinary CI now accepts a pending post-release publication record while still
  enforcing engineering bindings; human approval remains required by the
  notarized release workflow.

## [1.0.0] - 2026-09-01

### Added

- A native Metal terminal with independent VT parsing, scrollback, selection,
  command blocks, search, sessions, tabs, recursive splits, and window grids.
- The built-in editor, shader and theme system, extension SDK, Marketplace,
  Channels, Simulator integration, and Browser edition.
- Update discovery and Developer ID-signed downloads from immutable GitHub
  Releases with edition-preserving archive selection and SHA-256 verification.
- Public security, support, conduct, contribution, and issue-reporting guidance.
- A contributor-oriented architecture map and explicit performance invariants.

### Changed

- Fast wheel and trackpad scrolling now coalesces presentation work and shares
  repeated immutable row textures within a fixed 20 MiB cache, while selection
  and attributed command-block overlays stay off the hot scroll path.
- Editor and window-close ownership now follows one idempotent AppKit lifecycle,
  including repeated Show Editor commands and attached-editor teardown.
- Window Grid now keeps the dragged native window pinned while recursive
  neighbor animations settle, including on headless virtual displays.
- The frozen CmdyGPU 1.0 API now exposes selection composition and
  display-aligned scroll scheduling as explicit renderer seams.

### Security

- Release qualification binds active source, provenance, Core and renderer
  parity, performance, resource, TUI-zoo, signing, notarization, and Gatekeeper
  evidence before public artifacts can be published.
