#!/usr/bin/env bash
# Pinned upstream compiler for local and CI builds. Prints the executable path.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version=0.15.2
if command -v zig >/dev/null 2>&1 && [ "$(zig version)" = "$version" ]; then
  command -v zig
  exit 0
fi
case "$(uname -s):$(uname -m)" in
  Darwin:arm64)
    architecture=aarch64
    expected_sha=3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b ;;
  Darwin:x86_64)
    architecture=x86_64
    expected_sha=375b6909fc1495d16fc2c7db9538f707456bfc3373b14ee83fdd3e22b3d43f7f ;;
  *) echo "This app toolchain bootstrap currently supports macOS." >&2; exit 2 ;;
esac
# SHA-256 values are pinned from https://ziglang.org/download/index.json.
name="zig-$architecture-macos-$version"
toolchains="$repo_root/.zig-toolchain"
destination="$toolchains/$name"
if [ -x "$destination/zig" ] && [ "$("$destination/zig" version)" = "$version" ]; then
  echo "$destination/zig"
  exit 0
fi
mkdir -p "$toolchains"
temporary="$(mktemp -d "$toolchains/download.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
curl --fail --location --retry 3 --output "$temporary/zig.tar.xz" \
  "https://ziglang.org/download/$version/$name.tar.xz" >&2
actual_sha="$(shasum -a 256 "$temporary/zig.tar.xz" | awk '{print $1}')"
if [ "$actual_sha" != "$expected_sha" ]; then
  echo "Zig download checksum mismatch" >&2
  exit 1
fi
tar -xJf "$temporary/zig.tar.xz" -C "$temporary"
if [ -e "$destination" ]; then
  echo "Existing Zig toolchain is incomplete: $destination" >&2
  exit 1
fi
mv "$temporary/$name" "$destination"
echo "$destination/zig"
