# Rebranding cmdy safely

This is the complete runbook for changing the public product name, app icon,
and logo without breaking existing users. The identity system deliberately
turns a marketing rename into a small migration instead of a repository-wide
search-and-replace.

The rule to remember is:

- Change the product name through the identity script.
- Change the app artwork through the canonical brand master.
- Manually redraw the terminal boot badge and update public copy/media.
- Keep compatibility identifiers stable unless a separate breaking migration
  has been designed and tested.

## Fast path

For an ordinary future rename from cmdy to `New Name`:

```sh
git switch -c rebrand/new-name
./scripts/rename-product.sh "New Name"

# Replace Brand/Assets/app-icon.png with the new 1024 x 1024 PNG.
# Add the untouched source artwork under Brand/Assets/ for provenance.
# Redraw the terminal badge in App/SystemInfo.swift.
# Update public prose, links, screenshots, and the GitHub repository.

./scripts/check-product-identity.sh
swift test --package-path Identity
./test.sh
(cd site && npm test)
./package.sh
```

Do not globally replace product names or compatibility identifiers. Names such
as `Termite`, `termite`, and `term64` are intentionally retained in selected
places as compatibility aliases, stable API names, module names, C symbols,
environment fallbacks, and code-signing identifiers.

## What is automatic and what is not

The canonical identity manifest is:

```text
Identity/Sources/ProductIdentity/Resources/product-identity.json
```

Only its `name` is normally changed during a rebrand. Swift, Node, shell build
scripts, the packaged app, and first-party Extensions all derive their public
identity from that value.

| Surface | Source | Future rename |
| --- | --- | --- |
| Menu/app display name | identity `name` | Automatic |
| Lowercase product slug | derived from `name` | Automatic |
| Executable and `.app` name | derived slug | Automatic |
| Config and project directories | derived slug | Automatic, with legacy migration |
| Environment prefix | derived slug | Automatic, with legacy fallbacks |
| MCP server names | derived slug | Automatic |
| Extension install destination | derived slug | Automatic |
| Updater repository and release assets | owner plus derived slug | Automatic |
| ZIP, DMG, iconset, and ICNS filenames | derived slug | Automatic |
| `Info.plist` display and executable values | identity plus derived slug | Automatic |
| App icon and website icon | `Brand/Assets/app-icon.png` | Replace manually |
| Original logo artwork | `Brand/Assets/` | Archive manually |
| Terminal boot badge | `App/SystemInfo.swift` | Redraw manually |
| Website prose, docs, examples, screenshots | several editorial files | Review manually |
| GitHub repository, registry, domains, social accounts | external services | Rename manually |

For example, `New Name` becomes:

```text
display name       New Name
slug               new-name
app                 new-name.app
executable          new-name
config directory    ~/.config/new-name
project directory   .new-name
environment prefix  NEW_NAME
browser MCP name    new-name-browser
release prefix      new-name
GitHub repository   <repositoryOwner>/new-name
```

You can inspect the values that the scripts will use at any time. The identity
helper is a Bash library, so identity-inspection blocks explicitly launch Bash
and remain safe to paste from macOS's default zsh:

```sh
bash <<'BASH'
source scripts/product-identity.sh
printf 'name:       %s\n' "$PRODUCT_NAME"
printf 'slug:       %s\n' "$PRODUCT_SLUG"
printf 'app:        %s\n' "$PRODUCT_APP_BUNDLE"
printf 'executable: %s\n' "$PRODUCT_EXECUTABLE"
printf 'env prefix: %s\n' "$PRODUCT_ENV_PREFIX"
printf 'repository: %s\n' "$PRODUCT_GITHUB_REPOSITORY"
BASH
```

## 1. Prepare the rename

Before touching the manifest:

1. Start from a known commit and make a dedicated branch.
2. Record the old display name, slug, bundle identifier, repository URL, and
   latest shipped version.
3. Check the proposed name, domain, GitHub repository, package names, and app
   marketplace/trademark landscape.
4. Decide whether the GitHub repository will be renamed. The built-in updater
   derives `<repositoryOwner>/<new-slug>` immediately, so that repository must
   exist before a renamed build is distributed.
5. Collect the original vector or highest-resolution artwork, plus a finished
   square app-icon master.

See the current values with:

```sh
bash <<'BASH'
source scripts/product-identity.sh
git remote -v
plutil -p "$PRODUCT_IDENTITY_FILE"
BASH
```

Do not start by renaming folders or Swift types. The source checkout can keep
its existing local directory name, and internal API names are deliberately
decoupled from the public brand.

## 2. Change the public name

Run the migration-aware command from the repository root:

```sh
./scripts/rename-product.sh "New Name"
```

The command does two things:

1. It replaces the manifest's canonical public `name`.
2. It puts the former name first in `legacyNames`, unless it is already there.

That second step is important. It lets the new app discover old config and
project directories, accept old environment variables, and remove superseded
MCP registrations without deleting a user's old data.

Inspect the result:

```sh
plutil -p Identity/Sources/ProductIdentity/Resources/product-identity.json
bash <<'BASH'
source scripts/product-identity.sh
printf '%s -> %s.app (%s)\n' \
  "$PRODUCT_NAME" "$PRODUCT_SLUG" "$PRODUCT_ENV_PREFIX"
BASH
```

The name must produce a non-empty ASCII slug that begins with a letter. Spaces
and punctuation become dashes. Avoid names whose slugs collide with an older
identity or another shipped product.

### Capitalization-only changes

The rename script treats names with the same slug as the same identity. If the
only change is capitalization, update only the `name` value in
`product-identity.json`; do not add another `legacyNames` entry because the
paths, executable, environment prefix, MCP namespace, and release assets have
not changed. Then run the same verification gates below.

## 3. Keep these identifiers stable

For a normal marketing rebrand, do not change these manifest fields:

```text
bundleIdentifier
extensionIdentifierNamespace
codeSigningIdentifierNamespace
```

Their old-looking values are intentional compatibility infrastructure, not
missed branding. Changing them can cause macOS to see a different app and lose
preferences, Accessibility/Screen Recording permissions, designated signing
continuity, Extension install receipts, or update continuity.

Also do not rename these merely for visual consistency:

- Swift packages/modules and types such as `TermiteCore`, `TermiteKit`, and
  `TermiteSDK`.
- C ABI symbols, protocol keys, JSON schema fields, notification identifiers,
  header names, and compatibility entry points.
- `Termite.entitlements` unless the file's contents require a real change.
- Existing CI secret names such as `TERMITE_DEVELOPER_ID_P12_BASE64`.
- Entries already recorded in `legacyNames`.

Those can be migrated separately if there is a technical reason, but that is a
breaking API/security migration and is outside a visual rename.

## 4. Replace the logo and app icon

There are two kinds of artwork in `Brand/Assets/`:

- `app-icon.png` is the canonical build input. Packaging and the website read
  this exact stable filename, so do not rename it.
- Name-specific source files are archival originals. Add the untouched new
  artwork as `<new-slug>-logo-source.svg`, `.pdf`, or `.png`; keeping the source
  makes future icon work reproducible.

Prepare `Brand/Assets/app-icon.png` with these properties:

- PNG format.
- Exactly 1024 x 1024 pixels.
- RGB or RGBA color.
- The complete intended icon composition, including its background.
- Enough breathing room to remain recognizable at 16 and 32 pixels.
- No accidental stretch from a landscape logo into a square canvas.

Check the master before building:

```sh
sips -g pixelWidth -g pixelHeight -g format -g hasAlpha \
  Brand/Assets/app-icon.png
```

The width and height must both report `1024`, and the format must report `png`.
Open the master and inspect it visually at both full size and thumbnail size.

`App/IconGenerator.swift` reads this master and generates every required icon
size. `package.sh` then creates the slug-named ICNS and places it in the app.
The website build copies the same master to `site/dist/app-icon.png` through
`site/scripts/sync-brand.mjs`; do not edit the generated `site/dist/app-icon.png`
by hand.

After changing the artwork, update `Brand/README.md` so it names the archived
source file and briefly records how the square master was prepared. Never
overwrite the only copy of original supplied artwork.

## 5. Redraw the terminal boot badge

The startup badge is text, not a raster image. Its cell geometry lives in:

```text
App/SystemInfo.swift
```

Update the `logo` string array so it is a recognizable terminal-cell reduction
of the new mark. Also update the nearby source-art comment. The product name in
the banner header already comes from `ProductIdentity`; do not hardcode it.

Keep these constraints in mind:

- Every row should be visually close to the same cell width.
- Use full, half, or block glyphs deliberately; test with the bundled default
  font as well as a narrow fallback.
- Preserve enough negative space that the mark reads at normal terminal size.
- The mark should resemble the real logo, not merely spell the product name in
  an unrelated type style.
- Keep ANSI color resets intact so the badge cannot leak styling into the
  prompt.

Preview the exact banner without launching a full interactive session:

```sh
bash <<'BASH'
source scripts/product-identity.sh
swift build
".build/debug/$PRODUCT_EXECUTABLE" --banner
BASH
```

Then launch the packaged app and inspect the badge on Light, B/W, W/B, and at
least one colored theme.

## 6. Update public copy, links, and media

Functional identity is derived, but editorial language is deliberately human
written. Search the public-facing areas for the old display name and slug:

```sh
rg -n 'OLD DISPLAY NAME|old-slug' \
  README.md RELEASING.md Brand \
  ACTIONS.md CHANNELS.md EXTENSIONS.md EXTENSION_PROTOCOL.md \
  MARKETPLACE.md PLATFORM.md PLUGINS.md SHADERS.md SURFACE_PROTOCOL.md \
  site .github
```

Review every match; do not bulk-replace it. Typical manual updates include:

- README title, product description, install examples, and repository links.
- `RELEASING.md` example app names and notary profile examples.
- Extension/Action/Channel/Marketplace author documentation.
- Website headings, alt text, install commands, repository/registry URLs,
  local-storage keys, and test expectations.
- `site/package.json` package name if the site package should follow the new
  brand.
- GitHub workflow display labels and release prose. Secret keys may stay
  stable as noted above.
- Screenshots, video posters, recordings, terminal captures, and social/press
  assets in which the old name or icon is visible.
- Any stale logo file still referenced by HTML, CSS, Swift, or scripts.

The Vite build writes generated public files into `site/dist/`. Edit the sources
in `site/`, then rebuild; do not hand-maintain hashed files under
`site/dist/assets/`.

After the edits, run a wider audit:

```sh
rg -n --hidden \
  --glob '!.git/**' \
  --glob '!**/.build/**' \
  --glob '!*.app/**' \
  'OLD DISPLAY NAME|old-slug' .
```

Classify the remaining matches. A hit is allowed only when it is clearly one
of the following:

- an entry in `legacyNames`;
- a stable module, type, protocol, C symbol, bundle/signing namespace, or CI
  secret;
- a compatibility comment or test that intentionally proves migration;
- archived historical artwork or documentation that is intentionally kept.

Everything the user sees as current product branding should use the new name.

## 7. Rename external services in the right order

The identity manifest cannot rename external accounts. Check each of these:

- Main GitHub repository.
- Marketplace/registry repository.
- Website domain and deployment project.
- Release download links and update feed.
- Package-manager entries, if any.
- Social profiles, analytics properties, crash reporting, and support email.
- Apple Developer/App Store Connect records, only if those records are used.

If the main GitHub repository follows the product slug, rename it on GitHub and
then update the local remote:

```sh
bash <<'BASH'
source scripts/product-identity.sh
git remote set-url origin \
  "git@github.com:$PRODUCT_GITHUB_REPOSITORY.git"
git remote -v
git ls-remote origin HEAD
BASH
```

The app updater resolves the default repository from
`repositoryOwner/new-slug`. Do not ship the renamed app until that repository
exists and its Releases page is reachable. GitHub redirects often help old
links, but public documentation and CI should still be updated to the canonical
URL.

If the GitHub owner changes, update `repositoryOwner` in the identity manifest.
That is a public routing change, unlike the three compatibility identifiers
that should remain stable.

For the registry, update both the repository/link and any registry URLs in
website or app configuration. Existing package identifiers should normally
remain stable so installed Extensions are not duplicated.

## 8. Verify identity and compatibility

Run the fast identity gates first:

```sh
./scripts/check-product-identity.sh
swift test --package-path Identity
```

Then inspect the derived Node identity used by MCP shims:

```sh
node - <<'NODE'
const p = require('./Identity/Node/product-identity.js');
console.log({
  name: p.name,
  slug: p.slug,
  environmentPrefix: p.environmentPrefix,
  browserMCP: p.mcpServerName('browser'),
  legacySlugs: p.legacySlugs,
});
NODE
```

The new name/slug should be current, while the immediately previous slug should
appear in `legacySlugs`.

Run the application suite:

```sh
./test.sh
```

Run the standalone package suites when preparing a real release:

```sh
swift test --package-path Core
swift test --package-path Renderer
swift test --package-path Kit
swift test --package-path Plugins/TermiteSDK
swift test --package-path Plugins/chromium/Support
swift test --package-path Plugins/sim
```

Build every first-party Extension so stale hardcoded paths or executable names
cannot hide outside the main package:

```sh
swift build --package-path Plugins/bridge
swift build --package-path Plugins/detox
swift build --package-path Plugins/swarm
swift build --package-path Plugins/appdock
swift build --package-path Plugins/chromium
swift build --package-path Plugins/sim
```

Check MCP identity handshakes for the first-party Node shims:

```sh
for shim in \
  Plugins/chromium/mcp/index.js \
  Plugins/sim/mcp/index.js \
  Plugins/appdock/mcp/index.js
do
  printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
    | node "$shim"
done
```

Each `serverInfo.name` should begin with the new slug.

Finally rebuild and verify the website, including the synchronized icon:

```sh
(cd site && npm test)
cmp Brand/Assets/app-icon.png site/dist/app-icon.png
```

## 9. Build and inspect the real app bundle

`swift build` only builds an executable. It does not produce the app a user
will install. Build the bundle with:

```sh
./package.sh
bash <<'BASH'
source scripts/product-identity.sh
plutil -extract CFBundleName raw -o - \
  "$PRODUCT_APP_BUNDLE/Contents/Info.plist"
plutil -extract CFBundleDisplayName raw -o - \
  "$PRODUCT_APP_BUNDLE/Contents/Info.plist"
plutil -extract CFBundleExecutable raw -o - \
  "$PRODUCT_APP_BUNDLE/Contents/Info.plist"
plutil -extract CFBundleIdentifier raw -o - \
  "$PRODUCT_APP_BUNDLE/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$PRODUCT_APP_BUNDLE"
"$PRODUCT_APP_BUNDLE/Contents/MacOS/$PRODUCT_EXECUTABLE" --selftest
BASH
```

That block verifies the app's metadata and signature after packaging.

Expected results:

- `CFBundleName` and `CFBundleDisplayName` equal the new display name.
- `CFBundleExecutable` equals the new slug.
- `CFBundleIdentifier` remains the stable compatibility identifier.
- The signature verifies and the self-test passes.

Open the actual bundle:

```sh
bash <<'BASH'
source scripts/product-identity.sh
open "$PRODUCT_APP_BUNDLE"
BASH
```

Visually inspect Finder/Dock icon, menu bar name, About/update UI, window title,
config editor path, Marketplace install commands, Extension menus, MCP names,
startup badge, website favicon, and all Light/Dark appearance combinations.
Also check the 16/32 px icon in Finder list view; a logo that works only at
1024 px is not a finished app icon.

`package.sh` overwrites only the current slug's app bundle. A bundle from the
former slug may remain beside it, so confirm which exact `.app` you launch.
Quit old running copies before judging name, icon, updater, or config behavior.

## 10. Test fresh install and upgrade migration

Test both user stories before release:

### Fresh user

Use a separate macOS test account or an isolated configuration/defaults domain:

```sh
bash <<'BASH'
source scripts/product-identity.sh
REBRAND_TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/$PRODUCT_SLUG-rebrand.XXXXXX")"
env \
  "${PRODUCT_ENV_PREFIX}_CONFIG_DIR=$REBRAND_TEST_ROOT/config" \
  "${PRODUCT_ENV_PREFIX}_DEFAULTS_DOMAIN=$PRODUCT_BUNDLE_IDENTIFIER.rebrand-smoke" \
  "$PRODUCT_APP_BUNDLE/Contents/MacOS/$PRODUCT_EXECUTABLE" --selftest
BASH
```

This proves the renamed environment prefix and isolated storage route work. It
does not alter the real user config.

### Existing user

Use a test account containing a representative copy of the previous brand's
config, sessions, themes, and Extensions. Launch the renamed app without a new
config override and verify:

- missing items are copied into `~/.config/<new-slug>/`;
- existing items in the new directory are not overwritten;
- the old directory remains untouched for rollback;
- restored windows/tabs and working directories survive;
- first-party Extensions install under the new path and old MCP registrations
  do not multiply;
- the current environment prefix wins, followed by `PRODUCT_`, followed by
  legacy prefixes.

Never use a real user's only config directory as a migration fixture, and do
not delete the old directory during the rebrand. Keeping it is the downgrade
and rollback safety net.

## 11. Build the production release

A signed local app is not the same as a Gatekeeper-ready download.
`package.sh` signs the bundle; `release.sh` creates, notarizes, staples, and
validates the distributable ZIP and DMG.

Store notary credentials once, using any private keychain profile name:

```sh
xcrun notarytool store-credentials product-notary
```

Create a real release:

```sh
PRODUCT_VERSION=1.0.0 \
PRODUCT_NOTARY_PROFILE=product-notary \
./release.sh
```

For a packaging rehearsal only:

```sh
SKIP_NOTARIZE=1 PRODUCT_VERSION=1.0.0 ./release.sh
```

Never publish the rehearsal as Gatekeeper-ready. A production result must pass
all of these checks, which `release.sh` performs:

- Developer ID Application signature with hardened runtime and timestamp.
- Apple notarization result `Accepted`.
- Stapled ticket validation for the app and DMG.
- Deep strict code-signature verification.
- `hdiutil verify` for the DMG.
- Gatekeeper assessment reporting `source=Notarized Developer ID`.
- SHA-256 checksums for both release artifacts.

Inspect the exact output names under `dist/`; they should use the new slug. Mount
the DMG, drag the app to Applications, launch that installed copy, and repeat
the visual/name/updater smoke checks.

The GitHub release workflow derives artifact names and titles from identity.
Its existing `TERMITE_*` repository secret names may remain unchanged because
they are private CI keys, not customer-facing brand. Rename them only in one
coordinated change that updates both repository secrets and workflow references.

## 12. Final audit and commit checklist

Before committing or tagging, confirm every item:

- [ ] The identity script was used and the old name is first in `legacyNames`.
- [ ] Stable bundle, Extension, and signing identifiers are unchanged.
- [ ] The new slug has no collision with a previous identity.
- [ ] `Brand/Assets/app-icon.png` is a visually approved 1024 x 1024 PNG.
- [ ] Untouched source artwork is archived under `Brand/Assets/`.
- [ ] The terminal-cell badge visibly resembles the new logo.
- [ ] Public docs, website copy, URLs, commands, screenshots, and recordings
      use the new brand.
- [ ] The main GitHub repository exists at the updater's derived URL.
- [ ] The registry and external service links are correct.
- [ ] Identity, Swift, Extension, MCP, and website tests pass.
- [ ] The packaged app has the right visible name, executable, and icon.
- [ ] Fresh-user behavior and old-config migration were tested separately.
- [ ] The release ZIP and DMG are notarized, stapled, Gatekeeper-approved, and
      checksummed.
- [ ] Generated files in `site/dist/` reflect the website sources and canonical icon.
- [ ] The final diff contains no accidental global rename of internal APIs or
      compatibility identifiers.

Useful final checks:

```sh
./scripts/check-product-identity.sh
git diff --check
git status --short
git diff -- Identity Brand App/SystemInfo.swift README.md RELEASING.md \
  site .github
```

Commit the manifest, artwork, boot badge, public copy, editable website source,
and tests together so no intermediate commit advertises a mixed identity. Rebuild
the ignored `site/dist/` output from that committed source instead of committing it.

## Rollback

If the rename has not shipped, revert the rebrand commit as one unit. That is
safer than trying to reverse individual generated names by hand.

If it has shipped, treat rollback as another migration:

1. Run `rename-product.sh` with the restored public name so the temporary name
   becomes a compatibility alias.
2. Restore the previous canonical icon and terminal badge from version control.
3. Restore public links and ensure the updater's derived repository exists.
4. Repeat all fresh-user, upgrade, package, notarization, and Gatekeeper gates.
5. Leave both generations of user config untouched.

Do not remove a name from `legacyNames` merely because the marketing decision
was reversed. Once a build carrying that name reached users, its directories
and environment variables are real compatibility inputs.

## Files to know

| File or service | Responsibility |
| --- | --- |
| `Identity/Sources/ProductIdentity/Resources/product-identity.json` | One canonical public name and stable IDs |
| `scripts/rename-product.sh` | Safe public-name migration and alias recording |
| `scripts/product-identity.sh` | Shell derivations used by build/install/release scripts |
| `scripts/check-product-identity.sh` | Fast cross-runtime consistency gate |
| `Brand/Assets/app-icon.png` | Canonical app and website icon master |
| `Brand/Assets/<slug>-logo-source.*` | Untouched source artwork/provenance |
| `Brand/README.md` | Artwork provenance and preparation notes |
| `App/IconGenerator.swift` | Iconset renderer; normally no rebrand edit needed |
| `App/SystemInfo.swift` | Manual terminal-cell boot badge |
| `package.sh` | App bundle, Info.plist, helpers, icon, and signing |
| `release.sh` | ZIP/DMG, notarization, stapling, Gatekeeper, checksums |
| `.github/workflows/release.yml` | CI signing and GitHub Release publication |
| `site/` | Editable website source and editorial branding |
| `site/dist/` | Generated static deployment output |
| GitHub repository/registry | External names and updater destinations |

If a future rename seems to require editing dozens of functional Swift or
plugin files, stop and extend `ProductIdentity` instead. A public identity
surface should derive from the manifest; only artwork and intentional prose
should remain manual.
