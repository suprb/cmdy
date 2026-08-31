#!/bin/sh
set -u

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
printf '%s\n' "$$" > "$script_dir/stubborn.pid"

base="http://127.0.0.1:${CMDY_PORT:-${CMDY_PORT}}"
token="${CMDY_TOKEN:-${CMDY_TOKEN}}"
if ! /usr/bin/curl --fail --silent --show-error --max-time 2 \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d '{"commands":[{"id":"fixture.stubborn","title":"Fixture: Stubborn"}],"hotkeys":[],"hooks":[]}' \
    "${base}/v1/extensions/register" >/dev/null; then
  exit 7
fi

# An ignored disposition survives exec. This deliberately non-cooperative
# helper proves app shutdown escalates beyond SIGTERM without spawning a child.
trap '' TERM
exec /bin/sleep 30
