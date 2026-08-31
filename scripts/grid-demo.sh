#!/usr/bin/env bash
# A loopable black-theme product tour for the website hero:
# terminal zoo -> native panel -> live splits -> the same layout as native
# grid windows -> live add/close/reorder -> exact split layout -> one terminal.
set -euo pipefail

PACE="${PACE:-1.0}"
FONT_STEPS="${FONT_STEPS:-5}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/product-identity.sh"

CONFIG_DIR="$(product_env_value CONFIG_DIR "$HOME/.config/$PRODUCT_CONFIG_DIR_NAME")"
DISCOVERY="$CONFIG_DIR/plugin-api.json"
if [[ ! -f "$DISCOVERY" ]]; then
  echo "$PRODUCT_TITLE_NAME is not running for CONFIG_DIR=$CONFIG_DIR" >&2
  exit 1
fi

read -r PORT TOKEN < <(python3 - "$DISCOVERY" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
print(data["port"], data["token"])
PY
)
BASE="http://127.0.0.1:$PORT"
AUTH="Authorization: Bearer $TOKEN"

pause() {
  python3 -c 'import sys,time; time.sleep(float(sys.argv[1])*float(sys.argv[2]))' "$1" "$PACE"
}
json_string() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}
api_get() { curl -fsS -H "$AUTH" "$BASE$1"; }
api_post() {
  curl -fsS -H "$AUTH" -H 'Content-Type: application/json' \
    -X POST "$BASE$1" -d "$2" >/dev/null
}
run_in() {
  local payload
  payload="{\"command\":$(json_string "$2")}";
  api_post "/v1/panes/$1/run" "$payload"
}
split_in() {
  curl -fsS -H "$AUTH" -H 'Content-Type: application/json' \
    -X POST "$BASE/v1/panes/$1/split" -d "{\"direction\":\"$2\"}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("pane", ""))'
}
close_in() { api_post "/v1/panes/$1/close" '{}'; }
focus_in() { api_post "/v1/panes/$1/focus" '{}'; }
type_in() { api_post "/v1/panes/$1/type" "{\"text\":$(json_string "$2")}"; }

list_pane_ids() {
  api_get /v1/panes | python3 -c 'import json,sys
print(" ".join(p["id"] for p in json.load(sys.stdin)["panes"]))'
}

pane_window_number() {
  api_get /v1/panes | python3 -c 'import json,sys
wanted=sys.argv[1]
print(next((p.get("windowNumber", 0) for p in json.load(sys.stdin)["panes"] if p["id"] == wanted), 0))' "$1"
}

wait_for_pane_count() {
  local wanted="$1"
  for _ in $(seq 1 60); do
    local found
    found="$(api_get /v1/panes | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["panes"]))')"
    [[ "$found" == "$wanted" ]] && return 0
    pause 0.08
  done
  echo "Timed out waiting for $wanted panes" >&2
  return 1
}

new_window() {
  local before after new_id
  before=" $(list_pane_ids) "
  osascript - "$PRODUCT_TITLE_NAME" <<'APPLESCRIPT'
on run argv
  tell application "System Events"
    tell process (item 1 of argv)
      set frontmost to true
      keystroke "n" using command down
    end tell
  end tell
end run
APPLESCRIPT
  for _ in $(seq 1 60); do
    after="$(list_pane_ids)"
    for new_id in $after; do
      if [[ "$before" != *" $new_id "* ]]; then
        printf '%s\n' "$new_id"
        return 0
      fi
    done
    pause 0.08
  done
  echo "Timed out waiting for a new window pane" >&2
  return 1
}

new_tab() {
  local before after new_id
  before=" $(list_pane_ids) "
  osascript - "$PRODUCT_TITLE_NAME" <<'APPLESCRIPT'
on run argv
  tell application "System Events"
    tell process (item 1 of argv)
      set frontmost to true
      keystroke "t" using command down
    end tell
  end tell
end run
APPLESCRIPT
  for _ in $(seq 1 60); do
    after="$(list_pane_ids)"
    for new_id in $after; do
      if [[ "$before" != *" $new_id "* ]]; then
        printf '%s\n' "$new_id"
        return 0
      fi
    done
    pause 0.08
  done
  echo "Timed out waiting for a new tab pane" >&2
  return 1
}

show_panel() {
  curl -fsS -H "$AUTH" -H 'Content-Type: application/json' \
    -X POST "$BASE/v1/ui/panel" -d "$1" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("panel", ""))'
}

dismiss_panel() { api_post "/v1/ui/$1/dismiss" '{}'; }

front_window_fill_screen() {
  local frame
  frame="$(osascript -l JavaScript -e 'ObjC.import("AppKit"); var ds=$.NSScreen.mainScreen; var dv=ds.visibleFrame; var df=ds.frame; [Number(dv.origin.x), Number(df.size.height-dv.origin.y-dv.size.height), Number(dv.size.width), Number(dv.size.height)].join(",")')"
  osascript - "$PRODUCT_TITLE_NAME" "$frame" <<'APPLESCRIPT'
on run argv
  set processName to item 1 of argv
  set AppleScript's text item delimiters to ","
  set dimensions to text items of (item 2 of argv)
  set AppleScript's text item delimiters to ""
  set frameX to item 1 of dimensions as integer
  set frameY to item 2 of dimensions as integer
  set frameWidth to item 3 of dimensions as integer
  set frameHeight to item 4 of dimensions as integer
  tell application "System Events"
    tell process processName
      set frontmost to true
      tell front window
        set position to {frameX, frameY}
        set size to {frameWidth, frameHeight}
      end tell
    end tell
  end tell
end run
APPLESCRIPT

  # Reset to the product default, then enlarge by the requested number of
  # native Text Size steps. The website recording defaults to five.
  osascript - "$PRODUCT_TITLE_NAME" "$FONT_STEPS" <<'APPLESCRIPT'
on run argv
  set processName to item 1 of argv
  set increaseCount to item 2 of argv as integer
  tell application "System Events"
    tell process processName
      set frontmost to true
      click menu item "Reset" of menu 1 of menu item "Text Size" of menu 1 of menu bar item "View" of menu bar 1
      repeat increaseCount times
        click menu item "Increase" of menu 1 of menu item "Text Size" of menu 1 of menu bar item "View" of menu bar 1
      end repeat
    end tell
  end tell
end run
APPLESCRIPT
}

# AppKit can preserve a newly-created tab's old content size when it joins an
# already full-screen tab group. Nudge the selected native window by two pixels
# and restore it so the tab's live terminal host is laid out against the full
# recording frame instead of remaining stranded in the upper-left corner.
front_window_refit() {
  local frame
  frame="$(osascript -l JavaScript -e 'ObjC.import("AppKit"); var ds=$.NSScreen.mainScreen; var dv=ds.visibleFrame; var df=ds.frame; [Number(dv.origin.x), Number(df.size.height-dv.origin.y-dv.size.height), Number(dv.size.width), Number(dv.size.height)].join(",")')"
  osascript - "$PRODUCT_TITLE_NAME" "$frame" <<'APPLESCRIPT'
on run argv
  set processName to item 1 of argv
  set AppleScript's text item delimiters to ","
  set dimensions to text items of (item 2 of argv)
  set AppleScript's text item delimiters to ""
  set frameX to item 1 of dimensions as integer
  set frameY to item 2 of dimensions as integer
  set frameWidth to item 3 of dimensions as integer
  set frameHeight to item 4 of dimensions as integer
  tell application "System Events"
    tell process processName
      set frontmost to true
      tell front window
        set position to {frameX, frameY}
        set size to {frameWidth - 2, frameHeight - 2}
        delay 0.08
        set position to {frameX, frameY}
        set size to {frameWidth, frameHeight}
      end tell
    end tell
  end tell
end run
APPLESCRIPT
  pause 0.12
}

menu_action() {
  osascript - "$PRODUCT_TITLE_NAME" "$1" "$2" <<'APPLESCRIPT'
on run argv
  set processName to item 1 of argv
  set menuName to item 2 of argv
  set itemName to item 3 of argv
  tell application "System Events"
    tell process processName
      set frontmost to true
      repeat 40 times
        tell menu 1 of menu bar item menuName of menu bar 1
          if exists menu item itemName then
            click menu item itemName
            return true
          end if
        end tell
        delay 0.05
      end repeat
      error "menu item was not available: " & menuName & " > " & itemName
    end tell
  end tell
end run
APPLESCRIPT
}

window_action() { menu_action "Window" "$1"; }
view_action() { menu_action "View" "$1"; }

prepare_window_chrome() {
  osascript - "$PRODUCT_TITLE_NAME" <<'APPLESCRIPT'
on run argv
  set processName to item 1 of argv
  tell application "System Events"
    tell process processName
      set frontmost to true
      tell front window
        set sidebarButtons to every button whose description is "Show or Hide Sidebar"
        if (count of sidebarButtons) > 0 then
          set sidebarButton to item 1 of sidebarButtons
          if value of sidebarButton is "On" then click sidebarButton
        end if
      end tell
      delay 0.15
      tell menu 1 of menu bar item "View" of menu bar 1
        if exists menu item "Hide Tab Bar" then click menu item "Hide Tab Bar"
      end tell
    end tell
  end tell
end run
APPLESCRIPT
}

toggle_sidebar() {
  osascript - "$PRODUCT_TITLE_NAME" <<'APPLESCRIPT'
on run argv
  tell application "System Events"
    tell process (item 1 of argv)
      set frontmost to true
      tell front window
        set sidebarButtons to every button whose description is "Show or Hide Sidebar"
        if (count of sidebarButtons) = 0 then error "cmdy sidebar button was not found"
        click item 1 of sidebarButtons
      end tell
    end tell
  end tell
end run
APPLESCRIPT
}

toggle_browser() {
  osascript - "$PRODUCT_TITLE_NAME" <<'APPLESCRIPT'
on run argv
  tell application "System Events"
    tell process (item 1 of argv)
      set frontmost to true
      tell front window
        set browserButtons to every button whose description is "Show or Hide Browser"
        if (count of browserButtons) = 0 then error "cmdy Browser button was not found"
        click item 1 of browserButtons
      end tell
    end tell
  end tell
end run
APPLESCRIPT
}

navigate_browser() {
  local discovery="$CONFIG_DIR/browser-api.json"
  if [[ ! -f "$discovery" ]]; then
    discovery="$HOME/.config/$PRODUCT_CONFIG_DIR_NAME/browser-api.json"
  fi
  [[ -f "$discovery" ]] || {
    echo "Browser API discovery was not found" >&2
    return 1
  }
  local browser_port browser_token window_number payload
  read -r browser_port browser_token < <(python3 - "$discovery" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
print(data["port"], data["token"])
PY
)
  window_number="$(pane_window_number "$PANE")"
  payload="{\"tool\":\"navigate\",\"arguments\":{\"url\":$(json_string "$1")},\"window\":$window_number}"
  curl -fsS -H "Authorization: Bearer $browser_token" \
    -H 'Content-Type: application/json' -X POST \
    "http://127.0.0.1:$browser_port/execute" -d "$payload" >/dev/null
}

sim_execute() {
  local discovery="$CONFIG_DIR/sim-api.json"
  if [[ ! -f "$discovery" ]]; then
    discovery="$HOME/.config/$PRODUCT_CONFIG_DIR_NAME/sim-api.json"
  fi
  [[ -f "$discovery" ]] || {
    echo "Sim API discovery was not found" >&2
    return 1
  }
  local sim_port sim_token window_number payload
  read -r sim_port sim_token < <(python3 - "$discovery" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
print(data["port"], data["token"])
PY
)
  window_number="$(pane_window_number "$PANE")"
  payload="{\"tool\":$(json_string "$1"),\"arguments\":{},\"window\":$window_number}"
  curl -fsS -H "Authorization: Bearer $sim_token" \
    -H 'Content-Type: application/json' -X POST \
    "http://127.0.0.1:$sim_port/execute" -d "$payload"
}

start_sim_mirror() {
  local response url
  response="$(sim_execute mirror)"
  url="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("result", {}).get("url", ""))' <<<"$response")"
  [[ -n "$url" ]] || {
    echo "serve-sim did not return a mirror URL: $response" >&2
    return 1
  }
  for _ in $(seq 1 120); do
    if curl -fsS --max-time 1 "$url" >/dev/null 2>&1; then
      printf '%s\n' "$url"
      return 0
    fi
    pause 0.1
  done
  echo "Timed out waiting for serve-sim at $url" >&2
  return 1
}

stop_sim_mirror() {
  sim_execute mirror_stop >/dev/null
}

palette_run() {
  osascript - "$PRODUCT_TITLE_NAME" "$1" <<'APPLESCRIPT'
on run argv
  tell application "System Events"
    tell process (item 1 of argv)
      set frontmost to true
      keystroke "p" using {command down, shift down}
      delay 0.25
      keystroke (item 2 of argv)
      delay 0.35
      key code 36
    end tell
  end tell
end run
APPLESCRIPT
}

palette_config_reel() {
  # Open the Config Mixer from the command palette, then visit every family.
  # Its remembered starting tab does not matter: five Tab presses cover the
  # complete Theme/Font/Shader/Cursor/Spacing ring exactly once.
  palette_run "Config Mixer"
  pause 0.45
  osascript - "$PRODUCT_TITLE_NAME" <<'APPLESCRIPT'
on run argv
  tell application "System Events"
    tell process (item 1 of argv)
      repeat 5 times
        repeat 3 times
          key code 125
          delay 0.13
        end repeat
        key code 36
        delay 0.18
        key code 48
        delay 0.18
      end repeat
      key code 53
    end tell
  end tell
end run
APPLESCRIPT
}

appearance_action() {
  osascript - "$PRODUCT_TITLE_NAME" "$1" "$2" <<'APPLESCRIPT'
on run argv
  set processName to item 1 of argv
  set categoryName to item 2 of argv
  set choiceName to item 3 of argv
  tell application "System Events"
    tell process processName
      set frontmost to true
      tell menu 1 of menu item "Appearance" of menu 1 of menu bar item "View" of menu bar 1
        set categoryItems to every menu item whose name starts with categoryName
        if (count of categoryItems) = 0 then error "appearance category was not available: " & categoryName
        tell menu 1 of item 1 of categoryItems
          if not (exists menu item choiceName) then error "appearance choice was not available: " & choiceName
          click menu item choiceName
        end tell
      end tell
    end tell
  end tell
end run
APPLESCRIPT
}

reset_demo_appearance() {
  # Always leave the app in the requested neutral house look, even when a
  # recording is interrupted halfway through the visual reel.
  osascript - "$PRODUCT_TITLE_NAME" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
  tell application "System Events"
    tell process (item 1 of argv)
      set frontmost to true
      tell menu 1 of menu item "Text Size" of menu 1 of menu bar item "View" of menu bar 1
        click menu item "Reset"
      end tell
    end tell
  end tell
end run
APPLESCRIPT
  appearance_action "Theme" "B/W" >/dev/null 2>&1 || true
  appearance_action "Shader" "None" >/dev/null 2>&1 || true
  appearance_action "Font" "Fragment Mono" >/dev/null 2>&1 || true
  appearance_action "Cursor" "Block (blink)" >/dev/null 2>&1 || true
  appearance_action "Line Spacing" "Relaxed" >/dev/null 2>&1 || true
}

wait_for_windows() {
  local wanted="$1"
  for _ in $(seq 1 50); do
    local found
    found="$(osascript - "$PRODUCT_TITLE_NAME" <<'APPLESCRIPT'
on run argv
  tell application "System Events" to tell process (item 1 of argv) to return count of windows
end run
APPLESCRIPT
)"
    [[ "$found" == "$wanted" ]] && return 0
    pause 0.08
  done
  echo "Timed out waiting for $wanted windows" >&2
  return 1
}

compile_drag_helper() {
  local helper="${TMPDIR:-/tmp}/cmdy-demo-window-drag"
  if [[ ! -x "$helper" || "$ROOT/scripts/demo-window-drag.swift" -nt "$helper" ]]; then
    xcrun swiftc "$ROOT/scripts/demo-window-drag.swift" -o "$helper"
  fi
  printf '%s\n' "$helper"
}

drag_window_to_window() {
  local source_number target_number helper
  source_number="$(pane_window_number "$1")"
  target_number="$(pane_window_number "$2")"
  [[ "$source_number" != 0 && "$target_number" != 0 ]] || {
    echo "Could not resolve native windows for drag" >&2
    return 1
  }
  focus_in "$1"
  pause 0.55
  helper="$(compile_drag_helper)"
  if ! "$helper" "$source_number" "$target_number"; then
    echo "Retrying the top-left grid drag" >&2
    pause 0.45
    "$helper" "$source_number" "$target_number"
  fi
}

PANE="$(api_get /v1/panes | python3 -c 'import json,sys
panes=json.load(sys.stdin)["panes"]
focused=[pane for pane in panes if pane.get("focused")]
print((focused or panes)[0]["id"] if panes else "")')"
[[ -n "$PANE" ]] || { echo "No terminal pane is open" >&2; exit 1; }

trap reset_demo_appearance EXIT

# Use a stable public-looking alias in every command rendered on screen. The
# source checkout path must never leak into the website recording.
ln -sfn "$ROOT/scripts/demo-pane.sh" /tmp/cmdy-zoo
pane_demo="PROMPT='%% '; /tmp/cmdy-zoo"

front_window_fill_screen
prepare_window_chrome
run_in "$PANE" "$pane_demo overview"
pause 1.8

view_action "Show Tab Bar"
pause 0.6

# Populate real tabs before showing the sidebar so the recording demonstrates
# both native tab presentations updating from the same live sessions.
TAB_ENGINE="$(new_tab)"
front_window_refit
run_in "$TAB_ENGINE" "$pane_demo engine"
pause 0.65
TAB_PROJECT="$(new_tab)"
front_window_refit
run_in "$TAB_PROJECT" "$pane_demo project"
pause 0.65
TAB_AGENTS="$(new_tab)"
front_window_refit
run_in "$TAB_AGENTS" "$pane_demo agents"
pause 1.15

# Cycle them across the top tab bar, then do it again with the sidebar open.
for tab in "$PANE" "$TAB_ENGINE" "$TAB_PROJECT" "$TAB_AGENTS"; do
  focus_in "$tab"
  front_window_refit
  pause 0.48
done
toggle_sidebar
pause 1.0
for tab in "$PANE" "$TAB_ENGINE" "$TAB_PROJECT" "$TAB_AGENTS"; do
  focus_in "$tab"
  front_window_refit
  pause 0.58
done

# Close the extra tabs visibly, newest first, while both selectors remain up.
for tab in "$TAB_AGENTS" "$TAB_PROJECT" "$TAB_ENGINE"; do
  close_in "$tab"
  pause 0.65
done
focus_in "$PANE"
pause 0.55
toggle_sidebar
pause 0.9
view_action "Hide Tab Bar"
pause 0.75

run_in "$PANE" "$pane_demo colors"
pause 1.45
run_in "$PANE" "$pane_demo truecolor"
pause 1.35
run_in "$PANE" "$pane_demo unicode"
pause 1.35

run_in "$PANE" "vim -u NONE -R /tmp/cmdy-zoo"
pause 1.65
type_in "$PANE" $'\033:q!\r'
pause 0.35

run_in "$PANE" "$pane_demo monitor"
pause 1.8

run_in "$PANE" "$pane_demo blocks"
pause 1.55

PANEL_ID="$(show_panel '{"mode":"list","title":"Extension runtime","items":[{"title":"Browser","subtitle":"Chromium + agent automation"},{"title":"Sim","subtitle":"iOS build, input and capture"},{"title":"Swarm","subtitle":"live agent sessions"},{"title":"Channels","subtitle":"one durable work inbox"}]}')"
[[ -n "$PANEL_ID" ]] || { echo "Could not open native panel" >&2; exit 1; }
pause 2.5
dismiss_panel "$PANEL_ID"
pause 0.35
run_in "$PANE" "$pane_demo overview"
pause 0.75

# Show cmdy's real docked Chromium surface and navigate it like a user would.
toggle_browser
pause 1.2
navigate_browser "https://google.com"
pause 3.2
toggle_browser
pause 1.0

# Use Sim's window-scoped serve-sim mirror inside cmdy's Browser. This is the
# agent-facing loop people actually use, not the separate Simulator.app dock.
toggle_browser
SIM_MIRROR_URL="$(start_sim_mirror)"
focus_in "$PANE"
pause 0.35
navigate_browser "$SIM_MIRROR_URL"
pause 4.5
toggle_browser
stop_sim_mirror
pause 0.8

RIGHT="$(split_in "$PANE" right)"
[[ -n "$RIGHT" ]] || { echo "Could not create right split" >&2; exit 1; }
pause 0.4
run_in "$PANE" "$pane_demo colors"
run_in "$RIGHT" "$pane_demo engine"
pause 0.65

LOWER_LEFT="$(split_in "$PANE" down)"
[[ -n "$LOWER_LEFT" ]] || { echo "Could not create lower-left split" >&2; exit 1; }
pause 0.4
run_in "$LOWER_LEFT" "$pane_demo unicode"
pause 0.65

LOWER_RIGHT="$(split_in "$RIGHT" down)"
[[ -n "$LOWER_RIGHT" ]] || { echo "Could not create lower-right split" >&2; exit 1; }
pause 0.4
run_in "$LOWER_RIGHT" "$pane_demo project"
pause 0.65

PLATFORM="$(split_in "$LOWER_RIGHT" right)"
[[ -n "$PLATFORM" ]] || { echo "Could not create platform split" >&2; exit 1; }
pause 0.4
run_in "$PLATFORM" "$pane_demo platform"
pause 2.0

window_action "Break Splits into Grid Windows"
wait_for_windows 5
pause 2.2

EXTRA="$(new_window)"
wait_for_windows 6
run_in "$EXTRA" "$pane_demo glyphstorm"

# The dense-window stress is product theatre and a real responsiveness test:
# burst to a full 4×3 wall, give every tile different live terminal material,
# then collapse the burst just as quickly without losing the layout.
GRID_BURST=()
GRID_MODES=(agents channels colors unicode monitor project)
for mode in "${GRID_MODES[@]}"; do
  pane="$(new_window)"
  GRID_BURST+=("$pane")
  run_in "$pane" "$pane_demo $mode"
done
wait_for_windows 12
pause 2.4
for (( index=${#GRID_BURST[@]}-1; index>=0; index-- )); do
  close_in "${GRID_BURST[index]}"
done
wait_for_windows 6
wait_for_pane_count 6
pause 1.5

drag_window_to_window "$PANE" "$PLATFORM"
pause 2.8

window_action "Combine Grid Windows into Splits"
wait_for_windows 1
pause 2.5

close_in "$EXTRA"
pause 0.35
close_in "$PLATFORM"
pause 0.35
close_in "$LOWER_RIGHT"
pause 0.35
close_in "$LOWER_LEFT"
pause 0.35
close_in "$RIGHT"
pause 0.65

# End on a fast, palette-driven visual reel. The terminal keeps scrolling
# abstract glyph fields while Theme, Font, Shader, Cursor, and Spacing preview
# together, so follow-the-text shaders have actual motion to react to.
run_in "$PANE" "$pane_demo glyphstream"
pause 0.45
palette_config_reel
pause 0.35
palette_run "Databloom"
pause 2.4
palette_run "Increase Font Size"
pause 0.45
palette_run "Increase Font Size"
pause 0.65

reset_demo_appearance
run_in "$PANE" "$pane_demo overview"
pause 2.0

echo "grid demo complete"
