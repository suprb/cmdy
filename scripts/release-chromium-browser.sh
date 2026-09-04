#!/usr/bin/env bash
# Build cmdy's Browser-enabled compatibility artifact as a complete
# signed/notarized app.
#
# CEF's macOS sandbox requires its framework and helper apps to live inside the
# hosting app's standard Contents/Frameworks directory. Current releases bundle
# CEF in the canonical app and use a removable Extension activation record. This
# artifact remains only so older Browser-edition installations can follow their
# edition-preserving updater path into the unified release.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source scripts/product-identity.sh

BROWSER_VERSION_FILE="Plugins/chromium/VERSION"
BROWSER_VERSION="${BROWSER_VERSION:-$(tr -d '[:space:]' < "$BROWSER_VERSION_FILE")}"
APP_VERSION="$(tr -d '[:space:]' < VERSION)"
CEF_VERSION_FILE="Plugins/chromium/Frameworks/.cef-version"
DIST_DIR="$(product_env_value BROWSER_DIST_DIR dist/browser)"

if ! [[ "$BROWSER_VERSION" =~ ^[0-9]+(\.[0-9]+){2}$ ]]; then
    echo "Browser version must contain three numeric components." >&2
    exit 2
fi
if [ "$BROWSER_VERSION" != "$(tr -d '[:space:]' < "$BROWSER_VERSION_FILE")" ]; then
    echo "Browser version $BROWSER_VERSION does not match $BROWSER_VERSION_FILE." >&2
    exit 2
fi

./scripts/bootstrap-chromium.sh
./scripts/check-chromium-build.sh

export PRODUCT_BROWSER_EDITION=1
export PRODUCT_BROWSER_UPDATE_VARIANT=1
export PRODUCT_BROWSER_DEFAULT_ENABLED=1
export PRODUCT_RELEASE_VARIANT="browser-$BROWSER_VERSION"
export PRODUCT_RELEASE_ALIAS_VARIANT="browser"
export PRODUCT_DIST_DIR="$DIST_DIR"
./release.sh

CEF_VERSION="$(tr -d '[:space:]' < "$CEF_VERSION_FILE")"
APP_TEAM="$(codesign -dv --verbose=4 "$PRODUCT_APP_BUNDLE" 2>&1 \
    | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
if ! [[ "$APP_TEAM" =~ ^[A-Z0-9]{10}$ ]]; then
    echo "Could not derive a valid Apple Team identifier from Browser compatibility artifact." >&2
    exit 3
fi

ARCH="$(lipo -archs "$PRODUCT_APP_BUNDLE/Contents/MacOS/$PRODUCT_EXECUTABLE" \
    | tr ' ' '-')"
REHEARSAL_SUFFIX=""
if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
    REHEARSAL_SUFFIX="-rehearsal"
fi
STEM="$PRODUCT_RELEASE_PREFIX-$APP_VERSION-browser-$BROWSER_VERSION-macOS-$ARCH$REHEARSAL_SUFFIX"
ARCHIVE="$DIST_DIR/$STEM.zip"
DMG="$DIST_DIR/$STEM.dmg"
METADATA="$DIST_DIR/$STEM.json"
for artifact in "$ARCHIVE" "$ARCHIVE.sha256" "$DMG" "$DMG.sha256"; do
    [ -f "$artifact" ] || {
        echo "Missing Browser release artifact: $artifact" >&2
        exit 4
    }
done

cat > "$METADATA" <<JSON
{
  "schemaVersion": 1,
  "edition": "browser",
  "appVersion": "$APP_VERSION",
  "browserVersion": "$BROWSER_VERSION",
  "architecture": "$ARCH",
  "teamIdentifier": "$APP_TEAM",
  "cefVersion": "$CEF_VERSION",
  "archive": "$(basename "$ARCHIVE")",
  "archiveSHA256": "$(awk '{print $1}' "$ARCHIVE.sha256")",
  "dmg": "$(basename "$DMG")",
  "dmgSHA256": "$(awk '{print $1}' "$DMG.sha256")"
}
JSON

printf 'Browser compatibility ZIP: %s\n' "$ARCHIVE"
printf 'Browser compatibility DMG: %s\n' "$DMG"
printf 'Browser metadata:    %s\n' "$METADATA"
printf 'Apple Team:          %s\n' "$APP_TEAM"
printf 'Sandbox policy:      enabled (no no-sandbox or library-validation bypass)\n'
