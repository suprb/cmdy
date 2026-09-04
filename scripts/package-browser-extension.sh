#!/usr/bin/env bash
# Build the small Browser activation package.
#
# CEF itself stays sealed in cmdy.app because Chromium's macOS sandbox requires
# that layout. This ordinary .cmdyext record controls whether cmdy loads it, so
# Browser installs, disables, updates, and removes through the same Extension
# lifecycle as every other capability while its UI remains a real in-app split.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source scripts/product-identity.sh

BROWSER_VERSION="${BROWSER_VERSION:-$(tr -d '[:space:]' < Plugins/chromium/VERSION)}"
OUTPUT_DIRECTORY="${PRODUCT_BROWSER_EXTENSION_DIST_DIR:-dist/browser-extension}"
OUTPUT_ARCHIVE="$OUTPUT_DIRECTORY/chromium-$BROWSER_VERSION.cmdyext"
SIGN_ID="$(product_env_value SIGN_ID "$(security find-identity -v -p codesigning 2>/dev/null | awk '/Developer ID Application|Apple Development/{print $2; exit}')")"
SIGN_ID="${SIGN_ID:--}"

if ! [[ "$BROWSER_VERSION" =~ ^[0-9]+(\.[0-9]+){2}$ ]]; then
    echo "Browser version must contain three numeric components." >&2
    exit 2
fi

TEMP_ROOT="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
STAGING="$(mktemp -d "$TEMP_ROOT/cmdy-browser-extension.XXXXXX")"
cleanup() {
    case "$STAGING" in
        "$TEMP_ROOT"/cmdy-browser-extension.*) rm -rf -- "$STAGING" ;;
        *) echo "Refusing unsafe cleanup: $STAGING" >&2 ;;
    esac
}
trap cleanup EXIT HUP INT TERM

EXTENSION_ROOT="$STAGING/chromium"
EXECUTABLE="$EXTENSION_ROOT/browser-component"
MCP_ROOT="$EXTENSION_ROOT/mcp"
mkdir -p "$MCP_ROOT"

# Host components still carry a real executable so the package contract stays
# uniform. It is never launched: PluginManager routes the allow-listed
# embedded-chromium component to the app-owned runtime before process launch.
printf '%s\n' 'int main(void) { return 0; }' \
    | clang -x c -Os -mmacosx-version-min=26.0 -o "$EXECUTABLE" -
if [ "$SIGN_ID" = "-" ]; then
    codesign --force --sign - "$EXECUTABLE"
else
    codesign --force --sign "$SIGN_ID" --options runtime --timestamp \
        --identifier "$PRODUCT_CODE_SIGNING_IDENTIFIER_NAMESPACE.chromium.activation" \
        "$EXECUTABLE"
fi

# Ship the neutral stdio adapter with the activation record. The CEF runtime
# remains sealed in cmdy.app, while this small JS shim is what Claude, Codex,
# and Pi register to reach the app-owned Browser API after installation.
cp -R Plugins/chromium/mcp/. "$MCP_ROOT/"
cp Identity/Node/product-identity.js "$MCP_ROOT/product-identity.js"
cp "$PRODUCT_IDENTITY_FILE" "$MCP_ROOT/product-identity.json"

cat > "$EXTENSION_ROOT/manifest.json" <<JSON
{
  "manifestVersion": 1,
  "id": "dev.termite.chromium",
  "name": "Browser",
  "version": "$BROWSER_VERSION",
  "entrypoint": "browser-component",
  "exec": "browser-component",
  "hostComponent": "embedded-chromium",
  "enabled": true,
  "description": "Chromium browsing in a real cmdy window split",
  "homepage": "https://github.com/$PRODUCT_GITHUB_REPOSITORY/tree/main/Plugins/chromium",
  "capabilities": [],
  "guide": {
    "whatItDoes": [
      "Adds a Chromium browser as a real split inside each cmdy window.",
      "Lets local agents navigate, inspect, annotate, and capture the visible page through Browser MCP."
    ],
    "safety": [
      "Chromium's signed sandbox workers stay sealed inside cmdy.app; the visible browser stays embedded in cmdy.",
      "Disabling or removing the Extension closes its browser splits and prevents the runtime from loading."
    ],
    "setup": [
      "Choose Install in Extensions. cmdy verifies the package and turns on the integrated Browser immediately."
    ]
  }
}
JSON

mkdir -p "$OUTPUT_DIRECTORY"
TEMPORARY_ARCHIVE="$STAGING/browser-extension.zip"
(
    cd "$STAGING"
    ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl \
        chromium "$TEMPORARY_ARCHIVE"
)
mv -f -- "$TEMPORARY_ARCHIVE" "$OUTPUT_ARCHIVE"
shasum -a 256 "$OUTPUT_ARCHIVE" > "$OUTPUT_ARCHIVE.sha256"

printf 'Browser Extension: %s\n' "$OUTPUT_ARCHIVE"
printf 'SHA-256:          %s\n' "$(awk '{print $1}' "$OUTPUT_ARCHIVE.sha256")"
printf 'Signing:          %s\n' "$([ "$SIGN_ID" = "-" ] && echo ad-hoc || echo Developer-ID)"
printf 'Runtime:          bundled in cmdy.app (sandboxed, in-window)\n'
