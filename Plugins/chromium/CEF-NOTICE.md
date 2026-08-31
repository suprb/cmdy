# Chromium Embedded Framework notices

The optional Browser Extension uses CEF
`145.0.28+g51162e8+chromium-145.0.7632.160` for Apple silicon.

- CEF's BSD-style license is tracked at `CEF-LICENSE.txt`.
- Chromium and CEF's complete generated third-party attribution file is
  `Frameworks/CEF-CREDITS.html` after `scripts/bootstrap-chromium.sh` runs.
- The bootstrap verifies the pinned archive SHA-256, copies both notice files
  from that exact archive, and refuses `--check` if either is absent.
- `plugins.sh` installs the whole `Frameworks/` payload next to the Browser
  Extension, preserving both files with the framework it covers.

`CEF-CREDITS.html` is generated from the pinned 257 MiB upstream payload and is
not duplicated in Git. Run `./scripts/bootstrap-chromium.sh` to reproduce the
complete local notice set before building or redistributing the Browser
Extension.
