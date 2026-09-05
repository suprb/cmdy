# Building cmdy

This is the complete build and release reference for the lean app, its
installable Browser variant, and the Browser Extension activation. Keep this file current whenever packaging, signing,
notarization, CEF, Marketplace, or release automation changes.

## Requirements

- Apple silicon Mac running macOS 26 or newer
- Xcode 26 command-line tools and Swift 6.2
- Node 24 for the website
- CMake, curl, jq, tar, shasum, and GitHub CLI for full release work
- A `Developer ID Application` certificate for distributable artifacts
- App Store Connect notary credentials, either a keychain profile or API key

The app, Browser helpers, Browser host library, and CEF runtime must all be
signed by the same Apple Team. Never copy signing credentials into the source
tree or commit generated CEF files.

## Fast source build

```sh
swift build
swift run cmdy
```

Run the complete non-CEF test matrix with:

```sh
swift test -c release
swift test --package-path Identity -c release
swift test --package-path Core -c release
swift test --package-path Renderer -c release
swift test --package-path Kit -c release
swift test --package-path Plugins/CmdySDK -c release
swift test --package-path Plugins/chromium/Support -c release
swift test --package-path Vendor/BraincellBridge -c release
./test.sh
```

## Independent terminal-stack verification

`CmdyCore`, `CmdyPTY`, `CmdyGPU`, and the App surface are cmdy's terminal
stack. They have no SwiftTerm package or runtime dependency. Changes at these
boundaries must pass the independent-stack gates in addition to the ordinary
test matrix:

```sh
# Reproduce and verify the pinned Unicode-width tables and exhaustive oracle.
python3 -B Core/Tools/UnicodeWidth/generate.py --check

# Exercise the fail-closed scanner, then scan the files on disk. Unlike a
# history-only audit, this includes modified and untracked active source.
python3 -B Tests/test-working-tree-provenance.py
python3 -B scripts/check-working-tree-provenance.py --mode check

# Compare every frozen public declaration, including the reviewed compatibility
# aliases and the CmdyUnderlineStyleKey rename.
./scripts/check-independent-api.sh

# Confirm the two terminal packages resolve no package dependencies. Their only
# non-Swift inputs are the documented Darwin and Apple platform frameworks.
for cmdy_package in Core Renderer; do
  swift package --package-path "$cmdy_package" \
    show-dependencies --format json \
    | jq -e --arg package "$cmdy_package" \
      '.name == $package and (.dependencies | length == 0)' >/dev/null
done

# The complete application graph must not resolve SwiftTerm transitively.
swift package show-dependencies --format json \
  | jq -e \
    '[recurse(.dependencies[]?)
      | ((.name // "") + " " + (.url // "") + " " + (.path // ""))
      | test("SwiftTerm"; "i")] | any | not' >/dev/null

# Confirm there is no retired terminal-module import in active source. The
# provenance gate separately rejects SwiftTerm references in package manifests.
if git grep -n -E \
  '^[[:space:]]*import[[:space:]]+(SwiftTerm|TermiteCore|TermitePTY|TermiteGPU)([[:space:]]|$)' \
  -- '*.swift' '*.metal'; then
  exit 1
fi

# Engine, PTY/process lifecycle, renderer, memory, shader, and pixel oracles.
swift test --package-path Core -c release
swift test --package-path Renderer -c release

# Confirm the release executable has no retired linked image or module symbol.
swift build -c release
! otool -L .build/release/cmdy | grep -Ei \
  'SwiftTerm|Termite(Core|PTY|GPU)'
! nm -m .build/release/cmdy | grep -Ei \
  'SwiftTerm|Termite(Core|PTY|GPU)'
```

`scripts/audit-swiftterm-lineage.py` is the frozen history/inventory tool. It
reads a Git commit, so `--ref HEAD` does not inspect uncommitted replacement
files. Use `check-working-tree-provenance.py` for the active-tree release gate;
use the history report only to reproduce the pre-replacement inventory.

### Final Core black-box parity

Migration maintainers compare two already-built Core libraries solely through
the public C ABI. The gate reads no implementation source and checks full text,
cells, colors, styles, cursor, scrollback, and semantic blocks across targeted
and deterministic randomized streams. The frozen reference is a local
pre-replacement behavioral artifact; it is deliberately neither committed nor
downloaded by CI.

```sh
swift build --package-path Core -c release --product lib_cmdy
cmdy_reference_library=/absolute/path/to/frozen/reference/liblib_cmdy.dylib
cmdy_candidate_library="$(swift build --package-path Core -c release \
  --show-bin-path)/liblib_cmdy.dylib"

# The first seed is the canonical corpus. The next eleven reproduce every
# random family found during replacement. The final five are fixed release
# expansion seeds. Each run also executes all named targeted regressions.
for cmdy_seed in \
  49361 104729 123457 99991 2654435761 130363 155921 271828 \
  314159 161803 65537 16777619 \
  20260820 8675309 42424243 314159265 271828182; do
  python3 -B scripts/check-core-blackbox-parity.py \
    --reference "$cmdy_reference_library" \
    --candidate "$cmdy_candidate_library" \
    --seed "$cmdy_seed" \
    --random-cases 2000 \
    --actions 180
done
```

A mismatch prints the first exact public-state difference and a minimized case.
Turn that case into a named regression before changing behavior, then rerun the
entire seed matrix. Do not put the frozen library, its source, or a generated
trace containing private implementation material in the repository.

### Frozen Kitty placement compatibility

Cmdy's black-box contract intentionally preserves one historical placement
quirk: after a successful non-virtual Kitty image placement, the default cursor
transition resets the column to zero and moves down by the placed row count.
Kitty `C=1` suppresses both parts of that transition. This is compatibility
behavior frozen by the C-ABI oracle, not a claim that it matches the newest
Kitty protocol recommendation. Change it only as a separately versioned
terminal-behavior migration, never as incidental independence cleanup.

The clean-room contracts, Unicode source hashes, renderer memory limits,
pixel-oracle tolerances, and provenance method live in
[`docs/independence/`](docs/independence/). Preserve historical license notices
even after replacing current implementation; source independence does not
rewrite prior releases or Git history.

## Local app bundle

`package.sh` creates `cmdy.app`, signs it with the first available Developer ID
or Apple Development identity, and falls back to ad-hoc signing only when no
certificate exists:

```sh
./package.sh
codesign --verify --deep --strict --verbose=2 cmdy.app
```

This fast local developer package is the same lean layout as the canonical
download: it contains no CEF. Both lean and Browser packages copy exactly the active SwiftPM resource
bundles `Kit_CmdyKit.bundle` (fonts) and
`ProductIdentity_ProductIdentity.bundle` (canonical identity). Packaging fails
if either bundle is missing, if its embedded identity differs byte-for-byte
from the source manifest, or if any path in the assembled app contains a
retired `SwiftTerm` or `Termite` name; stale incremental build bundles are never
copied by wildcard.

## Pinned Chromium development build

CEF is intentionally not committed. Bootstrap the exact pinned Apple-silicon
archive, verify its SHA-256, build its C++ wrapper and cmdy bridge, then run the
full lifecycle and sandbox smoke:

```sh
./scripts/bootstrap-chromium.sh
./scripts/bootstrap-chromium.sh --check
./scripts/check-chromium-build.sh
```

For the CEF-bearing Browser app variant plus its installable activation package:

```sh
PRODUCT_BROWSER_EDITION=1 \
PRODUCT_BROWSER_DEFAULT_ENABLED=0 \
./package.sh
./scripts/package-browser-extension.sh
```

This copies CEF and the host library into `cmdy.app/Contents/Frameworks`, builds
the four subprocess apps, signs the full graph, and runs the real embedded
Browser UI smoke. The helper apps are:

- `cmdy Chromium Helper.app`
- `cmdy Chromium Helper (Renderer).app`
- `cmdy Chromium Helper (GPU).app`
- `cmdy Chromium Helper (Plugin).app`

They use only the JIT/executable-memory permissions in
`Plugins/chromium/ChromiumHelper.entitlements`. The main cmdy executable keeps
an empty entitlement set. Apple library validation, CEF's macOS sandbox, and
Chromium's Mach-port peer validation remain enabled. There is no `no-sandbox`
or signature-validation bypass.

Do not try to place CEF in a second app and load it into cmdy. CEF's current
macOS renderer/GPU sandbox blocks that external framework path even when both
apps are signed and notarized by the same Apple Team. Upstream tracks support
for that layout in [CEF issue #3940](https://github.com/chromiumembedded/cef/issues/3940).
cmdy therefore publishes a lean app and a Browser variant with CEF in its
supported internal layout. A small `.cmdyext` activation starts a verified
transactional swap to the Browser variant; removal swaps back to lean. CEF
stays unloaded when Browser is disabled.

## Signed and notarized cmdy release

Store local notary credentials once:

```sh
xcrun notarytool store-credentials cmdy-notary
```

Then build the canonical lean app, ZIP, and DMG:

```sh
PRODUCT_NOTARY_PROFILE=cmdy-notary ./release.sh
```

`release.sh` defaults to the lean package and fails if any Browser marker,
framework, helper, host library, or MCP payload leaks into it. A notarized release additionally refuses a
checkout whose `origin` is not the repository declared by product identity. It
signs cmdy with hardened runtime,
notarizes and staples the app and DMG, runs Gatekeeper checks, and writes
SHA-256 files under `dist/`.

To exercise every packaging and signing step without contacting Apple's notary
service:

```sh
SKIP_NOTARIZE=1 ./release.sh
```

Those rehearsal artifacts use a `-rehearsal` filename suffix so they cannot
overwrite the canonical notarized ZIP or DMG. They are not public or
Gatekeeper-ready.

## Browser activation and app-variant artifacts

Browser remains optional and has its own component version in
`Plugins/chromium/VERSION`. `scripts/package-browser-extension.sh` builds the
small `chromium-<version>.cmdyext` activation package published through the
Marketplace. It contains no CEF payload; installing it makes the lean app fetch
the signed Browser variant containing the framework and helpers.

The complete Browser app is published under `dist/browser/`. Marketplace
installation resolves a stable-named ZIP alias inside the immutable GitHub
Release matching the installed cmdy version. It does not call GitHub's
rate-limited latest-release API, and a stale Marketplace entry remains valid
when a release carries a newer compatible Browser component. It verifies the
archive's SHA-256, complete code signature, Developer ID Team, exact app
version, minimum Browser version, Gatekeeper assessment, and Browser layout,
then replaces the lean app and restarts. Browser removal resolves the matching
lean ZIP alias, performs the same checks, swaps back, and deletes the old
Browser app only after startup confirmation.

Build, sign, notarize, staple, and verify it with the same credentials:

```sh
PRODUCT_NOTARY_PROFILE=cmdy-notary \
./scripts/release-chromium-browser.sh
```

For a signed local rehearsal:

```sh
SKIP_NOTARIZE=1 ./scripts/release-chromium-browser.sh
```

The Browser release produces a ZIP, DMG, their SHA-256 files, and a metadata
JSON under `dist/browser/`. Artifact names contain both the cmdy app version and
the independently tracked Browser version; local rehearsals also end in
`-rehearsal`. Canonical releases additionally create stable-named ZIP and DMG
aliases for both lean and Browser artifacts. Component switching uses the ZIP
alias under the installed app's immutable release tag; the website uses the DMG
alias under GitHub's latest-release redirect. Every alias is a byte-for-byte
copy of its qualified artifact. The script:

1. Verifies and builds the pinned CEF source inputs.
2. Packages the Browser app with CEF, the host library, and four helpers.
3. Requires every code object to share cmdy's Developer-ID Team.
4. Requires only the helper JIT/executable-memory entitlements.
5. Runs the actual embedded page-load UI smoke with Chromium's sandbox on.
6. Notarizes and staples the app and DMG, then runs Gatekeeper checks.

Fresh users install only the canonical cmdy DMG. Browser is then installed,
disabled, removed, or reinstalled in **View → Extensions…**. Install and remove
download the requested notarized variant, replace `cmdy.app` without re-signing
it, restart automatically, and roll back both app and activation on failure.

The Browser activation package installs its MCP shim at
`~/.config/cmdy/extensions/chromium/mcp/index.js`, and Integration Doctor can
register it with supported agent clients. The signed app also keeps a matching
fallback copy at `/Applications/cmdy.app/Contents/Resources/BrowserMCP/index.js`.
For manual registration:

```sh
claude mcp add --scope user cmdy-browser -- node \
  ~/.config/cmdy/extensions/chromium/mcp/index.js
codex mcp add cmdy-browser -- node \
  ~/.config/cmdy/extensions/chromium/mcp/index.js
```

## Publication order

1. Update `VERSION`, and update `Plugins/chromium/VERSION` when Browser changed.
2. Land the matching app and Browser code together.
3. Run `release.yml`; it builds the canonical lean app, the activation
   `.cmdyext`, and the full Browser app with the same Apple Team.
4. Publish all checksums and metadata on the same immutable
   `v<cmdy-version>` GitHub Release.
5. Pin the new `chromium-<version>.cmdyext` URL and hash in `cmdy-registry`,
   merge that registry change, then refresh and land
   `site/public/marketplace-data.js` as the matching offline snapshot.
6. Verify the canonical app on a clean Mac: install Browser from the registry,
   load a real page in-window, run serve-sim into that split, remove Browser,
   and reinstall it.

Never replace an asset under an existing version; bump the cmdy app version and
publish a new release instead. Browser is a normal Marketplace lifecycle
package, but CEF itself must never move outside the host app because the current
upstream sandbox rejects that layout.

Lean cmdy selects the canonical ZIP for app updates and Browser cmdy selects the
`-browser-` ZIP. Component installation and removal instead use stable-named
ZIP aliases under the exact release tag for the app already on disk, so those
user-requested operations do not depend on update discovery, an unauthenticated
API quota, or the Marketplace cache containing the newest compatible Browser
version. The cached update record is invalidated when the installed variant
changes.

## GitHub Actions and secrets

- `.github/workflows/ci.yml` runs the ordinary suite plus the reproducible
  Unicode, active-tree provenance, public-API, dependency/import, and linked
  symbol gates. Its main checkout keeps full history so the two frozen
  provenance commits can be resolved. A separate job performs the pinned full
  CEF build, lifecycle stress test, helper sandbox smoke, and an ad-hoc
  Browser page-load smoke plus real lean-to-Browser and Browser-to-lean app swaps.
- `.github/workflows/release.yml` produces, notarizes, verifies, and publishes
  the lean app, Browser activation package, and full Browser app in one
  immutable GitHub Release.

The release workflow uses these secrets for every notarized app artifact:

- `CMDY_DEVELOPER_ID_P12_BASE64`
- `CMDY_DEVELOPER_ID_P12_PASSWORD`
- `CMDY_NOTARY_KEY_P8_BASE64`
- `CMDY_NOTARY_KEY_ID`
- `CMDY_NOTARY_ISSUER_ID`

## Final verification

Before publishing any release, run the complete source, API, package, app, and
interactive evidence matrix. The first block is suitable for a clean checkout;
the black-box matrix in the independence section additionally requires the
local frozen Core library and CmdyGPU release build.

```sh
./scripts/check-repository-hygiene.sh
./scripts/check-product-identity.sh
python3 -B Core/Tools/UnicodeWidth/generate.py --check
python3 -B Tests/test-working-tree-provenance.py
python3 -B scripts/check-working-tree-provenance.py --mode check
./scripts/check-independent-api.sh
for cmdy_package in Core Renderer; do
  swift package --package-path "$cmdy_package" \
    show-dependencies --format json \
    | jq -e --arg package "$cmdy_package" \
      '.name == $package and (.dependencies | length == 0)' >/dev/null
done
swift package show-dependencies --format json \
  | jq -e \
    '[recurse(.dependencies[]?)
      | ((.name // "") + " " + (.url // "") + " " + (.path // ""))
      | test("SwiftTerm"; "i")] | any | not' >/dev/null
! git grep -n -E \
  '^[[:space:]]*import[[:space:]]+(SwiftTerm|TermiteCore|TermitePTY|TermiteGPU)([[:space:]]|$)' \
  -- '*.swift' '*.metal'

swift test -c release
swift test --package-path Identity -c release
swift test --package-path Core -c release
swift test --package-path Renderer -c release
swift test --package-path Kit -c release
swift test --package-path Plugins/CmdySDK -c release
swift test --package-path Plugins/chromium/Support -c release
swift test --package-path Plugins/sim -c release
swift test --package-path Vendor/BraincellBridge -c release
swift build --package-path Plugins/detox -c release
swift build --package-path Plugins/bridge -c release
swift build --package-path Plugins/swarm -c release
swift build --package-path Plugins/appdock -c release

# Local frozen-reference parity is mandatory release evidence. The external
# artifacts must be retained with their recorded hashes; CI does not download
# or reconstruct them.
: "${CMDY_CORE_REFERENCE_LIBRARY:?set to the frozen Core reference dylib}"
: "${CMDY_RENDERER_REFERENCE_BUILD:?set to the frozen CmdyGPU release build}"
cmdy_candidate_library="$(swift build --package-path Core -c release \
  --show-bin-path)/liblib_cmdy.dylib"
for cmdy_seed in \
  49361 104729 123457 99991 2654435761 130363 155921 271828 \
  314159 161803 65537 16777619 \
  20260820 8675309 42424243 314159265 271828182; do
  python3 -B scripts/check-core-blackbox-parity.py \
    --reference "$CMDY_CORE_REFERENCE_LIBRARY" \
    --candidate "$cmdy_candidate_library" \
    --seed "$cmdy_seed" \
    --random-cases 2000 \
    --actions 180
done
python3 -B scripts/check-renderer-pixel-parity.py \
  --reference-build "$CMDY_RENDERER_REFERENCE_BUILD"

swift build
swift build -c release
CMDY_TEST_CONFIGURATION=release ./test.sh

Tests/perf-gate.sh
CMDY_PERF_MAXIMIZED=1 Tests/perf-gate.sh
ZOO_OUT="$(mktemp -d /tmp/cmdy-zoo-release.XXXXXX)" Tests/zoo.sh

./package.sh
codesign --verify --deep --strict --verbose=2 cmdy.app
source scripts/product-identity.sh
test "$(/usr/bin/plutil -extract CFBundleExecutable raw -o - \
  cmdy.app/Contents/Info.plist)" = "$PRODUCT_EXECUTABLE"
test "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - \
  cmdy.app/Contents/Info.plist)" = "$PRODUCT_BUNDLE_IDENTIFIER"
test -x "cmdy.app/Contents/MacOS/$PRODUCT_EXECUTABLE"
/usr/bin/file "cmdy.app/Contents/MacOS/$PRODUCT_EXECUTABLE" \
  | grep -F 'Mach-O 64-bit executable arm64'
CMDY_CONFIG_DIR="$(mktemp -d /tmp/cmdy-package-smoke.XXXXXX)" \
  "cmdy.app/Contents/MacOS/$PRODUCT_EXECUTABLE" --selftest
otool -L "cmdy.app/Contents/MacOS/$PRODUCT_EXECUTABLE"
! otool -L "cmdy.app/Contents/MacOS/$PRODUCT_EXECUTABLE" | grep -Ei \
  'SwiftTerm|Termite(Core|PTY|GPU)'
! nm -m "cmdy.app/Contents/MacOS/$PRODUCT_EXECUTABLE" | grep -Ei \
  'SwiftTerm|Termite(Core|PTY|GPU)'

git diff --check
```

`./test.sh` includes rapid create/close, 32-live-window, and grid/split
conversion stress. For an extended manual resource plateau, keep an isolated
post-close stress process alive long enough to sample it:

```sh
cmdy_stress_root="$(mktemp -d /tmp/cmdy-release-stress.XXXXXX)"
env CMDY_CONFIG_DIR="$cmdy_stress_root/config" \
  CMDY_DEFAULTS_DOMAIN="com.cmdy.release-stress.$$" \
  CMDY_UI_TEST_HOLD_SECONDS=30 \
  .build/release/cmdy --ui-test-window-grid-stress \
  >"$cmdy_stress_root/run.log" 2>&1 &
cmdy_stress_pid=$!

# Sample after the create/close wave has settled. Repeat the run several times;
# RSS, threads, and descriptors may warm once but must not grow monotonically.
ps -o pid=,rss= -p "$cmdy_stress_pid"
ps -M -p "$cmdy_stress_pid" \
  | awk 'NR > 1 { count++ } END { print "threads=" count + 0 }'
lsof -p "$cmdy_stress_pid" | wc -l
vmmap -summary "$cmdy_stress_pid"
ps -axo ppid=,pid=,stat=,command= \
  | awk -v parent="$cmdy_stress_pid" '$1 == parent && $3 ~ /^Z/'
wait "$cmdy_stress_pid"
grep -F 'UIWINDOWGRIDSTRESS' "$cmdy_stress_root/run.log"
```

An empty zombie query, `ok=true` in the stress result, stable post-warm-up
resource counts, both performance gates, and a reviewed zoo capture are all
release evidence. Keep generated zoo images and profiling output outside the
repository.

For Browser, first run the pinned build and sandbox checks:

```sh
./scripts/bootstrap-chromium.sh --check
./scripts/check-chromium-build.sh
PRODUCT_BROWSER_EDITION=1 ./package.sh
```

Then mount the generated DMG, verify that CEF and all four helpers are inside
`cmdy.app/Contents/Frameworks`, and confirm every Mach-O reports the same
non-empty `TeamIdentifier`. A notarized run must also pass:

```sh
for dmg in dist/*.dmg dist/browser/*.dmg; do
  xcrun stapler validate -v "$dmg"
  spctl --assess --type open --context context:primary-signature \
    --verbose=2 "$dmg"
done
```
