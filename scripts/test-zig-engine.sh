#!/usr/bin/env bash
# Runs the native engine's Zig tests with the same platform boundary as
# Core/Tools/ZigEngine/build.py: the C headers, the Objective-C platform
# objects and the Apple frameworks they use.
set -euo pipefail

cd "$(dirname "$0")/.."
optimize="${1:-Debug}"
zig="${CMDY_ZIG:-zig}"
arch="$(uname -m)"
zig_arch="$arch"
if [ "$arch" = arm64 ]; then zig_arch=aarch64; fi
clang_opt=-O0
case "$optimize" in ReleaseSafe) clang_opt=-O2 ;; ReleaseFast) clang_opt=-O3 ;; esac

sdk="$(xcrun --sdk macosx --show-sdk-path)"
clang="$(xcrun --find clang)"
work="$(mktemp -d "${TMPDIR:-/tmp}/cmdy-zig-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

objects=()
for source in Core/Platform/*.m; do
    object="$work/$(basename "$source").o"
    "$clang" -c "$source" -o "$object" -target "$arch-apple-macosx26.0" -isysroot "$sdk" \
        -I Core/Sources/CmdyNative/include -I Core/Platform -fblocks -fobjc-arc "$clang_opt"
    objects+=("$object")
done

frameworks=()
for framework in AppKit Foundation CoreFoundation CoreGraphics CoreText Metal MetalKit QuartzCore ImageIO; do
    frameworks+=(-framework "$framework")
done

"$zig" test Core/Zig/tests.zig "${objects[@]}" -lc -lobjc "${frameworks[@]}" \
    -O "$optimize" -target "$zig_arch-macos.26.0.0" \
    --sysroot "$sdk" "-F$sdk/System/Library/Frameworks" -L/usr/lib -isystem "$sdk/usr/include" \
    -ICore/Sources/CmdyNative/include -ICore/Platform
