# Changelog

All notable changes to cmdy will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project intends to follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Public APIs and protocols follow semantic versioning. Breaking changes should
be called out here with a migration path before a versioned release.

## [Unreleased]

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
