#!/bin/bash
# The TUI zoo: launch a test cmdy, drive real TUIs
# through the plugin SDK (HTTP type/run — never injected keystrokes), and
# screenshot every station by owner PID and emit deterministic evidence outside
# the repository by default. Set ZOO_OUT to preserve a specific destination.
#
#   Tests/zoo.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${CMDY_BIN:-$ROOT/.build/debug/cmdy}"
RUN="$(mktemp -d /tmp/cmdy-zoo.XXXXXX)"
if [ -n "${ZOO_OUT:-}" ]; then
  OUT="$ZOO_OUT"
else
  OUT="$(mktemp -d "${TMPDIR:-/private/tmp}/cmdy-zoo-evidence.XXXXXX")"
fi
MANIFEST="${ZOO_MANIFEST:-$OUT/capture-manifest.json}"
WINSHOT="${ZOO_WINSHOT:-$ROOT/Tests/winshot.swift}"
CFG="$RUN/config"
DEFAULTS_DOMAIN="com.cmdy.zoo.$(basename "$RUN")"
CAPTURE_COUNT=0

for required_tool in curl htop man less python3 shasum swift tmux vim; do
  command -v "$required_tool" >/dev/null || {
    echo "missing required zoo tool: $required_tool" >&2
    exit 1
  }
done

mkdir -p "$OUT"
[ -x "$BIN" ] || {
  echo "cmdy binary is missing or not executable: $BIN" >&2
  exit 1
}

restore() {
  if [ -n "${APP_PID:-}" ]; then
    kill -TERM "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  /usr/bin/defaults delete "$DEFAULTS_DOMAIN" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$DEFAULTS_DOMAIN.plist"
  rm -rf "$RUN"
}
trap restore EXIT

mkdir -p "$CFG"
cat > "$CFG/config" <<EOF
theme = C64
cursor-style = block
cursor-blink = false
banner = false
restore-session = false
shader = None
sounds = false
ghost-text = false
EOF

APP_BINARY_SHA256="$(shasum -a 256 "$BIN")"
APP_BINARY_SHA256="${APP_BINARY_SHA256%% *}"

cd /private/tmp
CMDY_DEFAULTS_DOMAIN="$DEFAULTS_DOMAIN" CMDY_CONFIG_DIR="$CFG" "$BIN" &
APP_PID=$!

API_FILE="$CFG/plugin-api.json"
parse_api_discovery() {
  python3 - "$API_FILE" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as handle:
    payload = json.load(handle)
if not isinstance(payload, dict):
    raise SystemExit("plugin API discovery root is not an object")
port = payload.get("port")
token = payload.get("token")
if isinstance(port, bool) or not isinstance(port, int) or not 1 <= port <= 65535:
    raise SystemExit("plugin API port is invalid")
if payload.get("api") != "v1":
    raise SystemExit("plugin API version is not v1")
if (not isinstance(token, str) or not token
        or any(character.isspace() or ord(character) < 0x20 for character in token)):
    raise SystemExit("plugin API token is invalid")
print(f"{port}\t{token}")
PY
}
API_INFO=""
attempt=0
while [ "$attempt" -lt 60 ]; do
  if [ -s "$API_FILE" ] \
      && API_INFO=$(parse_api_discovery 2>/dev/null); then
    break
  fi
  kill -0 "$APP_PID" 2>/dev/null || {
    echo "cmdy exited before publishing its plugin API" >&2
    exit 1
  }
  API_INFO=""
  sleep 0.1
  attempt=$((attempt + 1))
done
[ -n "$API_INFO" ] || {
  echo "plugin API discovery file is invalid" >&2
  exit 1
}
IFS=$'\t' read -r PORT TOKEN <<< "$API_INFO"
[ -n "$PORT" ] && [ -n "$TOKEN" ] || {
  echo "plugin API did not publish a usable port and token" >&2
  exit 1
}

api() {  # api <method> <path> [json]
  local method="$1"
  local path="$2"
  if [ "$#" -eq 3 ]; then
    curl --fail --silent --show-error --connect-timeout 3 --max-time 15 -X "$method" \
      "http://127.0.0.1:$PORT$path" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      --data "$3"
  else
    curl --fail --silent --show-error --connect-timeout 3 --max-time 15 -X "$method" \
      "http://127.0.0.1:$PORT$path" \
      -H "Authorization: Bearer $TOKEN"
  fi
}

parse_first_pane() {
  python3 -c '
import json
import sys

payload = json.load(sys.stdin)
if not isinstance(payload, dict):
    raise SystemExit("panes response root is not an object")
if "error" in payload:
    raise SystemExit("panes response contains an error")
panes = payload.get("panes")
if not isinstance(panes, list) or not panes or not isinstance(panes[0], dict):
    raise SystemExit("panes response has no pane object")
pane_id = panes[0].get("id")
if (not isinstance(pane_id, str) or not pane_id
        or any(character in pane_id for character in "/\r\n")):
    raise SystemExit("panes response has an invalid pane id")
print(pane_id)
'
}
PANE=""
attempt=0
while [ "$attempt" -lt 60 ]; do
  if PANE=$(api GET /v1/panes 2>/dev/null | parse_first_pane 2>/dev/null); then
    break
  fi
  kill -0 "$APP_PID" 2>/dev/null || {
    echo "cmdy exited before publishing a usable pane" >&2
    exit 1
  }
  PANE=""
  sleep 0.1
  attempt=$((attempt + 1))
done
[ -n "$PANE" ] || {
  echo "plugin API returned no usable pane" >&2
  exit 1
}
echo "pane $PANE on port $PORT"

shot() {
  sleep "$2"
  kill -0 "$APP_PID" 2>/dev/null || {
    echo "cmdy exited before screenshot $1" >&2
    exit 1
  }
  swift "$WINSHOT" "$APP_PID" "$OUT/$1.png" >/dev/null
  [ -s "$OUT/$1.png" ] || {
    echo "screenshot $1 was not created" >&2
    exit 1
  }
  CAPTURE_COUNT=$((CAPTURE_COUNT + 1))
  echo "  ▸ $1"
}

json_body() {
  python3 -c 'import json,sys; print(json.dumps({sys.argv[1]: sys.argv[2]}))' "$1" "$2"
}
require_ok_json() {
  python3 -c '
import json
import sys

payload = json.load(sys.stdin)
if (not isinstance(payload, dict) or payload.get("ok") is not True
        or "error" in payload):
    raise SystemExit("plugin API mutation response did not contain ok=true")
'
}
type_text() {
  local body
  body="$(json_body text "$1")"
  api POST "/v1/panes/$PANE/type" "$body" | require_ok_json
}
run_cmd() {
  local body
  body="$(json_body command "$1")"
  api POST "/v1/panes/$PANE/run" "$body" | require_ok_json
}

shot "00-shell" 1

# ── vim: open a real source file, insert text, split, quit ──
run_cmd "vim -u NONE -i NONE $ROOT/App/main.swift"
shot "01-vim-open" 2
type_text "50j"
shot "02-vim-scrolled" 1
type_text $':sp\r'
shot "03-vim-split" 1
type_text $':qa!\r'
sleep 2

# ── less + man ──
run_cmd "man ls"
shot "04-man" 2
type_text "q"
sleep 2
run_cmd "seq 1 500 | less -N"
shot "05-less" 2
type_text "G"
shot "06-less-end" 1
type_text "q"
sleep 2

# ── htop: the alt-screen + color + mouse-mode workout ──
run_cmd "htop"
shot "07-htop" 3
type_text "q"
sleep 2

# ── tmux: nested terminal, splits, status bar ──
run_cmd "tmux -f /dev/null -L zoo new-session"
shot "08-tmux" 2
type_text $'echo hello from tmux inside cmdy\r'
shot "09-tmux-echo" 1
type_text $'\002%'
shot "10-tmux-split" 1
type_text $'tmux kill-server\r'
sleep 2

# ── throughput sanity: cat 10MB ──
run_cmd "test -f /tmp/zoo-10mb.txt || base64 < /dev/urandom | head -c 10000000 > /tmp/zoo-10mb.txt"
sleep 2
run_cmd "time cat /tmp/zoo-10mb.txt > /dev/tty"
shot "11-cat-10mb" 6

# ── Claude Code: the alt-screen + SGR-mouse app the wheel policy exists for ──
CLAUDE_STATUS="skipped"
if command -v claude >/dev/null; then
  run_cmd "claude"
  shot "12-claude-code" 8
  type_text $'\033\033'
  sleep 1
  run_cmd "exit"
  sleep 1
  CLAUDE_STATUS="present"
else
  echo "  ▸ 12-claude-code skipped (command unavailable)"
fi

shot "99-shell-after" 1
actual_capture_count=$(find "$OUT" -maxdepth 1 -type f -name '*.png' | wc -l | tr -d ' ')
[ "$actual_capture_count" -eq "$CAPTURE_COUNT" ] || {
  echo "zoo capture count mismatch: expected $CAPTURE_COUNT, found $actual_capture_count" >&2
  exit 1
}
if [ "$CLAUDE_STATUS" = "present" ]; then
  python3 -B "$ROOT/scripts/check-zoo-review.py" capture-manifest \
    --captures "$OUT" \
    --app-binary "$BIN" \
    --expected-app-sha256 "$APP_BINARY_SHA256" \
    --claude-status present \
    --output "$MANIFEST"
else
  python3 -B "$ROOT/scripts/check-zoo-review.py" capture-manifest \
    --captures "$OUT" \
    --app-binary "$BIN" \
    --expected-app-sha256 "$APP_BINARY_SHA256" \
    --claude-status skipped \
    --claude-skip-reason command-unavailable \
    --output "$MANIFEST"
fi
echo "zoo complete ($CAPTURE_COUNT captures) → $OUT"
echo "capture manifest → $MANIFEST"
