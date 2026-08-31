#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────
# cmdy demo — drive the real terminal through a choreographed sequence
# over the local HTTP API, so you can screen-record it for the site hero.
#
# HOW TO RECORD
#   1. Open cmdy with one clean pane. Size the window how you want it
#      framed (a 16:9-ish shape records well). Optionally hide the cursor
#      blink distraction by just leaving it at the prompt.
#   2. Start a screen recording of the cmdy window  (⌘⇧5 → Record
#      Selected Portion, draw it around the cmdy window).
#   3. From macOS Terminal.app — not from inside cmdy — run:
#          /tmp/cmdy-demo.sh
#      (Running it outside cmdy keeps cmdy's pane focused so the demo
#       plays there while you record it.)
#   4. When it prints "done", stop the recording (⌘⇧5 stops, or the menubar
#      stop button). Trim the ends in QuickTime if you like.
#
# KNOBS
#   PACE=1.4 ~/…/demo.sh     # slower (1.0 default; 0.7 faster)
#   FINALE_ONLY=1 ~/…/demo.sh # record only themes, type and shaders
#   ~/…/demo.sh <paneId>     # target a specific pane (see: demo.sh --list)
#   ~/…/demo.sh --list       # print panes and exit
# ─────────────────────────────────────────────────────────────────────────
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/product-identity.sh"
ln -sfn "$ROOT/scripts/demo-pane.sh" /tmp/cmdy-zoo

# ── locate the API (cmdy writes this at launch) ────────────────────────
# The canonical directory is ~/.config/cmdy. Previous public names remain in
# the candidate list strictly for migration compatibility.
disc=""; CFGDIR=""
CONFIG_CANDIDATES=()
config_override="$(product_env_value CONFIG_DIR)"
[[ -n "$config_override" ]] && CONFIG_CANDIDATES+=("$config_override")
CONFIG_CANDIDATES+=("$HOME/.config/$PRODUCT_CONFIG_DIR_NAME")
for legacy in "${PRODUCT_LEGACY_SLUGS[@]}"; do
  CONFIG_CANDIDATES+=("$HOME/.config/$legacy")
done
for d in "${CONFIG_CANDIDATES[@]}"; do
  [ -f "$d/plugin-api.json" ] && { disc="$d/plugin-api.json"; CFGDIR="$d"; break; }
done
if [ -n "$(product_env_value PORT)" ] && [ -n "$(product_env_value TOKEN)" ]; then
  PORT="$(product_env_value PORT)"; TOKEN="$(product_env_value TOKEN)"
elif [ -n "$disc" ]; then
  PORT="$(python3 -c "import json;print(json.load(open('$disc'))['port'])")"
  TOKEN="$(python3 -c "import json;print(json.load(open('$disc'))['token'])")"
else
  echo "✗ Can't find $PRODUCT_TITLE_NAME's API — is $PRODUCT_TITLE_NAME running?" >&2
  echo "  (looked for plugin-api.json in current and legacy product config folders)" >&2
  exit 1
fi
BASE="http://127.0.0.1:$PORT"
AUTH="Authorization: Bearer $TOKEN"

# ── config file (for the live shader/theme restyle) ──────────────────────
# Must be the SAME dir the API came from, else shader writes go to a file
# cmdy isn't watching (the exact bug that made shaders "not work").
CFG=""
if [ -n "$CFGDIR" ] && [ -f "$CFGDIR/config" ]; then
  CFG="$CFGDIR/config"
else
  for d in "${CONFIG_CANDIDATES[@]}"; do
    f="$d/config"
    [ -f "$f" ] && { CFG="$f"; break; }
  done
fi

PACE="${PACE:-1.0}"
FINALE_ONLY="${FINALE_ONLY:-0}"
beat() { python3 -c "import time,sys;time.sleep(float(sys.argv[1])*$PACE)" "$1"; }
json() { python3 -c "import json,sys;print(json.dumps(sys.argv[1]))" "$1"; }
post() { curl -s -H "$AUTH" -H 'Content-Type: application/json' -X POST "$BASE$1" -d "$2" >/dev/null; }

# ── choose the pane to drive ─────────────────────────────────────────────
panes_json() { curl -s -H "$AUTH" "$BASE/v1/panes"; }
if [ "${1:-}" = "--list" ]; then
  panes_json | python3 -c "import json,sys;[print(p['id'], '·', p.get('title','?'), '(focused)' if p.get('focused') else '') for p in json.load(sys.stdin)['panes']]"
  exit 0
fi
if [ -n "${1:-}" ]; then
  PANE="$1"
else
  PANE="$(panes_json | python3 -c "import json,sys;d=json.load(sys.stdin)['panes'];f=[p for p in d if p.get('focused')];print(((f or d)[0]['id']) if d else '')")"
fi
[ -n "$PANE" ] || { echo "✗ No $PRODUCT_TITLE_NAME pane found (open one, then rerun)." >&2; exit 1; }

# ── verbs ────────────────────────────────────────────────────────────────
run()     { post "/v1/panes/$PANE/run" "{\"command\": $(json "$1")}"; }        # main pane
runin()   { post "/v1/panes/$1/run"    "{\"command\": $(json "$2")}"; }        # a specific pane
typ()     { post "/v1/panes/$PANE/type" "{\"text\": $(json "$1")}"; }          # type, no Enter (to quit TUIs)
type_slow() {
  local text="$1" i chunk
  for (( i=0; i<${#text}; i+=3 )); do
    chunk="${text:i:3}"
    typ "$chunk"
    beat 0.025
  done
  typ $'\r'
}
focusin() { post "/v1/panes/$1/focus"  '{}'; }
splitp()  { curl -s -H "$AUTH" -H 'Content-Type: application/json' -X POST \
              "$BASE/v1/panes/$1/split" -d "{\"direction\":\"${2:-right}\"}" \
            | python3 -c "import json,sys;print(json.load(sys.stdin).get('pane',''))"; }
closep()  { post "/v1/panes/$1/close" '{}'; }                                  # close a pane
feedin()  { post "/v1/panes/$1/feed" "{\"text\": $(json "$2")}"; }             # raw bytes → a pane
notify()  { post "/v1/notify" "{\"title\": $(json "$1"), \"body\": $(json "$2")}"; }
PANEL_ID=""
panel()   { PANEL_ID="$(curl -s -H "$AUTH" -H 'Content-Type: application/json' -X POST "$BASE/v1/ui/panel" -d "$1" | python3 -c "import json,sys;print(json.load(sys.stdin).get('panel',''))")"; }
dismiss() { [ -n "$PANEL_ID" ] && post "/v1/ui/$PANEL_ID/dismiss" '{}' || true; }
set_kv() {  # key value — replace the line in the config, or append it
  [ -n "$CFG" ] || return 0
  local k="$1" v="$2"
  # cmdy watches the config directory because editors replace files atomically.
  # Replace it the same way so every gallery step emits a directory event; the
  # holds below exceed cmdy's 0.2-second reload debounce.
  python3 - "$CFG" "$k" "$v" <<'PY'
import os, re, sys, tempfile
path, key, value = sys.argv[1:]
with open(path, encoding="utf-8") as f:
    text = f.read()
line = f"{key} = {value}"
pattern = re.compile(rf"(?m)^{re.escape(key)}\s*=.*$")
text = pattern.sub(line, text) if pattern.search(text) else text.rstrip() + "\n" + line + "\n"
directory = os.path.dirname(path)
fd, temporary = tempfile.mkstemp(prefix=".cmdy-demo-", dir=directory, text=True)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(temporary, path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
}
cap()    { run "cap '${1}'"; }  # amber caption via the shell helper defined at setup (no ' in text)
ok()     { run "ok '${1}'"; }   # green success line

# remember the current look so we can put it back
cfgval() { grep -E "^$1 *=" "${CFG:-/dev/null}" 2>/dev/null | head -1 | sed -E "s/^$1 *= *//" || true; }
ORIG_SHADER="$(cfgval shader)"; ORIG_SHADER="${ORIG_SHADER:-None}"
ORIG_THEME="$(cfgval theme)"
ORIG_FONTSZ="$(cfgval font-size)"
ORIG_FONT="$(cfgval font-family)"
restore() {
  set_kv shader "$ORIG_SHADER"
  [ -n "$ORIG_THEME"  ] && set_kv theme       "$ORIG_THEME"
  [ -n "$ORIG_FONTSZ" ] && set_kv font-size   "$ORIG_FONTSZ"
  [ -n "$ORIG_FONT"   ] && set_kv font-family "$ORIG_FONT"
}
trap restore EXIT

# Window Grid owns the window geometry for the whole tour, including the
# one-window appearance finale. Leave it enabled after the script exits so
# the final recorded frame cannot collapse back to a floating window.
set_kv window-grid true

# Shared by the split sequence and FINALE_ONLY. A standalone finale must have
# moving material available for the shader sweep too.
STREAM='n=0; while :; do n=$((n+1)); case $((n%4)) in 0) printf "\033[38;5;81mrender\033[0m  ▁▂▃▅▇▅▃▂  frame ready  ●\n";; 1) printf "\033[38;5;213magents\033[0m  codex ●  local ◐  review ✓\n";; 2) printf "\033[38;5;118municode\033[0m λ ∑ π ∞  ⣿⣶⣤⣀  → ↑ ↓\n";; 3) printf "\033[38;5;220mblocks\033[0m  ░▒▓█  build ✓  package ✓\n";; esac; sleep .055; done'

echo "▶ driving pane $PANE  (PACE=$PACE)  — record the $PRODUCT_TITLE_NAME window now"

# ═══ 0 · a clean, hostname-free prompt + caption helpers, then wipe setup ═
run "PROMPT='%F{108}cmdy%f ❯ '"
run 'cap(){ printf "\033[38;5;180m▸ %s\033[0m\n" "$1"; }; ok(){ printf "\033[38;5;114m✓ %s\033[0m\n" "$1"; }'
beat 0.4
run "clear"; beat 0.7

# ═══ 1 · a real terminal ═════════════════════════════════════════════════
if [[ "$FINALE_ONLY" != 1 ]]; then
cap "a real terminal — its own VT engine, its own Metal renderer"; beat 1.2
run "/tmp/cmdy-zoo project"; beat 2.4
run "/tmp/cmdy-zoo platform"; beat 2.2

# a pool of quick, colorful commands — a random one per split pane
CMDS=(
  '/tmp/cmdy-zoo project'
  '/tmp/cmdy-zoo blocks'
  'for i in $(seq 16 231); do printf "\033[48;5;%dm \033[0m" $i; done'
  'top -o cpu'
  'ps aux | head -20'
  'printf "▁▂▃▄▅▆▇█\n░▒▓█  λ ∑ π ∞\n😀 🐝 🚀 🔥\n"'
  'echo $PATH | tr ":" "\n"'
  'df -h; echo; uptime'
  'seq 1 240 | paste - - - - - -'
  'cal 2>/dev/null; date'
)
putrandom() {  # paneId — clean prompt + a random command from the pool
  runin "$1" "PROMPT='%F{108}%1~%f ❯ '"; runin "$1" clear
  runin "$1" "${CMDS[$(( RANDOM % ${#CMDS[@]} ))]}"
}

# ═══ 2 · splits multiply — the mosaic grows, vertical and horizontal ═════
cap "split it — again and again, any direction"; beat 1.0
PANES=("$PANE"); i=0
for d in right down right down right; do
  target="${PANES[$(( i % ${#PANES[@]} ))]}"
  new="$(splitp "$target" "$d")"
  [ -z "$new" ] && { cap "(split/close need a fresh build — quit $PRODUCT_TITLE_NAME, ./package.sh, relaunch)"; beat 1.2; break; }
  PANES+=("$new"); putrandom "$new"; i=$(( i + 1 )); beat 0.9
done
beat 0.8

# ═══ 3 · built for agents — panes in the mosaic ring for you ═════════════
cap "any of them can ring when it needs you"; beat 0.9
if [ "${#PANES[@]}" -gt 2 ]; then
  feedin "${PANES[1]}" $'\033]9;tests green\a'
  feedin "${PANES[2]}" $'\033]9;needs review\a'
fi
notify "claude" "tests green — ready for review"; beat 2.4

# ═══ 4 · …then gone, one by one ══════════════════════════════════════════
cap "…and gone, one by one"; beat 0.8
for (( j=${#PANES[@]}-1; j>=1; j-- )); do closep "${PANES[j]}"; beat 0.55; done
focusin "$PANE"; run clear; beat 0.6

# ═══ 5 · the zoo — one window, every kind of program ═════════════════════
cap "runs anything — the zoo, in one window"; beat 1.0
run 'clear; for i in $(seq 0 255); do printf "\033[48;5;%dm  \033[0m" $i; [ $(( (i+1) % 36 )) -eq 0 ] && echo; done; echo'; beat 1.3
run 'clear; printf "true color\n"; for i in $(seq 0 77); do printf "\033[48;2;%d;%d;%dm " $((i*3)) $((90+i*2)) $((255-i*3)); done; printf "\033[0m\n\nbold \033[1mABC\033[0m   italic \033[3mABC\033[0m   underline \033[4mABC\033[0m   reverse \033[7mABC\033[0m\n"'; beat 1.4
run 'clear; printf "blocks   ▁▂▃▄▅▆▇█  ░▒▓█\nbraille  ⣿⣶⣤⣀⠿⠷⠟   arrows  → ↑ ↓ ★ ☂ ✓ ⚡\nsymbols  λ ∑ π ∞ ≈ ⌘   emoji  😀 🐝 🚀 🔥\n"'; beat 1.5
command -v vim >/dev/null 2>&1 && { run "vim -u NONE -R /tmp/cmdy-zoo"; beat 1.7; typ $'\033:q!\r'; beat 0.4; }
run "top -o cpu"; beat 1.8; typ "q"; beat 0.4
for x in htop btop cmatrix; do command -v "$x" >/dev/null 2>&1 && { run "$x"; beat 1.7; typ "q"; beat 0.4; break; }; done
run clear; beat 0.4

# ═══ 6 · extend it — a native panel, drawn over HTTP ═════════════════════
cap "extend it — this panel was drawn over HTTP, one curl call"; beat 1.1
panel '{"mode":"list","title":"deploys","items":[{"title":"api · staging  ✓"},{"title":"web · prod  ✓"},{"title":"worker · staging  …"}]}'
beat 3.0
dismiss; beat 0.5   # ← close the interactive panel so it doesn't hang the demo
fi

# ═══ 7 · visual finale — every shader, scale, type, every theme ═════
run clear
cap "make it yours — every shader, type scale and theme, all live"; beat 0.7
run 'clear; printf "VISUAL SAMPLER\n\n"; printf "spectrum  \033[48;5;196m    \033[48;5;208m      \033[48;5;226m   \033[48;5;46m       \033[48;5;51m     \033[48;5;21m        \033[0m\n"; printf "signal    ▁▂▃▅▇▅▃▂  ░▒▓█  ⣿⣶⣤⣀\n"; printf "runtime   Browser ●  Sim ◐  Swarm ✓  Bridge ↔\n"; printf "glyphs    λ ∑ π ∞  → ↑ ↓  ★  ⚡  ⌘\n"'
beat 0.45

# Every built-in shader, in the renderer's canonical order, over moving text.
# Databloom gets a second, longer beat below because it reacts to scrolling.
SHADERS=(
  CRT Scanlines Glow VHS Dither Neon Plasma Glitch Ripple Copper Starfield
  Matrix Fire Grid Tunnel Rotozoom Wobble Aurora Lava Boot Snow Bubbles Rain
  Tron Radar Maze Waves Plexus Vortex Blocks Lightning Scroller Rasterbars ANSI
  Floor Twister Moire Drift Breath Lagoon Silk Ember Fireflies Clouds Mist Deep
  Tide Zen Lanterns Snowfall Petals Koi Moss Dunes Horizon Rainfall Nebula Comet
  Meadow Ink Marble Prism Halo Waterline Slowscan Voronoi Eclipse Databloom
)
THEMES=(
  C64 Dark Amber Green Light 'W/B' Dracula Nord 'Catppuccin Mocha'
  'Gruvbox Dark' 'Tokyo Night' 'Solarized Dark' 'Solarized Light' Monokai
  'Rosé Pine' 'One Dark' 'B/W'
)
run "$STREAM"; beat 0.45
shader_index=0
theme_index=0
for s in "${SHADERS[@]}"; do
  set_kv shader "$s"
  # Spread the full palette sweep across the shader reel so both dimensions
  # keep changing together instead of becoming two repetitive chapters.
  if (( shader_index % 4 == 0 && theme_index < ${#THEMES[@]} )); then
    set_kv theme "${THEMES[$theme_index]}"
    theme_index=$((theme_index + 1))
  fi
  shader_index=$((shader_index + 1))
  beat 0.18
done
typ $'\003'; beat 0.3
set_kv shader Databloom
run 'for i in {1..88}; do case $((i%4)) in 0) printf "\033[38;5;81m◆ bloom\033[0m  ▁▂▃▅▇  text motion\n";; 1) printf "\033[38;5;213m◇ signal\033[0m  ⣿⣶⣤⣀  λ ∑ π\n";; 2) printf "\033[38;5;118m● glyph\033[0m   ░▒▓█  → ↑ ↓\n";; 3) printf "\033[38;5;220m◐ frame\033[0m   Browser  Sim  Swarm\n";; esac; done'
beat 0.35
# Databloom is driven by viewport motion, not output alone. Build scrollback,
# jump upward, then move it line-by-line through the real pane scroll endpoint.
post "/v1/panes/$PANE/scroll" '{"lines":-40}'
for _ in $(seq 1 26); do
  post "/v1/panes/$PANE/scroll" '{"lines":1}'
  beat 0.035
done
beat 0.2
set_kv shader None
beat 0.7

# Zoom from the smallest supported terminal type to the largest, pull back to
# tiny, then settle at the demo's readable default.
for z in 8 10 12 16 22 30 40 48 40 30 22 16 12 10 8 18; do
  set_kv font-size "$z"
  beat 0.45
done
for f in JetBrainsMono-Regular MonaspaceRadon-Regular Glass_TTY_VT220 Monocraft DepartureMono-Regular IntelOneMono-Regular GeistMono-Regular; do
  set_kv font-family "$f"
  beat 0.36
done

set_kv shader None
set_kv theme B/W
[ -n "$ORIG_FONTSZ" ] && set_kv font-size "$ORIG_FONTSZ" || set_kv font-size 18
[ -n "$ORIG_FONT" ] && set_kv font-family "$ORIG_FONT"
beat 0.8
run clear; beat 0.35

# ═══ close ═══════════════════════════════════════════════════════════════
ok "$PRODUCT_NAME — the terminal that became a platform"
beat 1.4
echo "done — stop the recording."
