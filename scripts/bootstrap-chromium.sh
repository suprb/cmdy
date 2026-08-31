#!/usr/bin/env bash
# Fetch and build the exact CEF toolchain used by cmdy's optional Browser Extension.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FRAMEWORKS="$ROOT/Plugins/chromium/Frameworks"
BRIDGE_SOURCE="$ROOT/Plugins/chromium/Sources/CEFBridge/cef_bridge.mm"
BRIDGE_HEADER="$ROOT/Plugins/chromium/Sources/CEFBridge/include/cef_bridge.h"
BRIDGE_LIFECYCLE="$ROOT/Plugins/chromium/Sources/CEFBridge/bridge_lifecycle.h"

CEF_VERSION="145.0.28+g51162e8+chromium-145.0.7632.160"
CEF_ARCHIVE="cef_binary_${CEF_VERSION}_macosarm64.tar.bz2"
CEF_URL="https://cef-builds.spotifycdn.com/${CEF_ARCHIVE//+/%2B}"
CEF_SHA256="2c0d7b03a8548ce0fe4ce4ee79097dec03e95646c0622a19054fe6a7cfb65599"
CEF_BOOTSTRAP_FORMAT="4"

die() {
    printf 'bootstrap-chromium: %s\n' "$*" >&2
    exit 1
}

installed_version() {
    [ -f "$FRAMEWORKS/.cef-version" ] || return 1
    cat "$FRAMEWORKS/.cef-version"
}

bridge_digest() {
    shasum -a 256 "$BRIDGE_SOURCE" "$BRIDGE_HEADER" "$BRIDGE_LIFECYCLE" \
        | awk '{print $1}' \
        | shasum -a 256 \
        | awk '{print $1}'
}

check_install() {
    [ "$(installed_version 2>/dev/null || true)" = "$CEF_VERSION" ] || return 1
    [ "$(cat "$FRAMEWORKS/.cef-bootstrap-format" 2>/dev/null || true)" \
        = "$CEF_BOOTSTRAP_FORMAT" ] || return 1
    [ -f "$FRAMEWORKS/Chromium Embedded Framework.framework/Chromium Embedded Framework" ] || return 1
    [ -d "$FRAMEWORKS/CEF/include" ] || return 1
    [ -f "$FRAMEWORKS/libcef_dll_wrapper.a" ] || return 1
    [ -f "$FRAMEWORKS/libcef_bridge.a" ] || return 1
    [ "$(cat "$FRAMEWORKS/.cef-bridge.sha256" 2>/dev/null || true)" \
        = "$(bridge_digest)" ] || return 1
    [ -f "$FRAMEWORKS/CEF-LICENSE.txt" ] || return 1
    [ -f "$FRAMEWORKS/CEF-CREDITS.html" ] || return 1
}

if [ "${1:-}" = "--check" ]; then
    check_install || die "CEF $CEF_VERSION is not fully bootstrapped"
    printf 'CEF %s is ready.\n' "$CEF_VERSION"
    exit 0
fi
[ "$#" -eq 0 ] || die "usage: $0 [--check]"

[ "$(uname -s)" = "Darwin" ] || die "CEF Browser development is supported on macOS"
[ "$(uname -m)" = "arm64" ] || die "the pinned Browser payload targets Apple silicon"
for command_name in cmake curl shasum tar clang++ libtool ditto; do
    command -v "$command_name" >/dev/null || die "missing required tool: $command_name"
done
for bridge_input in "$BRIDGE_SOURCE" "$BRIDGE_HEADER" "$BRIDGE_LIFECYCLE"; do
    [ -f "$bridge_input" ] || die "missing open-source CEF bridge input: $bridge_input"
done

if check_install; then
    printf 'CEF %s is already ready.\n' "$CEF_VERSION"
    exit 0
fi
if [ -e "$FRAMEWORKS" ] || [ -L "$FRAMEWORKS" ]; then
    die "$FRAMEWORKS already exists but does not match the pinned payload; move it aside and retry"
fi

TEMP_ROOT="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
WORK_DIR="$(mktemp -d "$TEMP_ROOT/cmdy-cef.XXXXXX")"
cleanup() {
    case "$WORK_DIR" in
        "$TEMP_ROOT"/cmdy-cef.*) rm -rf "$WORK_DIR" ;;
        *) printf 'bootstrap-chromium: refusing to remove unexpected path %s\n' "$WORK_DIR" >&2 ;;
    esac
}
trap cleanup EXIT INT TERM

ARCHIVE_PATH="$WORK_DIR/$CEF_ARCHIVE"
if [ -n "${CMDY_CEF_ARCHIVE:-}" ]; then
    [ -f "$CMDY_CEF_ARCHIVE" ] || die "CMDY_CEF_ARCHIVE does not name a file"
    cp "$CMDY_CEF_ARCHIVE" "$ARCHIVE_PATH"
else
    printf 'Downloading CEF %s (about 257 MiB)...\n' "$CEF_VERSION"
    curl --fail --location --retry 3 --output "$ARCHIVE_PATH" "$CEF_URL"
fi

ACTUAL_SHA256="$(shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}')"
[ "$ACTUAL_SHA256" = "$CEF_SHA256" ] || \
    die "CEF checksum mismatch: expected $CEF_SHA256, got $ACTUAL_SHA256"

tar -xjf "$ARCHIVE_PATH" -C "$WORK_DIR"
CEF_ROOT="$WORK_DIR/cef_binary_${CEF_VERSION}_macosarm64"
[ -d "$CEF_ROOT" ] || die "archive did not contain the expected CEF root"

printf 'Building the CEF C++ wrapper...\n'
BUILD_DIR="$WORK_DIR/build"
CEF_PREFIX_MAP_FLAGS="-ffile-prefix-map=$WORK_DIR=/cmdy-cef -fmacro-prefix-map=$WORK_DIR=/cmdy-cef"
cmake -S "$CEF_ROOT" -B "$BUILD_DIR" -G Xcode \
    -DPROJECT_ARCH=arm64 \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
    -DCMAKE_C_FLAGS_RELEASE="$CEF_PREFIX_MAP_FLAGS" \
    -DCMAKE_CXX_FLAGS_RELEASE="$CEF_PREFIX_MAP_FLAGS"
cmake --build "$BUILD_DIR" --config Release --target libcef_dll_wrapper
WRAPPER_ARCHIVE="$(find "$BUILD_DIR" -name libcef_dll_wrapper.a -type f -print -quit)"
[ -n "$WRAPPER_ARCHIVE" ] || die "CEF wrapper build produced no archive"

printf "Building cmdy's CEF bridge...\n"
BRIDGE_OBJECT="$WORK_DIR/cef_bridge.o"
clang++ -std=c++20 -ObjC++ -fobjc-arc -mmacosx-version-min=26.0 \
    -ffile-prefix-map="$ROOT"=/cmdy-source \
    -fmacro-prefix-map="$ROOT"=/cmdy-source \
    -ffile-prefix-map="$WORK_DIR"=/cmdy-cef \
    -fmacro-prefix-map="$WORK_DIR"=/cmdy-cef \
    -I "$CEF_ROOT" \
    -I "$ROOT/Plugins/chromium/Sources/CEFBridge" \
    -c "$BRIDGE_SOURCE" -o "$BRIDGE_OBJECT"
libtool -static -o "$WORK_DIR/libcef_bridge.a" "$BRIDGE_OBJECT"

STAGED="$WORK_DIR/Frameworks"
mkdir -p "$STAGED/CEF"
ditto "$CEF_ROOT/Release/Chromium Embedded Framework.framework" \
    "$STAGED/Chromium Embedded Framework.framework"
ditto "$CEF_ROOT/include" "$STAGED/CEF/include"
cp "$WRAPPER_ARCHIVE" "$STAGED/libcef_dll_wrapper.a"
cp "$WORK_DIR/libcef_bridge.a" "$STAGED/libcef_bridge.a"
cp "$CEF_ROOT/LICENSE.txt" "$STAGED/CEF-LICENSE.txt"
cp "$CEF_ROOT/CREDITS.html" "$STAGED/CEF-CREDITS.html"
printf '%s\n' "$CEF_VERSION" > "$STAGED/.cef-version"
printf '%s\n' "$CEF_BOOTSTRAP_FORMAT" > "$STAGED/.cef-bootstrap-format"
bridge_digest > "$STAGED/.cef-bridge.sha256"
printf '%s  %s\n' "$CEF_SHA256" "$CEF_ARCHIVE" > "$STAGED/.cef-archive.sha256"

mv "$STAGED" "$FRAMEWORKS"
check_install || die "post-install verification failed"
printf 'CEF %s is ready at %s.\n' "$CEF_VERSION" "$FRAMEWORKS"
