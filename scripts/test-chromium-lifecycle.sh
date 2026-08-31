#!/usr/bin/env bash
# Compile and run the CEF-independent state machine used by the real bridge.
set -euo pipefail
cd "$(dirname "$0")/.."

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/cmdy-cef-lifecycle.XXXXXX")"
cleanup() {
  case "$work_dir" in
    "${TMPDIR:-/tmp}"/cmdy-cef-lifecycle.*) rm -rf "$work_dir" ;;
  esac
}
trap cleanup EXIT INT TERM

clang++ -std=c++20 -Wall -Wextra -Werror \
  Plugins/chromium/Tests/CEFBridgeLifecycleTests.cpp \
  -o "$work_dir/cef-bridge-lifecycle-tests"
"$work_dir/cef-bridge-lifecycle-tests"
printf 'Chromium bridge lifecycle tests passed.\n'
