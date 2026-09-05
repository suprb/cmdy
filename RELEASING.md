# Releasing cmdy for macOS

## Publish signed artifacts

Once the release commit is pushed, run:

```sh
./publish-release.sh 1.2.0
```

The command refuses dirty or unpushed source, a private repository, or any
release target that differs from the repository embedded in product identity,
then dispatches `.github/workflows/release.yml`, watches the notarized build,
and verifies the published GitHub Release assets. Use `--no-watch` to dispatch
and return immediately, or `--dry-run` to inspect the resolved version,
repository, branch, and commit without contacting GitHub.

GitHub assets are the first publication phase. Pin the released Browser
activation URL and SHA-256 in `cmdy-registry`, merge that change, refresh
`site/public/marketplace-data.js` from the merged registry, and merge the site
snapshot. The release is complete only when this strict live cross-repository
gate passes:

```sh
./scripts/check-public-release.sh
```

The public repository named by `product-identity.json` must exist before the
first release, and these Actions secrets must be configured:

- `CMDY_DEVELOPER_ID_P12_BASE64`
- `CMDY_DEVELOPER_ID_P12_PASSWORD`
- `CMDY_NOTARY_KEY_P8_BASE64`
- `CMDY_NOTARY_KEY_ID`
- `CMDY_NOTARY_ISSUER_ID`

The workflow temporarily accepts the legacy `TERMITE_` secret names so an
existing private repository can migrate without a broken release window.

Manual workflow dispatches and `v*` tag pushes both build, notarize, staple,
checksum, and publish the ZIP and DMG. A release is not made public until every
verification step passes.

The release workflow also requires the fail-closed publication record described
in [`docs/independence/RELEASE_QUALIFICATION.md`](docs/independence/RELEASE_QUALIFICATION.md).
Ordinary CI verifies engineering bindings without implying human approval.
Publication remains blocked while that record is `pending`, and only the real
notarized path consumes the approved record and emits final package evidence.

## Build locally

`package.sh` builds `cmdy.app`, applies the requested version metadata, and
signs it. With a real identity it always enables hardened runtime and a trusted
timestamp, then verifies the finished bundle.

For a complete release, store notary credentials once in the login keychain:

```sh
xcrun notarytool store-credentials cmdy-notary
PRODUCT_NOTARY_PROFILE=cmdy-notary \
./release.sh
```

`release.sh` requires a canonical `suprb/cmdy` checkout and a
`Developer ID Application` certificate. It creates a
ZIP, submits it to Apple, requires an `Accepted` result, staples the ticket to
the app, and validates the app with Gatekeeper. It then creates a signed
drag-to-Applications DMG using a sparse APFS image, notarizes and staples the
DMG, validates that with Gatekeeper, and writes SHA-256 checksums for both
artifacts in `dist/`. The canonical run also emits stable-named
`cmdy-macOS-arm64.zip` and `.dmg` aliases with checksums; the DMG is the lean
public download and contains no Chromium. The Browser release emits matching
`cmdy-browser-macOS-arm64.zip` and `.dmg` aliases. Marketplace component
switching pins these ZIP names under the installed app's immutable release tag,
so it needs no GitHub release API call and can accept a newer compatible Browser
component than a cached Marketplace manifest requests. Browser-edition app
updates still select the versioned Browser ZIP through normal update discovery.
Rehearsal builds never create stable aliases.
It also retains each raw Apple JSON receipt beside the release artifacts, each
submission identifier and pre-staple submitted hash, then writes a
`*.publication.json` record for the final stapled package. The submitted and
final hashes are intentionally distinct fields. Source approval happens first;
the completed receipt and publication records form a separate post-notary
artifact attestation.

App Store Connect API keys are also supported, which is the path used by CI:

```sh
PRODUCT_NOTARY_KEY_FILE=/secure/AuthKey_ABC123.p8 \
PRODUCT_NOTARY_KEY_ID=ABC123 \
PRODUCT_NOTARY_ISSUER_ID=00000000-0000-0000-0000-000000000000 \
./release.sh
```

Use `SKIP_NOTARIZE=1 ./release.sh` to rehearse the complete build, hardened
signing, ZIP, DMG, and checksum path without submitting to Apple. Those
artifacts have a `-rehearsal` filename suffix so they cannot overwrite or be
mistaken for notarized release assets. They are intentionally not described as
Gatekeeper-ready and do not pass or emit publication qualification.

## GitHub Actions

`.github/workflows/release.yml` runs on a `v*` tag or manual dispatch. It uses
an ephemeral keychain, calls the same `release.sh`, and uploads the ZIP, DMG,
and checksums as workflow artifacts and to the matching GitHub Release.
Configure these repository secrets:

- `CMDY_DEVELOPER_ID_P12_BASE64`
- `CMDY_DEVELOPER_ID_P12_PASSWORD`
- `CMDY_NOTARY_KEY_P8_BASE64`
- `CMDY_NOTARY_KEY_ID`
- `CMDY_NOTARY_ISSUER_ID`

The `.p12` and `.p8` values are base64-encoded file contents. The workflow
deletes the temporary certificate, API key, and keychain even when a release
step fails.

Every `v*` release publishes two signed layouts of the same app: a canonical
lean build with no Chromium and a Browser build containing CEF and its four
signed helpers in `cmdy.app/Contents/Frameworks`, the layout required by
Chromium's macOS sandbox. Installing the hash-pinned `.cmdyext` activation makes
cmdy download, verify, swap to, and restart the Browser build; removal verifies
and restores the lean build. Build the Browser component with
`./scripts/release-chromium-browser.sh`; see
[BUILDING.md](BUILDING.md) for the signing graph, artifact names, clean-Mac
verification, and rollback path.
