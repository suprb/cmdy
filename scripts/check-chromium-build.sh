#!/usr/bin/env bash
# Compile and smoke-test the complete optional Browser Extension after CEF bootstrap.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FRAMEWORKS="$ROOT/Plugins/chromium/Frameworks"
CEF_INCLUDE="$FRAMEWORKS/CEF"
CEF_FRAMEWORK="$FRAMEWORKS/Chromium Embedded Framework.framework"
HELPER_SOURCE="$ROOT/Plugins/chromium/Sources/ChromiumHost/ChromiumHelper.mm"

"$ROOT/scripts/bootstrap-chromium.sh" --check
"$ROOT/scripts/test-chromium-lifecycle.sh"
swift build --package-path "$ROOT/Plugins/chromium" -c release

TEMP_ROOT="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
WORK_DIR="$(mktemp -d "$TEMP_ROOT/cmdy-chromium-check.XXXXXX")"
cleanup() {
    case "$WORK_DIR" in
        "$TEMP_ROOT"/cmdy-chromium-check.*) rm -rf "$WORK_DIR" ;;
        *) printf 'check-chromium-build: refusing unsafe cleanup: %s\n' "$WORK_DIR" >&2 ;;
    esac
}
trap cleanup EXIT INT TERM

RUNTIME_FRAMEWORKS="$WORK_DIR/cmdy Browser Runtime.app/Contents/Frameworks"
HELPER_APP="$RUNTIME_FRAMEWORKS/cmdy Browser Runtime Helper.app"
HELPER_BIN="$HELPER_APP/Contents/MacOS/cmdy Browser Runtime Helper"
RUNTIME_MACOS="$WORK_DIR/cmdy Browser Runtime.app/Contents/MacOS"
mkdir -p "$(dirname "$HELPER_BIN")" "$RUNTIME_MACOS"
cat > "$WORK_DIR/runtime.c" <<'C'
int main(void) { return 0; }
C
xcrun clang -Os "$WORK_DIR/runtime.c" -o "$RUNTIME_MACOS/browser-runtime"
cat > "$WORK_DIR/cmdy Browser Runtime.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>browser-runtime</string>
  <key>CFBundleIdentifier</key><string>com.cmdy.chromium.check</string>
  <key>CFBundleName</key><string>cmdy Browser Runtime</string>
  <key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
cat > "$HELPER_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>cmdy Browser Runtime Helper</string>
  <key>CFBundleIdentifier</key><string>com.cmdy.chromium.check.helper</string>
  <key>CFBundleName</key><string>cmdy Browser Runtime Helper</string>
  <key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
ditto "$CEF_FRAMEWORK" \
    "$RUNTIME_FRAMEWORKS/Chromium Embedded Framework.framework"

clang++ -std=c++20 -ObjC++ -fobjc-arc -mmacosx-version-min=26.0 \
    -Wall -Wextra -Werror \
    -Wno-unused-parameter \
    -isystem "$CEF_INCLUDE" \
    "$HELPER_SOURCE" \
    "$FRAMEWORKS/libcef_dll_wrapper.a" \
    -framework Cocoa -framework IOKit \
    -o "$HELPER_BIN"

"$HELPER_BIN" \
    --type=renderer \
    --cmdy-sandbox-smoke

printf 'Sandboxed Chromium build checks passed.\n'
