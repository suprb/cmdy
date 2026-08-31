#!/bin/bash
# Focused stations: measured 10MB-cat throughput + a settled Claude Code
# capture. usage: zoo-focus.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/debug/cmdy"
RUN="$(mktemp -d /tmp/cmdy-zoo-focus.XXXXXX)"
OUT="${ZOO_OUT:-$ROOT/Tests/zoo-results/cmdy}"
WINSHOT="${ZOO_WINSHOT:-$ROOT/Tests/winshot.swift}"
CFG="$RUN/config"
DEFAULTS_DOMAIN="com.cmdy.zoo-focus.$(basename "$RUN")"
mkdir -p "$OUT"

restore() {
  [ -n "${APP_PID:-}" ] && kill -TERM "$APP_PID" 2>/dev/null
  /usr/bin/defaults delete "$DEFAULTS_DOMAIN" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$DEFAULTS_DOMAIN.plist"
  rm -rf "$RUN"
  true
}
trap restore EXIT

mkdir -p "$CFG"
printf 'theme = C64\ncursor-style = block\ncursor-blink = false\nbanner = false\nrestore-session = false\nshader = None\nsounds = false\nghost-text = false\n' > "$CFG/config"

cd /private/tmp
CMDY_DEFAULTS_DOMAIN="$DEFAULTS_DOMAIN" CMDY_CONFIG_DIR="$CFG" "$BIN" &
APP_PID=$!
sleep 3

PORT=$(python3 -c "import json;print(json.load(open('$CFG/plugin-api.json'))['port'])")
TOKEN=$(python3 -c "import json;print(json.load(open('$CFG/plugin-api.json'))['token'])")
api() { curl -s -X "$1" "http://127.0.0.1:$PORT$2" -H "Authorization: Bearer $TOKEN" ${3:+-H "Content-Type: application/json" -d "$3"}; }
PANE=$(api GET /v1/panes | python3 -c "import json,sys;print(json.load(sys.stdin)['panes'][0]['id'])")

# ── throughput: time cat 10MB, read the timing back from the pane ──
test -f /tmp/zoo-10mb.txt || base64 < /dev/urandom | head -c 10000000 > /tmp/zoo-10mb.txt
api POST "/v1/panes/$PANE/run" '{"command": "time cat /tmp/zoo-10mb.txt"}' >/dev/null
for _ in $(seq 1 60); do
  sleep 1
  TEXT=$(api GET "/v1/panes/$PANE/output?lines=6" | python3 -c "import json,sys;print(json.load(sys.stdin).get('text',''))" 2>/dev/null)
  if echo "$TEXT" | grep -q "cpu "; then break; fi
done
echo "── cat-10MB timing:"
echo "$TEXT" | grep -E "cat .* total|cpu" | tail -2

# ── Claude Code, given room to settle ──
if command -v claude >/dev/null; then
  api POST "/v1/panes/$PANE/run" '{"command": "claude"}' >/dev/null
  sleep 12
  swift "$WINSHOT" "$APP_PID" "$OUT/12-claude-code.png" >/dev/null && echo "  ▸ 12-claude-code (retaken)"
fi
