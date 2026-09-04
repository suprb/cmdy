#!/usr/bin/env bash
# Exercise the real signed executable's transactional app replacement in both
# directions. The input apps must have the same identity and version; one must
# be lean and one must contain the complete Browser runtime.
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: $0 /path/to/lean.app /path/to/browser.app" >&2
    exit 2
fi

LEAN_APP="$1"
BROWSER_APP="$2"
for app in "$LEAN_APP" "$BROWSER_APP"; do
    [ -d "$app" ] || { echo "Missing app: $app" >&2; exit 2; }
    codesign --verify --deep --strict "$app"
done

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cmdy-component-swap.XXXXXX")"
cleanup() {
    case "$TEST_ROOT" in
        "${TMPDIR:-/tmp}"/cmdy-component-swap.*) rm -rf -- "$TEST_ROOT" ;;
        *) echo "Refusing unsafe component-smoke cleanup: $TEST_ROOT" >&2 ;;
    esac
}
trap cleanup EXIT HUP INT TERM

INSTALL_ROOT="$TEST_ROOT/Applications"
DESTINATION="$INSTALL_ROOT/cmdy.app"
CONFIG_ROOT="$TEST_ROOT/config"
HOME_ROOT="$TEST_ROOT/home"
mkdir -p "$INSTALL_ROOT" "$CONFIG_ROOT" "$HOME_ROOT"
ditto "$LEAN_APP" "$DESTINATION"

BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$DESTINATION/Contents/Info.plist")"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$DESTINATION/Contents/Info.plist")"
BUILD="$(plutil -extract CFBundleVersion raw "$BROWSER_APP/Contents/Info.plist")"
BROWSER_VERSION="$(plutil -extract CMDYBrowserVersion raw \
    "$BROWSER_APP/Contents/Info.plist")"
COORDINATION_ROOT="$HOME_ROOT/Library/Application Support/$BUNDLE_ID/ComponentSwitch"
mkdir -p "$COORDINATION_ROOT"

# Prove the packaged CLI can find its surrounding app when a shell invokes it
# by basename through PATH. Browser is already present in this copy, so this
# exercises the complete Marketplace package/activation path without starting
# a second app-replacement helper.
CLI_ROOT="$TEST_ROOT/cli"
CLI_APP="$CLI_ROOT/Applications/cmdy.app"
CLI_CONFIG="$CLI_ROOT/config"
CLI_HOME="$CLI_ROOT/home"
CLI_EXTENSION_DIST="$CLI_ROOT/extension-dist"
mkdir -p "$CLI_ROOT/Applications" "$CLI_CONFIG" "$CLI_HOME"
ditto "$BROWSER_APP" "$CLI_APP"
PRODUCT_SIGN_ID=- PRODUCT_BROWSER_EXTENSION_DIST_DIR="$CLI_EXTENSION_DIST" \
    ./scripts/package-browser-extension.sh >/dev/null
CLI_EXTENSION="$CLI_EXTENSION_DIST/chromium-$BROWSER_VERSION.cmdyext"
CLI_EXTENSION_SHA="$(shasum -a 256 "$CLI_EXTENSION" | awk '{print $1}')"
CLI_REGISTRY="$CLI_ROOT/registry.json"
cat > "$CLI_REGISTRY" <<JSON
{
  "api": 1,
  "name": "Browser component CLI smoke",
  "entries": [
    {
      "kind": "plugin",
      "id": "dev.termite.chromium",
      "name": "Browser",
      "description": "Browser component CLI smoke",
      "author": "cmdy",
      "license": "MIT",
      "version": "$BROWSER_VERSION",
      "file": "extension-dist/$(basename "$CLI_EXTENSION")",
      "sha256": "$CLI_EXTENSION_SHA",
      "sdk": "v1",
      "arch": ["arm64"]
    }
  ]
}
JSON
(
    cd "$TEST_ROOT"
    env HOME="$CLI_HOME" CFFIXED_USER_HOME="$CLI_HOME" \
        CMDY_CONFIG_DIR="$CLI_CONFIG" \
        PATH="$CLI_APP/Contents/MacOS:/usr/bin:/bin" \
        cmdy marketplace install dev.termite.chromium --yes \
        --registry "$CLI_REGISTRY"
)
test -f "$CLI_CONFIG/extensions/chromium/manifest.json"
test "$(plutil -extract enabled raw \
    "$CLI_CONFIG/extensions/chromium/manifest.json")" = true

run_switch() {
    local candidate="$1"
    local variant="$2"
    local uuid="$3"
    local token="$4"
    local activation_kind="${5:-none}"
    local activation_enabled="${6:-true}"
    local expected_state="${7:-completed}"
    local failure_mode="${8:-none}"
    local staged="$INSTALL_ROOT/.cmdy-component-stage-$uuid.app"
    local backup="$INSTALL_ROOT/.cmdy-component-backup-$uuid.app"
    local helper_dir="$TEST_ROOT/ComponentSwitch/$uuid"
    local helper="$helper_dir/cmdy-component-helper"
    local transaction="$TEST_ROOT/$variant.json"
    local lock_dir="$COORDINATION_ROOT/.browser-component-switch.lock"
    local browser_version_json=null
    local activation_json=null
    local suppress_confirmation=false
    local confirmation_timeout=null
    if [ "$failure_mode" = "no-confirmation" ]; then
        suppress_confirmation=true
        confirmation_timeout=3
    fi
    if [ "$variant" = "browser" ]; then
        local browser_version
        browser_version="$(plutil -extract CMDYBrowserVersion raw \
            "$candidate/Contents/Info.plist")"
        browser_version_json="\"$browser_version\""
    fi

    local activation_root="$CONFIG_ROOT/extensions"
    local activation_destination="$activation_root/chromium"
    local activation_backup="$activation_root/.chromium-backup-$uuid"
    if [ "$activation_kind" = "installed" ]; then
        mkdir -p "$activation_destination" "$activation_backup"
        cat > "$activation_destination/browser-component" <<'SH'
#!/bin/sh
exit 0
SH
        chmod 755 "$activation_destination/browser-component"
        cat > "$activation_destination/manifest.json" <<JSON
{
  "manifestVersion": 1,
  "id": "dev.termite.chromium",
  "name": "Browser",
  "version": "$BROWSER_VERSION",
  "entrypoint": "browser-component",
  "exec": "browser-component",
  "hostComponent": "embedded-chromium",
  "enabled": $activation_enabled,
  "capabilities": []
}
JSON
        printf 'previous\n' > "$activation_backup/marker"
        cat > "$activation_backup/manifest.json" <<JSON
{
  "manifestVersion": 1,
  "id": "dev.termite.chromium",
  "name": "Browser",
  "version": "$BROWSER_VERSION",
  "entrypoint": "browser-component",
  "exec": "browser-component",
  "hostComponent": "embedded-chromium",
  "enabled": $activation_enabled,
  "capabilities": []
}
JSON
        activation_json="{\"kind\":\"installed\",\"rootPath\":\"$activation_root\",\"destinationPath\":\"$activation_destination\",\"backupPath\":\"$activation_backup\"}"
    elif [ "$activation_kind" = "removed" ]; then
        [ -d "$activation_destination" ] || {
            echo "Browser activation missing before removal smoke." >&2
            exit 1
        }
        mv "$activation_destination" "$activation_backup"
        activation_json="{\"kind\":\"removed\",\"rootPath\":\"$activation_root\",\"destinationPath\":\"$activation_destination\",\"backupPath\":\"$activation_backup\"}"
    fi

    ditto "$candidate" "$staged"
    mkdir -p "$helper_dir"
    cp "$DESTINATION/Contents/MacOS/cmdy" "$helper"
    chmod 700 "$helper"
    mkdir "$lock_dir"
    cat > "$transaction" <<JSON
{
  "schemaVersion": 1,
  "token": "$token",
  "variant": "$variant",
  "destinationAppPath": "$DESTINATION",
  "stagedAppPath": "$staged",
  "backupAppPath": "$backup",
  "helperDirectoryPath": "$helper_dir",
  "lockDirectoryPath": "$lock_dir",
  "bundleIdentifier": "$BUNDLE_ID",
  "candidateVersion": "$VERSION",
  "candidateBuild": "$BUILD",
  "waitingPIDs": [],
  "activation": $activation_json,
  "browserComponentVersion": $browser_version_json,
  "createdAt": 0,
  "testOnlyExitAfterConfirmation": true,
  "testOnlySuppressConfirmation": $suppress_confirmation,
  "testOnlyConfirmationTimeoutSeconds": $confirmation_timeout,
  "state": "staged",
  "message": null
}
JSON
    cat > "$lock_dir/owner.json" <<JSON
{
  "schemaVersion": 1,
  "token": "$token",
  "transactionPath": "$transaction",
  "ownerPID": $$,
  "createdAt": 0,
  "activation": $activation_json
}
JSON
    if [ "$failure_mode" = "invalid-candidate" ]; then
        rm -f "$staged/Contents/Frameworks/libCmdyChromiumHost.dylib"
    fi

    local helper_status=0
    env HOME="$HOME_ROOT" CFFIXED_USER_HOME="$HOME_ROOT" \
        CMDY_CONFIG_DIR="$CONFIG_ROOT" \
        "$helper" --browser-component-swap-helper "$transaction" "$token" \
        || helper_status=$?
    if [ "$expected_state" = "completed" ] && [ "$helper_status" -ne 0 ]; then
        echo "component switch helper failed with status $helper_status" >&2
        exit 1
    fi
    if [ "$expected_state" = "failed" ] && [ "$helper_status" -ne 5 ]; then
        echo "failure-injected helper returned $helper_status, expected 5" >&2
        exit 1
    fi
    python3 -B - "$transaction" "$expected_state" <<'PY'
import json
import pathlib
import sys

transaction = json.loads(pathlib.Path(sys.argv[1]).read_text())
if transaction.get("state") != sys.argv[2]:
    raise SystemExit(f"component switch did not complete: {transaction}")
PY
    [ ! -e "$staged" ]
    [ ! -e "$backup" ]
    [ ! -e "$lock_dir" ]
    if [ "$expected_state" = "failed" ]; then
        test "$(plutil -extract CMDYBrowserEdition raw \
            "$DESTINATION/Contents/Info.plist" 2>/dev/null || true)" != true
        [ -f "$activation_destination/marker" ]
        test "$(plutil -extract enabled raw \
            "$activation_destination/manifest.json")" = "$activation_enabled"
        [ ! -e "$activation_backup" ]
        return
    fi
    if [ "$activation_kind" = "installed" ]; then
        [ -f "$activation_destination/manifest.json" ]
        [ ! -e "$activation_backup" ]
    elif [ "$activation_kind" = "removed" ]; then
        [ ! -e "$activation_destination" ]
        [ ! -e "$activation_backup" ]
    fi
}

run_switch "$BROWSER_APP" browser \
    11111111-1111-1111-1111-111111111111 browser-install-smoke installed false
test "$(plutil -extract CMDYBrowserEdition raw \
    "$DESTINATION/Contents/Info.plist")" = true
test "$(plutil -extract CMDYBrowserVersion raw \
    "$DESTINATION/Contents/Info.plist")" = \
    "$(tr -d '[:space:]' < Plugins/chromium/VERSION)"
test -f "$DESTINATION/Contents/Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework"
test -f "$DESTINATION/Contents/Frameworks/libCmdyChromiumHost.dylib"

run_switch "$LEAN_APP" lean \
    22222222-2222-2222-2222-222222222222 browser-remove-smoke removed
if plutil -extract CMDYBrowserEdition raw "$DESTINATION/Contents/Info.plist" \
    >/dev/null 2>&1; then
    echo "Lean replacement retained the Browser marker." >&2
    exit 1
fi
test ! -e "$DESTINATION/Contents/Frameworks/Chromium Embedded Framework.framework"
test ! -e "$DESTINATION/Contents/Frameworks/libCmdyChromiumHost.dylib"
test ! -e "$DESTINATION/Contents/Resources/BrowserMCP"

# Corrupt a staged Browser app after signing. The helper must refuse it and
# verify both app and prior activation rollback before releasing the lease.
run_switch "$BROWSER_APP" browser \
    33333333-3333-3333-3333-333333333333 browser-failure-smoke \
    installed true failed invalid-candidate
test -f "$CONFIG_ROOT/extensions/chromium/marker"

# Suppress the replacement's startup acknowledgement after the real app move.
# The helper must stop that app and restore both the lean bundle and activation.
rm -rf "$CONFIG_ROOT/extensions/chromium"
run_switch "$BROWSER_APP" browser \
    44444444-4444-4444-4444-444444444444 browser-confirmation-failure-smoke \
    installed true failed no-confirmation
test -f "$CONFIG_ROOT/extensions/chromium/marker"

echo "Browser component install/remove app-swap smoke passed."
