#!/usr/bin/env bash
# Build the Zig archive and then the normal macOS app through SwiftPM.
set -euo pipefail
cd "$(dirname "$0")"

configuration=debug
configuration_seen=
arch_arm64=0
arch_x86_64=0
triple_arch=
target_triple=

fail() { echo "build.sh: $*" >&2; exit 2; }
value_required() {
  [ -n "${2:-}" ] && [[ "$2" != -* ]] || fail "$1 requires a value"
}
set_configuration() {
  case "$1" in debug|release) ;; *) fail "Expected Swift configuration debug or release" ;; esac
  [ -z "$configuration_seen" ] || [ "$configuration" = "$1" ] || fail "Conflicting Swift configurations"
  configuration="$1"
  configuration_seen=1
}
set_architecture() {
  case "$1" in
    arm64) arch_arm64=1 ;;
    x86_64) arch_x86_64=1 ;;
    *) fail "Unsupported architecture $1; use arm64, x86_64, or both --arch flags" ;;
  esac
}
set_triple() {
  [ -z "$target_triple" ] || [ "$target_triple" = "$1" ] || fail "Conflicting target triples"
  # The engine and package require macOS 26. A versionless macOS triple uses
  # the package deployment target; other OS targets need a separate port.
  local pattern='^(arm64|aarch64|x86_64)-apple-macosx([0-9]+(\.[0-9]+){0,2})?$'
  [[ "$1" =~ $pattern ]] || fail "Unsupported target triple $1; expected a macOS arm64 or x86_64 triple"
  triple_arch="${BASH_REMATCH[1]}"
  local version="${BASH_REMATCH[2]}"
  if [ -n "$version" ]; then
    local major="${version%%.*}"
    [ "$((10#$major))" -ge 26 ] || fail "Target triple $1 is older than the required macOS 26"
  fi
  [ "$triple_arch" != aarch64 ] || triple_arch=arm64
  target_triple="$1"
}
parse_arguments() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -c|--configuration) value_required "$1" "${2:-}"; set_configuration "$2"; shift ;;
      --configuration=*) set_configuration "${1#*=}" ;;
      --arch) value_required "$1" "${2:-}"; set_architecture "$2"; shift ;;
      --arch=*) set_architecture "${1#*=}" ;;
      --triple) value_required "$1" "${2:-}"; set_triple "$2"; shift ;;
      --triple=*) set_triple "${1#*=}" ;;
      --manifest-cache)
        value_required "$1" "${2:-}"
        [ "$2" = none ] || fail "Native archive selection requires --manifest-cache none"
        shift ;;
      --manifest-cache=*)
        [ "${1#*=}" = none ] || fail "Native archive selection requires --manifest-cache none" ;;
      --enable-build-manifest-caching)
        fail "Native archive selection requires --disable-build-manifest-caching" ;;
      --destination|--destination=*|--swift-sdk|--swift-sdk=*)
        fail "Use --arch or a macOS --triple so Swift and Zig select the same target" ;;
      -Xcc|-Xcxx|-Xswiftc|-Xlinker)
        [ "$#" -ge 2 ] || fail "$1 requires a value"
        shift ;;
    esac
    shift
  done
}
parse_arguments "$@"
case "$configuration" in
  debug) native_mode=Debug ;;
  release) native_mode=ReleaseFast ;;
  *) echo "Expected Swift configuration debug or release" >&2; exit 2 ;;
esac
if [ "$arch_arm64" -eq 1 ] && [ "$arch_x86_64" -eq 1 ]; then
  native_arch=universal
elif [ "$arch_arm64" -eq 1 ]; then
  native_arch=arm64
elif [ "$arch_x86_64" -eq 1 ]; then
  native_arch=x86_64
else
  native_arch="${triple_arch:-$(uname -m)}"
fi
if [ -n "$triple_arch" ] && [ "$native_arch" != "$triple_arch" ]; then
  fail "--arch and --triple select different targets"
fi
case "$native_arch" in arm64|x86_64|universal) ;; *) fail "Unsupported host architecture $native_arch" ;; esac
case "${CMDY_NATIVE_ARCH:-native}" in
  native) ;;
  universal) native_arch=universal ;;
  arm64|x86_64)
    [ "$CMDY_NATIVE_ARCH" = "$native_arch" ] || fail "CMDY_NATIVE_ARCH does not cover the Swift target; use matching --arch or --triple flags"
    native_arch="$CMDY_NATIVE_ARCH" ;;
  *) fail "Unsupported CMDY_NATIVE_ARCH: $CMDY_NATIVE_ARCH" ;;
esac
if [ -z "${CMDY_ZIG:-}" ]; then
  CMDY_ZIG="$(./scripts/bootstrap-zig.sh)"
  export CMDY_ZIG
fi
python3 Core/Tools/ZigEngine/build.py --optimize "$native_mode" --arch "$native_arch"
# Package.swift reads the selected native receipt. SwiftPM caches both the
# package manifest and the resulting build plan; either cache can otherwise
# retain the previous immutable archive and compiler selection after a rebuild.
exec swift build --manifest-cache none --disable-build-manifest-caching "$@"
