#!/bin/bash
# The perf gate: launches an ISOLATED cmdy (CMDY_CONFIG_DIR sandbox —
# your live cmdy is untouched), drives it over its own plugin API, and
# asserts frame budgets. "Fastest terminal" as numbers, not vibes.
#
# The gate window is never key, so this measures the FLEET profile — the
# background terminals you keep dozens of: idle must be ZERO frames, output
# must coalesce, animated shaders must ride the 20fps background throttle.
# (Focused-profile paces — 60fps shader — need a key window; check
# those by hand, the gate can't steal your focus.)
#
#   Tests/perf-gate.sh                              # small fleet window
#   CMDY_PERF_MAXIMIZED=1 Tests/perf-gate.sh    # full visible screen
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${CMDY_BIN:-$ROOT/.build/release/cmdy}"
GATE="$(mktemp -d /tmp/cmdy-perf-gate.XXXXXX)"
DEFAULTS_DOMAIN="com.cmdy.perf.$(basename "$GATE")"
PASS=0; FAIL=0

cleanup() {
  [ -n "${APP_PID:-}" ] && kill -TERM "$APP_PID" 2>/dev/null
  sleep 0.5
  /usr/bin/defaults delete "$DEFAULTS_DOMAIN" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$DEFAULTS_DOMAIN.plist"
  rm -rf "$GATE"
}
trap cleanup EXIT

cat > "$GATE/config" <<CFG
restore-session = false
sounds = false
ghost-text = false
shader = None
clean-prompt = true
CFG

APP_ARGS=()
if [ "${CMDY_PERF_MAXIMIZED:-0}" = "1" ]; then
  APP_ARGS+=(--ui-test-maximized-perf)
fi
if [ "${#APP_ARGS[@]}" -gt 0 ]; then
  CMDY_DEFAULTS_DOMAIN="$DEFAULTS_DOMAIN" CMDY_CONFIG_DIR="$GATE" \
    "$BIN" "${APP_ARGS[@]}" &
else
  # Bash 3.2 + `set -u` treats expansion of an empty array as unbound.
  CMDY_DEFAULTS_DOMAIN="$DEFAULTS_DOMAIN" CMDY_CONFIG_DIR="$GATE" \
    "$BIN" &
fi
APP_PID=$!

for i in $(seq 1 40); do [ -f "$GATE/plugin-api.json" ] && break; sleep 0.25; done
[ -f "$GATE/plugin-api.json" ] || { echo "✗ gate cmdy never came up"; exit 1; }
PORT=$(python3 -c "import json;print(json.load(open('$GATE/plugin-api.json'))['port'])")
TOKEN=$(python3 -c "import json;print(json.load(open('$GATE/plugin-api.json'))['token'])")
api()    { /usr/bin/curl -s -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT$1"; }
post()   { /usr/bin/curl -s -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -X POST "http://127.0.0.1:$PORT$1" -d "$2" >/dev/null; }
post_json() { /usr/bin/curl -s -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -X POST "http://127.0.0.1:$PORT$1" -d "$2"; }
frames() { api /v1/debug/framestats | python3 -c "import json,sys;print(json.load(sys.stdin).get('frames',-1))"; }
PANE=$(api /v1/panes | python3 -c "import json,sys;print(json.load(sys.stdin)['panes'][0]['id'])")
rowstat() { api /v1/debug/framestats | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('rowsRebuilt',0), d.get('rowsReused',0))"; }
rows_rebuilt() { rowstat | cut -d' ' -f1; }
frame_row_state() {
  api /v1/debug/framestats | python3 -c \
    "import json,sys;d=json.load(sys.stdin);print(d.get('frames',-1),d.get('rowsRebuilt',-1),int(bool(d.get('visible'))),int(bool(d.get('key'))))"
}
window_state() {
  api /v1/debug/framestats | python3 -c \
    "import json,sys;d=json.load(sys.stdin);print('%d:%d' % (bool(d.get('visible')),bool(d.get('key'))))"
}
run_cmd() { post "/v1/panes/$PANE/run" "{\"command\": $(python3 -c "import json,sys;print(json.dumps(sys.argv[1]))" "$1")}"; }
run_cmd_for() { post "/v1/panes/$1/run" "{\"command\": $(python3 -c "import json,sys;print(json.dumps(sys.argv[1]))" "$2")}"; }
scroll_by() { post "/v1/panes/$PANE/scroll" "{\"lines\":$1}"; }
scroll_position() {
  /usr/bin/curl -s -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -X POST "http://127.0.0.1:$PORT/v1/panes/$PANE/scroll" -d '{"lines":0}' \
    | python3 -c "import json,sys;print(json.load(sys.stdin)['state']['yDisp'])"
}
wait_scroll_stable() {
  local prev cur hits=0
  prev=$(scroll_position)
  for _ in $(seq 1 30); do
    sleep 0.1
    cur=$(scroll_position)
    if [ "$cur" -eq "$prev" ]; then
      hits=$((hits + 1)); [ "$hits" -ge 3 ] && { echo "$cur"; return 0; }
    else
      hits=0
    fi
    prev=$cur
  done
  echo "$prev"
}

# API command submission is asynchronous. Wait for an output marker that cannot
# appear in the echoed command, then for at least one resulting frame and a
# stable row-build counter. This keeps one phase's deferred work out of the
# next phase's measurement.
wait_output_marker() {
  local marker="$1"
  for _ in $(seq 1 100); do
    api "/v1/panes/$PANE/output" | /usr/bin/grep -q "$marker" && return 0
    sleep 0.1
  done
  return 1
}

wait_frame_after() {
  local baseline="$1" cur
  for _ in $(seq 1 50); do
    cur=$(frames)
    [ "$cur" -gt "$baseline" ] && return 0
    sleep 0.1
  done
  return 1
}

wait_rows_quiet() {
  local prev cur hits=0
  prev=$(rows_rebuilt)
  for _ in $(seq 1 50); do
    sleep 0.1
    cur=$(rows_rebuilt)
    if [ "$cur" -eq "$prev" ]; then
      hits=$((hits + 1)); [ "$hits" -ge 5 ] && return 0
    else
      hits=0
    fi
    prev=$cur
  done
  return 1
}

require_render_after() {
  local baseline="$1" phase="$2"
  wait_frame_after "$baseline" || {
    echo "✗ $phase produced no rendered frame"
    exit 1
  }
  wait_rows_quiet || {
    echo "✗ renderer did not quiesce after $phase"
    exit 1
  }
}

# A key/visibility transition legitimately invalidates the full GPU row cache
# (windowDidBecomeKey reapplies appearance). Never attribute that desktop event
# to the terminal action bracketed by a row/frame budget.
MEASUREMENT_STATE=""
begin_measurement() {
  local phase="$1"
  MEASUREMENT_STATE=$(window_state)
  case "$MEASUREMENT_STATE" in
    1:*) ;;
    *) echo "✗ gate window is not visible before $phase; measurement invalid"; exit 1 ;;
  esac
}

finish_measurement() {
  local phase="$1" after
  after=$(window_state)
  if [ "$after" != "$MEASUREMENT_STATE" ]; then
    echo "✗ gate window state changed during $phase ($MEASUREMENT_STATE -> $after); measurement invalid"
    exit 1
  fi
}

check() { # name actual op budget
  local name="$1" actual="$2" op="$3" budget="$4"
  if [ "$op" = "<=" ] && [ "$actual" -le "$budget" ] || { [ "$op" = ">=" ] && [ "$actual" -ge "$budget" ]; }; then
    printf "  ✓ %-34s %6s  (budget %s %s)\n" "$name" "$actual" "$op" "$budget"; PASS=$((PASS+1))
  else
    printf "  ✗ %-34s %6s  (budget %s %s)\n" "$name" "$actual" "$op" "$budget"; FAIL=$((FAIL+1))
  fi
}

echo "cmdy perf gate — pid $APP_PID, port $PORT"
sleep 3   # boot settle

# Block until rendering has actually quiesced (frames stop climbing) instead of
# a fixed sleep — the cursor blink can take ~12s to settle and the window's key
# state is unpredictable headless, which made fixed sleeps flake.
wait_settled() {
  # Require four continuous seconds with no new frame, rebuilt row, or window
  # state transition. Coarse 2s deltas could sample two quiet troughs around a
  # delayed activation/cursor-animation burst and return too early.
  local sample prev cur prev_f prev_r prev_v prev_k cur_f cur_r cur_v cur_k hits=0
  prev=$(frame_row_state) || return 1
  read prev_f prev_r prev_v prev_k <<< "$prev"
  for _ in $(seq 1 300); do         # up to ~60s
    sleep 0.2
    cur=$(frame_row_state) || { hits=0; continue; }
    read cur_f cur_r cur_v cur_k <<< "$cur"
    if [ "$cur_f" -eq "$prev_f" ] && [ "$cur_r" -eq "$prev_r" ] \
       && [ "$cur_v" -eq "$prev_v" ] && [ "$cur_k" -eq "$prev_k" ]; then
      hits=$((hits + 1)); [ "$hits" -ge 20 ] && return 0
    else
      hits=0
    fi
    prev_f=$cur_f; prev_r=$cur_r; prev_v=$cur_v; prev_k=$cur_k
  done
  return 1
}

# 1 · idle: once rendering quiesces, an idle terminal renders NOTHING.
wait_settled || { echo "✗ renderer did not settle before idle measurement"; exit 1; }
begin_measurement "idle measurement"
F0=$(frames); sleep 6; F1=$(frames)
finish_measurement "idle measurement"
check "idle frames / 6s (settled)" $((F1 - F0)) "<=" 2

# 2 · output coalescing: 200 lines must not mean 200 frames. Since the
# scroll-cache refactor (yDisp as a draw shift, not a cache key) each scrolled
# frame rebuilds ~2 rows not the whole screen, so frames are cheap enough that
# the renderer keeps up frame-by-frame (smoother) — a few more frames than
# before, still far below one-per-line. Budget widened 80→120 to match.
begin_measurement "200-line burst"
R0=$(rows_rebuilt)
F0=$(frames)
BURST_MARKER="__CMDY_PERF_BURST_READY__"
run_cmd "seq 1 200; printf '\n__CMDY_%s_%s__\n' PERF BURST_READY"
wait_output_marker "$BURST_MARKER" || { echo "✗ 200-line burst never completed"; exit 1; }
require_render_after "$F0" "200-line burst"
F1=$(frames)
R1=$(rows_rebuilt)
finish_measurement "200-line burst"
check "frames for 200-line burst" $((F1 - F0)) "<=" 120
# 2a · the scroll-cache win: a 200-line scroll must rebuild a few dozen rows,
# NOT a full screen per frame. Pre-refactor this wiped the row cache on every
# scrolled line (~visible-rows × frames = thousands); now it's ~60. A blown
# budget here means yDisp crept back into the cache signature.
check "rows rebuilt for 200-line scroll" $((R1 - R0)) "<=" 500

# 2b · dirty-row rendering: typing ONE line must rebuild few rows, not the
# whole screen. rowsRebuilt/(rebuilt+reused) is the dirty-row win, measured
# in the release build via framestats.
# TYPE (no newline → no scroll) so we measure a true single-line change,
# not viewport motion, which should reuse retained rows and build only the newly
# exposed edge rows.
type_txt() { post "/v1/panes/$PANE/type" "{\"text\": $(python3 -c "import json,sys;print(json.dumps(sys.argv[1]))" "$1")}"; }
wait_settled || { echo "✗ renderer did not settle before prompt-edit measurement"; exit 1; }
begin_measurement "prompt edit"
read RB0 RU0 < <(rowstat)
F0=$(frames)
type_txt "xyz"
require_render_after "$F0" "prompt edit"
read RB1 RU1 < <(rowstat)
finish_measurement "prompt edit"
REBUILT=$((RB1 - RB0)); REUSED=$((RU1 - RU0))
# echoing 3 chars onto the prompt line touches only that line (plus the
# blinking cursor row); a tall window's other rows must all come from cache.
check "rows rebuilt for prompt edit" "$REBUILT" "<=" 8
check "rows reused ≥ rebuilt (cache wins)" "$REUSED" ">=" "$REBUILT"
# clear what we typed so the later prompt is clean
type_txt ""
post "/v1/panes/$PANE/run" "{\"command\": \"\"}"

# 2c · interactive prompt redraws must not rebuild the whole screen. The shell
# toggles bracketed-paste (CSI ?2004h/l) and erases-below (CSI 0J) around EVERY
# prompt; a blanket markAllDirty on those made holding Return crawl at ~12fps on
# a big window. These change no visible cell (or only below the cursor), so 20
# rounds must rebuild ~nothing, not 20 screenfuls. Regressed = markAllDirty
# crept back onto a benign mode toggle / partial erase.
PROMPT_READY_MARKER="__CMDY_PERF_PROMPT_READY__"
F0=$(frames)
run_cmd "seq 1 200; printf '\n__CMDY_%s_%s__\n' PERF PROMPT_READY"
wait_output_marker "$PROMPT_READY_MARKER" || { echo "✗ prompt-redraw setup never completed"; exit 1; }
require_render_after "$F0" "prompt-redraw setup"
begin_measurement "synthetic prompt redraws"
read RB0 _ < <(rowstat)
F0=$(frames)
post "/v1/panes/$PANE/feed" "{\"text\": $(python3 -c 'import json;print(json.dumps("\x1b[?2004h\x1b[?2004l\x1b[0J"*20))')}"
require_render_after "$F0" "synthetic prompt redraws"
read RB1 _ < <(rowstat)
finish_measurement "synthetic prompt redraws"
check "rows rebuilt for 20 prompt redraws" $((RB1 - RB0)) "<=" 80

# 2d · actual Return-repeat path: raw CR bytes through the PTY must produce one
# clean one-line prompt apiece at an OS-like repeat pace. This catches both main-
# queue starvation and permanent blank gaps that synthetic display feeds miss.
RETURN_STEPS=20
begin_measurement "Return-repeat measurement"
Y0=$(wait_scroll_stable)
wait_rows_quiet || { echo "✗ renderer did not quiesce before Return-repeat measurement"; exit 1; }
read RB0 _ < <(rowstat)
F0=$(frames)
for _ in $(seq 1 "$RETURN_STEPS"); do type_txt $'\r'; sleep 0.03; done
Y1=$(wait_scroll_stable)
require_render_after "$F0" "Return-repeat measurement"
read RB1 _ < <(rowstat)
finish_measurement "Return-repeat measurement"
check "rows advanced for $RETURN_STEPS Returns (min)" $((Y1 - Y0)) ">=" "$RETURN_STEPS"
check "rows advanced for $RETURN_STEPS Returns (max)" $((Y1 - Y0)) "<=" "$RETURN_STEPS"
check "rows rebuilt for $RETURN_STEPS Returns" $((RB1 - RB0)) "<=" $((RETURN_STEPS * 10))

# 2e · repeated one-line viewport moves must retain the cached rows. The old
# forceRedraw path marked the whole viewport dirty on every wheel delta, making
# cost scale as steps × visible rows (and making a maximized window worst). Pace
# requests across display ticks so coalescing cannot hide that regression.
SCROLL_STEPS=20
SCROLL_ROW_BUDGET=$((SCROLL_STEPS * 3))
begin_measurement "one-line scroll-ups"
read RB0 _ < <(rowstat)
for _ in $(seq 1 "$SCROLL_STEPS"); do scroll_by -1; sleep 0.03; done
sleep 0.5
read RB1 _ < <(rowstat)
finish_measurement "one-line scroll-ups"
check "rows rebuilt for $SCROLL_STEPS one-line scroll-ups" $((RB1 - RB0)) "<=" "$SCROLL_ROW_BUDGET"

begin_measurement "one-line scroll-downs"
read RB0 _ < <(rowstat)
for _ in $(seq 1 "$SCROLL_STEPS"); do scroll_by 1; sleep 0.03; done
sleep 0.5
read RB1 _ < <(rowstat)
finish_measurement "one-line scroll-downs"
check "rows rebuilt for $SCROLL_STEPS one-line scroll-downs" $((RB1 - RB0)) "<=" "$SCROLL_ROW_BUDGET"

# 3 · re-settle after activity.
wait_settled || { echo "✗ renderer did not re-settle after activity"; exit 1; }
begin_measurement "re-settled idle measurement"
F0=$(frames); sleep 5; F1=$(frames)
finish_measurement "re-settled idle measurement"
check "idle frames / 5s (re-settled)" $((F1 - F0)) "<=" 2

# 4 · throughput: 3 MB through the whole PTY→VT→GPU path. The marker
# is assembled by printf so the shell's echoed command cannot contain the
# completed token and make this gate pass before the parser reaches the tail.
DRAIN_MARKER="__CMDY_DRAIN_DONE__"
T0=$(python3 -c "import time;print(time.time())")
run_cmd "base64 </dev/urandom | head -c 3000000; printf '\n__CMDY_%s_%s__\n' DRAIN DONE"
for i in $(seq 1 100); do
  OUT=$(api "/v1/panes/$PANE/output" | /usr/bin/grep -c "$DRAIN_MARKER" || true)
  [ "$OUT" -ge 1 ] && break; sleep 0.2
done
T1=$(python3 -c "import time;print(time.time())")
MS=$(python3 -c "print(int((${T1}-${T0})*1000))")
# Parse-bound (VT byte processing dominates); budget stays generous to avoid
# load-variance flakes across debug machines and CI hosts.
check "3MB dump wall-time (ms)" "$MS" "<=" 6000

# 5 · static shader: Scanlines idles at zero too. (Atomic replace — the
# config watcher fires on editor-style saves, not in-place appends.)
setcfg() { python3 - "$GATE/config" "$1" <<'PY'
import sys, re, os
p, shader = sys.argv[1], sys.argv[2]
s = open(p).read()
s = re.sub(r"shader = \w+", "shader = " + shader, s)
tmp = p + ".tmp"
open(tmp, "w").write(s)
os.replace(tmp, p)
PY
}
setcfg Scanlines
sleep 2
wait_settled || { echo "✗ static shader did not settle"; exit 1; }
begin_measurement "static-shader idle measurement"
F0=$(frames); sleep 6; F1=$(frames)
finish_measurement "static-shader idle measurement"
check "static-shader idle / 6s" $((F1 - F0)) "<=" 2

# 6 · animated shader. Occluded windows render NOTHING by design, so the
# 10fps background band only applies when the gate window is actually
# visible on this desktop — otherwise assert the occluded contract (0).
setcfg Plasma
sleep 3
ST=$(api /v1/debug/framestats)
VIS=$(echo "$ST" | python3 -c "import json,sys;print(1 if json.load(sys.stdin).get('visible') else 0)")
KEY=$(echo "$ST" | python3 -c "import json,sys;print(1 if json.load(sys.stdin).get('key') else 0)")
F0=$(frames); sleep 5; F1=$(frames)
D=$((F1 - F0))
if [ "$VIS" != "1" ]; then
  check "plasma occluded frames / 5s" "$D" "<=" 2
  echo "  · (window occluded — animation correctly stopped)"
elif [ "$KEY" = "1" ]; then
  # focused: the renderer's tested 60fps target (allow scheduler slack)
  check "plasma focused frames / 5s (≥ 40fps)" "$D" ">=" 200
  check "plasma focused frames / 5s (≤ 70fps)" "$D" "<=" 350
else
  # visible but not key: the 20fps background throttle
  check "plasma bg frames / 5s (≥ ticking)" "$D" ">=" 25
  check "plasma bg frames / 5s (≤ 20fps+)" "$D" "<=" 120
fi

# 7 · multi-pane isolation: split the maximized window and drain two PTYs at
# once. Per-pane model queues should parse concurrently while AppKit remains
# responsive enough for both output endpoints to observe their tail marker.
setcfg None
SPLIT=$(post_json "/v1/panes/$PANE/split" '{"direction":"right"}')
PANE2=$(echo "$SPLIT" | python3 -c "import json,sys;print(json.load(sys.stdin).get('pane',''))")
for _ in $(seq 1 40); do
  READY=$(api /v1/panes | python3 -c "import json,sys;print(sum(1 for p in json.load(sys.stdin)['panes'] if p.get('pid',0) > 0))")
  [ "$READY" -ge 2 ] && break
  sleep 0.1
done
T0=$(python3 -c "import time;print(time.time())")
run_cmd_for "$PANE"  "base64 </dev/urandom | head -c 1000000; printf '\n__CMDY_MULTI_%s__\n' LEFT"
run_cmd_for "$PANE2" "base64 </dev/urandom | head -c 1000000; printf '\n__CMDY_MULTI_%s__\n' RIGHT"
LEFT=0; RIGHT=0
for _ in $(seq 1 100); do
  LEFT=$(api "/v1/panes/$PANE/output" | /usr/bin/grep -c "__CMDY_MULTI_LEFT__" || true)
  RIGHT=$(api "/v1/panes/$PANE2/output" | /usr/bin/grep -c "__CMDY_MULTI_RIGHT__" || true)
  [ "$LEFT" -ge 1 ] && [ "$RIGHT" -ge 1 ] && break
  sleep 0.1
done
T1=$(python3 -c "import time;print(time.time())")
MULTI_MS=$(python3 -c "print(int((${T1}-${T0})*1000))")
check "two-pane concurrent drain markers" $((LEFT + RIGHT)) ">=" 2
check "two-pane concurrent 2MB (ms)" "$MULTI_MS" "<=" 6000

echo
echo "passed $PASS · failed $FAIL"
[ "$FAIL" -eq 0 ]
