#!/usr/bin/env bash
# Exercise Restart to Update with real packaged apps: an installed app swaps
# itself for a newer release ZIP through the signed restart helper, relaunches,
# and confirms; a ZIP that does not match its claimed version is refused.
#
# Both apps must share a bundle identifier that no running app uses: the
# restart quits every app with that identifier. Build them from a checkout
# whose product identity names a test bundle identifier, for example with
#   PRODUCT_SIGN_ID=- PRODUCT_VERSION=<old|new> ./package.sh
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: $0 /path/to/old.app /path/to/new.app" >&2
    exit 2
fi
OLD_APP="$1"
NEW_APP="$2"
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$OLD_APP/Contents/Info.plist")"
NEW_VERSION="$(plutil -extract CFBundleShortVersionString raw "$NEW_APP/Contents/Info.plist")"
if [ "$BUNDLE_ID" = "$(plutil -extract bundleIdentifier raw Identity/Sources/ProductIdentity/Resources/product-identity.json)" ]; then
    echo "Refusing to run with the product bundle identifier $BUNDLE_ID: it would quit the real app." >&2
    exit 2
fi

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cmdy-update-swap.XXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT HUP INT TERM
ARCHIVE="$TEST_ROOT/update.zip"
(cd "$(dirname "$NEW_APP")" && ditto -c -k --keepParent "$(basename "$NEW_APP")" "$ARCHIVE")

run_update() {
    local version="$1" root="$2"
    mkdir -p "$root/Applications" "$root/home" "$root/config"
    ditto "$OLD_APP" "$root/Applications/cmdy.app"
    HOME="$root/home" CMDY_CONFIG_DIR="$root/config" \
        CMDY_DEFAULTS_DOMAIN="$BUNDLE_ID.update-swap.$$" \
        "$root/Applications/cmdy.app/Contents/MacOS/cmdy" \
        --ui-test-restart-to-update "$ARCHIVE" "$version" > "$root/old.log" 2>&1 &
}

state_of() {
    cat "$1"/config/browser-component-switch-*.json 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])' 2>/dev/null || true
}

# A matching newer release replaces the app and the relaunched copy confirms.
GOOD="$TEST_ROOT/good"
run_update "$NEW_VERSION" "$GOOD"
for _ in $(seq 1 120); do
    installed="$(plutil -extract CFBundleShortVersionString raw "$GOOD/Applications/cmdy.app/Contents/Info.plist")"
    [ "$installed" = "$NEW_VERSION" ] && [ "$(state_of "$GOOD")" = completed ] && break
    sleep 1
done
pkill -f "$GOOD/Applications/cmdy.app/Contents/MacOS/cmdy" || true
[ "$installed" = "$NEW_VERSION" ] || { echo "update did not install: $installed" >&2; exit 1; }
[ "$(state_of "$GOOD")" = completed ] || { echo "update transaction did not complete" >&2; exit 1; }
[ "$(ls -A "$GOOD/Applications")" = cmdy.app ] || { echo "staged or backup app left behind" >&2; exit 1; }

# A ZIP that does not match the claimed release is refused before any change.
BAD="$TEST_ROOT/bad"
run_update "$NEW_VERSION.1" "$BAD"
wait $! || true
grep -q 'UIRESTARTUPDATE failed' "$BAD/old.log" || { echo "mismatched update was not refused" >&2; exit 1; }
[ "$(plutil -extract CFBundleShortVersionString raw "$BAD/Applications/cmdy.app/Contents/Info.plist")" \
    = "$(plutil -extract CFBundleShortVersionString raw "$OLD_APP/Contents/Info.plist")" ] \
    || { echo "refused update changed the installed app" >&2; exit 1; }

echo "Restart to Update app-swap smoke passed."
