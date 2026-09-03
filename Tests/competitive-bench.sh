#!/bin/bash
# Same-machine terminal drain baseline. Both terminals print the same payload,
# then issue DSR (CSI 6 n) and wait for the response. The timer cannot finish
# until the terminal has parsed the payload and reached the query.
#
# This opens one maximized Cmdy window and one large Ghostty window. Existing
# Ghostty processes are left alone; only the benchmark instance is terminated.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CMDY_BIN="${CMDY_BIN:-$ROOT/.build/release/cmdy}"
GHOSTTY_APP="${GHOSTTY_APP:-/Applications/Ghostty.app}"
GHOSTTY_BIN="$GHOSTTY_APP/Contents/MacOS/ghostty"
WORKLOAD="${CMDY_BENCH_WORKLOAD:-continuous}"
BENCH_BYTES="${CMDY_BENCH_BYTES:-3000000}"
RUN="$(mktemp -d /tmp/cmdy-competitive.XXXXXX)"
DEFAULTS_DOMAIN="com.cmdy.bench.$(basename "$RUN")"
CMDY_PID=""
GHOSTTY_PID=""

cleanup() {
  [ -n "$CMDY_PID" ] && kill -TERM "$CMDY_PID" 2>/dev/null || true
  [ -n "$GHOSTTY_PID" ] && kill -TERM "$GHOSTTY_PID" 2>/dev/null || true
  /usr/bin/defaults delete "$DEFAULTS_DOMAIN" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$DEFAULTS_DOMAIN.plist"
  rm -rf "$RUN"
}
trap cleanup EXIT

[ -x "$CMDY_BIN" ] || { echo "missing $CMDY_BIN; run swift build -c release"; exit 1; }
[ -x "$GHOSTTY_BIN" ] || { echo "missing $GHOSTTY_BIN"; exit 1; }

case "$WORKLOAD" in
  continuous)
    /bin/dd if=/dev/zero bs="$BENCH_BYTES" count=1 2>/dev/null \
      | LC_ALL=C /usr/bin/tr '\000' 'A' > "$RUN/payload.txt"
    ;;
  lines)
    # The PTY's ONLCR output processing turns LF into the CRLF bytes received
    # by the emulator. Supplying CRLF here would benchmark the artificial
    # CR-CR-LF sequence instead of ordinary command output.
    /usr/bin/perl -e '$p = ("A" x 76) . "\n"; $n = $ARGV[0];
      print $p x int($n / length($p)); print substr($p, 0, $n % length($p));' \
      "$BENCH_BYTES" > "$RUN/payload.txt"
    ;;
  *) echo "unknown CMDY_BENCH_WORKLOAD=$WORKLOAD (continuous|lines)"; exit 1 ;;
esac

cat > "$RUN/drain.sh" <<'BENCH'
#!/bin/zsh
zmodload zsh/datetime
sleep 2
result="$CMDY_BENCH_DIR/${TERM_PROGRAM}.time"
grid="$CMDY_BENCH_DIR/${TERM_PROGRAM}.grid"
ok="$CMDY_BENCH_DIR/${TERM_PROGRAM}.ok"
rm -f "$result" "$ok"
stty size > "$grid"
for _ in 1 2 3 4 5; do
  saved=$(stty -g)
  stty -echo -icanon min 0 time 100
  started=$EPOCHREALTIME
  if ! { cat "$CMDY_BENCH_PAYLOAD"; printf "\033[6n"; IFS= read -r -d R response; }; then
    stty "$saved"
    exit 1
  fi
  printf '%.6f\n' $((EPOCHREALTIME - started)) >> "$result"
  stty "$saved"
done
: > "$ok"
sleep 1
BENCH
chmod 700 "$RUN/drain.sh"

cat > "$RUN/config" <<'CFG'
restore-session = false
shell-integration = true
clean-prompt = true
sounds = false
ghost-text = false
shader = None
smooth-cursor = false
smooth-scroll = false
cursor-style = block
cursor-blink = false
font-family = DepartureMono-Regular
font-size = 15
line-height = 0.85
CFG

echo "Cmdy: maximized $BENCH_BYTES-byte $WORKLOAD DSR drain x5"
CMDY_DEFAULTS_DOMAIN="$DEFAULTS_DOMAIN" CMDY_CONFIG_DIR="$RUN" \
CMDY_BENCH_DIR="$RUN" \
CMDY_BENCH_PAYLOAD="$RUN/payload.txt" \
  "$CMDY_BIN" --ui-test-maximized-perf > "$RUN/cmdy.log" 2>&1 &
CMDY_PID=$!
for _ in $(seq 1 100); do [ -f "$RUN/plugin-api.json" ] && break; sleep 0.1; done
[ -f "$RUN/plugin-api.json" ] || { cat "$RUN/cmdy.log"; exit 1; }
PORT=$(python3 -c "import json;print(json.load(open('$RUN/plugin-api.json'))['port'])")
TOKEN=$(python3 -c "import json;print(json.load(open('$RUN/plugin-api.json'))['token'])")
PANE=$(/usr/bin/curl -s -H "Authorization: Bearer $TOKEN" \
  "http://127.0.0.1:$PORT/v1/panes" \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['panes'][0]['id'])")
BODY=$(python3 -c 'import json,sys;print(json.dumps({"command":sys.argv[1]}))' "$RUN/drain.sh")
/usr/bin/curl -s -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -X POST "http://127.0.0.1:$PORT/v1/panes/$PANE/run" -d "$BODY" >/dev/null
for _ in $(seq 1 600); do
  [ -f "$RUN/cmdy.ok" ] && break
  sleep 0.1
done
[ -f "$RUN/cmdy.ok" ] || { echo "Cmdy benchmark timed out or DSR failed"; exit 1; }
kill -TERM "$CMDY_PID" 2>/dev/null || true
wait "$CMDY_PID" 2>/dev/null || true
CMDY_PID=""

echo "Ghostty: large/maximized $BENCH_BYTES-byte $WORKLOAD DSR drain x5"
ghostty_pids() {
  pgrep -x ghostty 2>/dev/null || true
}
BEFORE=" $(ghostty_pids | tr '\n' ' ') "
open -na "$GHOSTTY_APP" --args \
  --title=CMDY_COMPETITIVE_BENCH \
  --window-width=220 --window-height=70 \
  --font-size=15 --font-family='Departure Mono' \
  --adjust-cell-width=15% --adjust-cell-height=-12% \
  --shell-integration=none --background-opacity=1 \
  --window-save-state=never --confirm-close-surface=false \
  --quit-after-last-window-closed=true \
  "--env=CMDY_BENCH_DIR=$RUN" \
  "--env=CMDY_BENCH_PAYLOAD=$RUN/payload.txt" \
  "--command=direct:$RUN/drain.sh"
for _ in $(seq 1 100); do
  for pid in $(ghostty_pids); do
    case "$BEFORE" in *" $pid "*) ;; *) GHOSTTY_PID=$pid ;; esac
  done
  [ -n "$GHOSTTY_PID" ] && break
  sleep 0.1
done
[ -n "$GHOSTTY_PID" ] || { echo "Ghostty benchmark instance did not launch"; exit 1; }
for _ in $(seq 1 600); do
  [ -f "$RUN/ghostty.ok" ] && break
  sleep 0.1
done
[ -f "$RUN/ghostty.ok" ] || { echo "Ghostty benchmark timed out or DSR failed"; exit 1; }

median() {
  sort -n "$1" \
    | awk 'NR == 3 { printf "%.3f", $1 }'
}

CMDY_MEDIAN=$(median "$RUN/cmdy.time")
GHOSTTY_MEDIAN=$(median "$RUN/ghostty.time")
printf '\n%-10s grid %s  median %ss\n' "Cmdy" "$(cat "$RUN/cmdy.grid")" "$CMDY_MEDIAN"
printf '%-10s grid %s  median %ss\n' "Ghostty" "$(cat "$RUN/ghostty.grid")" "$GHOSTTY_MEDIAN"
python3 - "$CMDY_MEDIAN" "$GHOSTTY_MEDIAN" <<'PY'
import sys
cmdy, ghostty = map(float, sys.argv[1:])
print(f"Cmdy/Ghostty drain-time ratio: {cmdy / ghostty:.2f}x (lower is better)")
PY
