#!/bin/sh
set -u

base="http://127.0.0.1:${CMDY_PORT}"
if ! /usr/bin/curl --fail --silent --show-error --max-time 2 \
    -H "Authorization: Bearer ${CMDY_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"commands":[{"id":"fixture.one","title":"Fixture: One"},{"id":"fixture.two","title":"Fixture: Two"},{"id":"fixture.three","title":"Fixture: Three"}],"hotkeys":[],"hooks":[]}' \
    "${base}/v1/extensions/register" >/dev/null; then
  echo "could not register fixture batch" >&2
  exit 7
fi

# Exercise the complete authenticated Adaptive Frame route with a real
# launched Extension credential. A failure terminates the fixture and makes
# --plugin-menu report the launch as failed.
if ! /usr/bin/curl --fail --silent --show-error --max-time 2 \
    -H "Authorization: Bearer ${CMDY_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"id":"fixture-workspace","location":"navigator","title":"Fixture","sequence":0,"items":[{"id":"ready","title":"Ready","status":"success","action":"pick"}]}' \
    "${base}/v1/ui/contributions" >/dev/null; then
  echo "could not register fixture workspace contribution" >&2
  exit 7
fi

if ! /usr/bin/curl --fail --silent --show-error --max-time 2 \
    -H "Authorization: Bearer ${CMDY_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"sequence":1,"items":[{"id":"ready","title":"Updated","status":"active","action":"pick"}]}' \
    "${base}/v1/ui/contributions/fixture-workspace/update" >/dev/null; then
  echo "could not update fixture workspace contribution" >&2
  exit 7
fi

# Remain alive until the diagnostic deactivates Extensions, without leaving a
# child process behind after SIGTERM.
exec /bin/sleep 30
