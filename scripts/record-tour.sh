#!/usr/bin/env bash
# A deterministic, recordable tour of cmdy's terminal, GPU renderer,
# blocks, splits, Surface Protocol, SDK panels, and Extension system.
#
# Run this from Terminal.app while the cmdy window you want to record is
# focused. The script drives cmdy through its local authenticated API.
#
#   scripts/record-tour.sh --list
#   PACE=1.2 scripts/record-tour.sh
#   CHAPTERS=terminal,surfaces,platform scripts/record-tour.sh <pane-id>
#
# Optional companion-app chapter (Browser/Sim/Bridge) is deliberately opt-in:
#   SIDECARS=1 scripts/record-tour.sh
set -euo pipefail

PACE="${PACE:-1.0}"
CHAPTERS="${CHAPTERS:-intro,terminal,blocks,splits,surfaces,platform,appearance,finale}"
SIDECARS="${SIDECARS:-0}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/product-identity.sh"

usage() {
  cat <<'EOF'
usage: record-tour.sh [--list] [pane-id]

environment:
  PACE=1.2                 timing multiplier (larger is slower)
  CHAPTERS=a,b,c           intro terminal blocks splits surfaces platform appearance finale
  SIDECARS=1               include installed Browser/Sim/Bridge launch commands
  PRODUCT_BIN=/path        Product CLI used for Surface and Extension commands
EOF
}

CONFIG_CANDIDATES=()
config_override="$(product_env_value CONFIG_DIR)"
[[ -n "$config_override" ]] && CONFIG_CANDIDATES+=("$config_override")
CONFIG_CANDIDATES+=("$HOME/.config/$PRODUCT_CONFIG_DIR_NAME")
for legacy in "${PRODUCT_LEGACY_SLUGS[@]}"; do
  CONFIG_CANDIDATES+=("$HOME/.config/$legacy")
done
for dir in "${CONFIG_CANDIDATES[@]}"; do
  if [[ -f "$dir/plugin-api.json" ]]; then
    DISCOVERY="$dir/plugin-api.json"
    CONFIG_DIR="$dir"
    break
  fi
done
if [[ -n "$(product_env_value PORT)" && -n "$(product_env_value TOKEN)" ]]; then
  PORT="$(product_env_value PORT)"
  TOKEN="$(product_env_value TOKEN)"
elif [[ -n "${DISCOVERY:-}" ]]; then
  read -r PORT TOKEN < <(python3 - "$DISCOVERY" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(d["port"], d["token"])
PY
  )
else
  echo "$PRODUCT_TITLE_NAME is not running (plugin-api.json was not found)." >&2
  exit 1
fi

BASE="http://127.0.0.1:$PORT"
AUTH="Authorization: Bearer $TOKEN"
CONFIG="${CONFIG_DIR:-$HOME/.config/$PRODUCT_CONFIG_DIR_NAME}/config"

PRODUCT_BIN="$(product_env_value BIN)"
if [[ -z "$PRODUCT_BIN" ]]; then
  for candidate in \
    "$ROOT/$PRODUCT_APP_BUNDLE/Contents/MacOS/$PRODUCT_EXECUTABLE" \
    "$ROOT/.build/release/$PRODUCT_EXECUTABLE" \
    "/Applications/$PRODUCT_APP_BUNDLE/Contents/MacOS/$PRODUCT_EXECUTABLE"; do
    if [[ -x "$candidate" ]]; then PRODUCT_BIN="$candidate"; break; fi
  done
fi
PRODUCT_BIN="${PRODUCT_BIN:-$(command -v "$PRODUCT_EXECUTABLE" 2>/dev/null || true)}"

api_get() { curl -fsS -H "$AUTH" "$BASE$1"; }
api_post() {
  curl -fsS -H "$AUTH" -H 'Content-Type: application/json' \
    -X POST "$BASE$1" -d "$2" >/dev/null
}
json_string() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}
shell_quote() {
  python3 -c 'import sys; print("\x27" + sys.argv[1].replace("\x27", "\x27\\\x27\x27") + "\x27")' "$1"
}
pause() {
  python3 -c 'import sys,time; time.sleep(float(sys.argv[1])*float(sys.argv[2]))' "$1" "$PACE"
}
has_chapter() { [[ ",${CHAPTERS}," == *",$1,"* ]]; }

panes_json() { api_get /v1/panes; }
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then usage; exit 0; fi
if [[ "${1:-}" == "--list" ]]; then
  panes_json | python3 -c 'import json,sys
for p in json.load(sys.stdin)["panes"]:
 print(p["id"], "focused" if p.get("focused") else "", p.get("title", ""))'
  exit 0
fi
PANE="${1:-$(panes_json | python3 -c 'import json,sys
p=json.load(sys.stdin)["panes"]; f=[x for x in p if x.get("focused")]; print((f or p)[0]["id"] if p else "")')}"
[[ -n "$PANE" ]] || { echo "No $PRODUCT_TITLE_NAME pane is open." >&2; exit 1; }

run_in() { api_post "/v1/panes/$1/run" "{\"command\":$(json_string "$2")}"; }
run() { run_in "$PANE" "$1"; }
type_in() { api_post "/v1/panes/$1/type" "{\"text\":$(json_string "$2")}"; }
focus_in() { api_post "/v1/panes/$1/focus" '{}'; }
feed_in() { api_post "/v1/panes/$1/feed" "{\"text\":$(json_string "$2")}"; }
close_in() { api_post "/v1/panes/$1/close" '{}'; }
split_in() {
  curl -fsS -H "$AUTH" -H 'Content-Type: application/json' -X POST \
    "$BASE/v1/panes/$1/split" -d "{\"direction\":\"$2\"}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("pane", ""))'
}
caption() { run "cmdy_chapter $(shell_quote "$1")"; pause 0.8; }
success() { run "cmdy_success $(shell_quote "$1")"; }

CONFIG_BACKUP=""
PROMPT_SAVED=0
HELPERS_INSTALLED=0
if [[ -f "$CONFIG" ]]; then
  CONFIG_BACKUP="$(mktemp -t cmdy-record-config.XXXXXX)"
  cp "$CONFIG" "$CONFIG_BACKUP"
fi
set_config() {
  [[ -f "$CONFIG" ]] || return 0
  python3 - "$CONFIG" "$1" "$2" <<'PY'
import re, sys
path, key, value = sys.argv[1:]
text = open(path).read()
line = f"{key} = {value}"
pattern = re.compile(rf"(?m)^{re.escape(key)}\s*=.*$")
text = pattern.sub(line, text) if pattern.search(text) else text.rstrip()+"\n"+line+"\n"
open(path, "w").write(text)
PY
}
cleanup() {
  if [[ "$HELPERS_INSTALLED" == 1 ]]; then
    run cmdy_finish || true
    HELPERS_INSTALLED=0
    PROMPT_SAVED=0
  elif [[ "$PROMPT_SAVED" == 1 ]]; then
    run 'PROMPT="$__cmdy_tour_prompt"; unset __cmdy_tour_prompt' || true
    PROMPT_SAVED=0
  fi
  if [[ -n "$CONFIG_BACKUP" && -f "$CONFIG_BACKUP" ]]; then
    cp "$CONFIG_BACKUP" "$CONFIG"
    rm -f "$CONFIG_BACKUP"
  fi
}
trap cleanup EXIT INT TERM

echo "Driving pane $PANE at PACE=$PACE"
echo "Chapters: $CHAPTERS"
run '__cmdy_tour_prompt="$PROMPT"'
PROMPT_SAVED=1
run "PROMPT='%F{108}%1~%f %F{244}›%f '"
run "cmdy_chapter() { printf '\\033[38;5;180m%s\\033[0m\\n' \"\$*\"; }; cmdy_success() { printf '\\033[38;5;114m%s\\033[0m\\n' \"\$*\"; }; cmdy_finish() { PROMPT=\"\$__cmdy_tour_prompt\"; unset __cmdy_tour_prompt; unfunction cmdy_chapter cmdy_success cmdy_finish; }"
HELPERS_INSTALLED=1
# One failed command is part of the Blocks chapter. Keep its red block, but do
# not let the automatic error explainer turn a visual tour into a wall of text.
set_config automatic-error-help false
run clear
pause 0.5

if has_chapter intro; then
  caption "$PRODUCT_ENV_PREFIX / a dedicated VT engine and native Metal renderer"
  run "printf 'Core      VT engine\\nRenderer  Metal pipeline\\nKit       Extension and Surface SDK\\nlib_cmdy  embeddable C ABI\\n'"
  pause 2.2
  run "git -C $(printf %q "$ROOT") log --oneline -5"
  pause 1.8
fi

if has_chapter terminal; then
  run clear
  caption "A fast, standards-first terminal"
  run 'for i in $(seq 16 231); do printf "\033[48;5;%dm  \033[0m" "$i"; [ $(((i-15)%36)) -eq 0 ] && echo; done'
  pause 1.2
  run 'printf "\ntruecolor  "; for i in $(seq 0 60); do printf "\033[48;2;%d;%d;%dm \033[0m" $((i*4)) $((80+i*2)) $((255-i*4)); done; echo'
  pause 1.2
  run 'printf "bold \033[1mABC\033[0m   italic \033[3mABC\033[0m   underline \033[4mABC\033[0m   λ ∑ π ∞  →  ✓\n"'
  pause 1.4
  run 'seq 1 2500 | awk '\''{printf "\033[38;5;%dmrow %04d  render cache + scrollback\033[0m\n", 16+($1%200), $1}'\'''
  pause 1.8
fi

if has_chapter blocks; then
  run clear
  caption "Commands become useful blocks without replacing stdout"
  run "printf 'lint     '; sleep .25; printf '\\033[32mpassed\\033[0m\\n'; printf 'tests    '; sleep .25; printf '\\033[32m28 passed\\033[0m\\n'"
  pause 1.3
  run "printf 'compile  '; sleep .3; printf '\\033[31mfailed: missing symbol\\033[0m\\n'; false"
  pause 2.0
fi

if has_chapter splits; then
  run clear
  caption "Every pane is independently controllable"
  RIGHT="$(split_in "$PANE" right)"
  DOWN=""
  if [[ -n "$RIGHT" ]]; then
    run_in "$RIGHT" "git -C $(printf %q "$ROOT") status --short"
    DOWN="$(split_in "$RIGHT" down)"
  fi
  if [[ -n "$DOWN" ]]; then
    run_in "$DOWN" 'while :; do color=$((80+RANDOM%120)); now=$(date +%H:%M:%S); printf "\033[38;5;%dmagent event  %s\033[0m\n" "$color" "$now"; sleep .18; done'
    pause 2.2
    feed_in "$RIGHT" $'\033]9;review ready\a'
    pause 1.2
    type_in "$DOWN" $'\003'
    close_in "$DOWN"
  fi
  [[ -n "$RIGHT" ]] && close_in "$RIGHT"
  focus_in "$PANE"
  pause 0.8
fi

if has_chapter surfaces; then
  run clear
  caption "stdout can optionally grow a native live Surface"
  if [[ -n "$PRODUCT_BIN" && -x "$PRODUCT_BIN" ]]; then
    Q_BIN="$(printf %q "$PRODUCT_BIN")"
    run "printf '%s\\n' '{\"name\":\"renderer\",\"state\":\"ready\",\"latency\":1.8}' '{\"name\":\"extensions\",\"state\":\"ready\",\"latency\":0.7}' '{\"name\":\"surfaces\",\"state\":\"live\",\"latency\":0.4}' | $Q_BIN surface table --id tour-table --title 'Runtime'"
    pause 2.5
    run "printf '%s\\n' '{\"label\":\"Parse project\",\"status\":\"complete\",\"progress\":1}' '{\"label\":\"Run tests\",\"status\":\"running\",\"progress\":0.72}' '{\"label\":\"Review\",\"status\":\"pending\"}' | $Q_BIN surface task --id tour-tasks --title 'Agent plan'"
    pause 2.5
    run "git -C $(printf %q "$ROOT") diff -- README.md | head -80 | $Q_BIN surface diff --id tour-diff --title 'Working tree'"
    pause 2.5
  else
    run "printf '\\033[33m$PRODUCT_TITLE_NAME CLI not found; set PRODUCT_BIN to record native Surfaces.\\033[0m\\n'"
    pause 1.5
  fi
fi

if has_chapter platform; then
  run clear
  caption "The Extension SDK can draw native UI and control panes"
  PANEL_JSON='{"mode":"list","title":"Extension runtime","items":[{"title":"Browser","subtitle":"native companion + MCP"},{"title":"Sim","subtitle":"iOS Simulator + MCP"},{"title":"Bridge","subtitle":"93-tool MCP runtime"}]}'
  PANEL_ID="$(curl -fsS -H "$AUTH" -H 'Content-Type: application/json' -X POST \
    "$BASE/v1/ui/panel" -d "$PANEL_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("panel", ""))')"
  pause 2.8
  [[ -n "$PANEL_ID" ]] && api_post "/v1/ui/$PANEL_ID/dismiss" '{}'
  if [[ -n "$PRODUCT_BIN" && -x "$PRODUCT_BIN" ]]; then
    run "$(printf %q "$PRODUCT_BIN") extension list"
    pause 2.0
  fi
  if [[ "$SIDECARS" == 1 ]]; then
    run "printf 'Companion launch is enabled for this recording.\\nUse the Extensions palette to attach Browser, Sim, or Bridge.\\n'"
    pause 1.8
  fi
fi

if has_chapter appearance; then
  run clear
  caption "Cursor motion and rendering are live GPU settings"
  set_config smooth-cursor true
  set_config cursor-glide-max-distance 0
  set_config cursor-glide-speed 0.45
  type_in "$PANE" "printf 'slow glide'"
  type_in "$PANE" $'\001'
  type_in "$PANE" $'\005'
  pause 1.7
  set_config cursor-glide-speed 2.5
  type_in "$PANE" $'\001'
  type_in "$PANE" $'\005'
  pause 1.2
  type_in "$PANE" $'\025'
  for shader in Glow Scanlines Ripple None; do
    set_config shader "$shader"
    run 'printf "\033[38;5;114mGPU frame %s\033[0m\n" "$(date +%H:%M:%S)"'
    pause 0.65
  done
fi

if has_chapter finale; then
  run clear
  success "$PRODUCT_ENV_PREFIX / terminal first, platform when you need it"
  run "echo 'GPU-native. Fast. Open. Extensible.'"
  pause 2.0
fi

run cmdy_finish
PROMPT_SAVED=0
HELPERS_INSTALLED=0
echo "Tour complete. Stop the recording; configuration has been restored."
