#!/usr/bin/env bash
# Compact pane content for scripts/grid-demo.sh. Keeping this in a helper
# makes the on-screen command short while a newly-created shell starts.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode="${1:-overview}"

printf '\033]0;cmdy\007'
clear

case "$mode" in
  overview)
    printf '\033[1mcmdy / a terminal turned platform\033[0m\n\n'
    printf 'terminal        VT engine + Metal renderer\n'
    printf 'workflow        blocks + actions + agents\n'
    printf 'windows         splits ↔ native grid\n'
    printf 'platform        surfaces + extensions + channels\n'
    printf 'unicode         λ  ∑  π  ∞  ▁▂▃▄▅▆▇█\n'
    ;;
  colors)
    printf '\033[1mANSI / 256 COLORS\033[0m\n\n'
    for i in $(seq 0 255); do
      printf '\033[48;5;%dm  \033[0m' "$i"
      [[ $(((i + 1) % 32)) -eq 0 ]] && echo
    done
    printf '\n▁▂▃▄▅▆▇█  ░▒▓█\n'
    ;;
  truecolor)
    printf '\033[1mTRUECOLOR + TEXT\033[0m\n\n'
    for i in $(seq 0 95); do
      printf '\033[48;2;%d;%d;%dm \033[0m' "$((i * 2))" "$((64 + i))" "$((255 - i * 2))"
      [[ $(((i + 1) % 48)) -eq 0 ]] && echo
    done
    printf '\n'
    printf 'plain   \033[1mbold\033[0m   \033[3mitalic\033[0m   \033[4munderline\033[0m   \033[7mreverse\033[0m\n'
    printf '\033[38;2;255;96;72mR\033[38;2;255;190;72mG\033[38;2;82;220;150mB\033[0m   GPU frame ready\n'
    ;;
  engine)
    printf '\033[1mENGINE\033[0m\n\n'
    printf 'VT parser       ✓\n'
    printf 'PTY transport   ✓\n'
    printf 'Metal atlas     ✓\n'
    printf 'Scrollback      ✓\n'
    printf 'Shell process   live\n'
    printf '\n00  01  02  03  04\n10  11  12  13  14\n'
    ;;
  unicode)
    printf '\033[1mUNICODE\033[0m\n\n'
    printf 'blocks   ▁▂▃▄▅▆▇█\n'
    printf 'shade    ░▒▓█\n'
    printf 'braille  ⣿⣶⣤⣀⠿⠷⠟\n'
    printf 'arrows   ← ↑ → ↓\n'
    printf 'math     λ ∑ π ∞ ≈\n'
    printf 'emoji    ● ◐ ◒ ◓\n'
    ;;
  project)
    printf '\033[1mPROJECT\033[0m\n\n'
    printf 'branch      main\n'
    printf 'tests       84 passed\n'
    printf 'build       signed\n'
    printf 'release     ready\n'
    ;;
  blocks)
    printf '\033[1mCOMMAND BLOCKS\033[0m\n\n'
    printf '┌ tests\n'
    printf '│  84 passed       1.8s\n'
    printf '└ status           ready\n\n'
    printf '┌ package\n'
    printf '│  app signed      2.4s\n'
    printf '└ artifact         cmdy.dmg\n'
    ;;
  monitor)
    printf '\033[1mSYSTEM MONITOR\033[0m\n\n'
    printf 'renderer      8.3%%   ▁▂▃▅▃▂▁\n'
    printf 'terminal      2.1%%   ▁▁▂▃▂▁▁\n'
    printf 'extensions    1.4%%   ▁▂▂▁▂▁▁\n'
    printf 'memory       184 MB  ▓▓▓░░░░\n'
    printf 'frames       120 Hz  ● live\n'
    ;;
  agents)
    printf '\033[1mAGENT SESSIONS\033[0m\n\n'
    printf 'codex      implementing    ●\n'
    printf 'claude     tests green     ✓\n'
    printf 'pi         awaiting input  ○\n'
    printf 'local      indexing        ◐\n\n'
    printf 'follow / gather / focus\n'
    ;;
  channels)
    printf '\033[1mCHANNELS\033[0m\n\n'
    printf 'GitHub      ready   12\n'
    printf 'Slack       new      3\n'
    printf 'Linear      open     5\n'
    printf 'Email       waiting  8\n\n'
    printf 'one durable work inbox\n'
    ;;
  platform)
    printf '\033[1mEXTENSIONS\033[0m\n\n'
    printf 'Browser     Chromium\n'
    printf 'Sim         iOS tools\n'
    printf 'Swarm       agents\n'
    printf 'Bridge      MCP runtime\n'
    printf 'Detox       synth\n'
    ;;
  glyphstorm|glyphstream)
    python3 - "$mode" <<'PY'
import random
import sys
import time

streaming = sys.argv[1] == "glyphstream"
random.seed(0xC0D7)
glyphs = ["⌁", "⌇", "⌐", "⌙", "⋮", "⋯", "›", "»", "λ", "π", "∑", "⌘", "◦", "○", "◐", "⣿", "⣶", "⣤", "⣀", "░", "▒", "▓"]
inks = [81, 117, 159, 213, 220, 215, 203, 118, 229]

def ink(value, color):
    return f"\033[38;5;{color}m{value}\033[0m"

def ribbon(width, start):
    cells = []
    for index in range(width):
        color = inks[(start + index // 5) % len(inks)]
        cells.append(ink("▪", color))
    return "".join(cells)

print("\033[2J\033[H", end="")
print(ink("GLYPH FIELD / LIVE SIGNAL", 255), end="\n\n")
rows = 150 if streaming else 24
for row in range(rows):
    indent = random.randrange(0, 32)
    kind = row % 7
    if kind in (1, 5):
        body = ribbon(random.randrange(22, 58), row)
    elif kind == 3:
        body = ink("⣿" * random.randrange(4, 12), random.choice(inks))
        body += "  " + ink(" ".join(random.choice(glyphs) for _ in range(9)), 252)
    else:
        body = ink(" ".join(random.choice(glyphs) for _ in range(random.randrange(8, 21))), random.choice(inks))
    print(" " * indent + body, flush=True)
    if streaming:
        time.sleep(0.027)
PY
    ;;
  *)
    echo "unknown demo pane: $mode" >&2
    exit 2
    ;;
esac

printf '\033]0;cmdy\007'
