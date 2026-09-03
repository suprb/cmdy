#!/bin/bash
# Run every headless suite (CmdyCore is the only engine).
# Builds first; exits non-zero on the first failing suite.
set -uo pipefail
cd "$(dirname "$0")"
source scripts/product-identity.sh

CONFIGURATION="${CMDY_TEST_CONFIGURATION:-debug}"
case "$CONFIGURATION" in
  debug|release) ;;
  *) echo "CMDY_TEST_CONFIGURATION must be debug or release" >&2; exit 2 ;;
esac
swift build -c "$CONFIGURATION" || exit 1
BIN=".build/$CONFIGURATION/$PRODUCT_EXECUTABLE"
FAIL=0

for t in selftest menu-bar-test panel-test shader-test reflow-test wheel-test scroll-test graphics-test; do
  out=$("$BIN" --$t 2>&1)
  code=$?
  last=$(echo "$out" | tail -1)
  if [ $code -eq 0 ]; then
    echo "PASS  --$t  $last"
  else
    echo "FAIL  --$t"
    echo "$out" | tail -12
    FAIL=1
  fi
done

# Show Editor is a visibility command, not a document factory. Invoking it
# twice from one terminal must focus the same attached editor and keep the
# document count stable after the first invocation.
SHOW_EDITOR_HOME=$(mktemp -d "/tmp/$PRODUCT_SLUG-show-editor.XXXXXX")
mkdir -p "$SHOW_EDITOR_HOME/config"
out=$(env HOME="$SHOW_EDITOR_HOME" CFFIXED_USER_HOME="$SHOW_EDITOR_HOME" \
    "${PRODUCT_ENV_PREFIX}_CONFIG_DIR=$SHOW_EDITOR_HOME/config" \
    "$BIN" --ui-test-show-editor 2>&1)
code=$?
rm -rf "$SHOW_EDITOR_HOME"
if [ $code -eq 0 ] && grep -Fq "UISHOWEDITOR" <<< "$out" \
    && grep -Fq "afterFirst=1 afterSecond=1" <<< "$out" \
    && grep -Fq "reused=true" <<< "$out" \
    && grep -Fq "attached=true" <<< "$out" \
    && grep -Fq "visible=true" <<< "$out" \
    && grep -Fq "focused=true" <<< "$out" \
    && grep -Fq "routed=true" <<< "$out" \
    && grep -Fq "ok=true" <<< "$out"; then
  echo "PASS  --ui-test-show-editor  File menu routed twice and reused one attached document"
else
  echo "FAIL  --ui-test-show-editor"
  echo "$out" | tail -20
  FAIL=1
fi

# A fresh shell is disposable and closes on the first click. Once a command
# has run, the same action must retain the destructive confirmation.
CLOSE_TEST_HOME=$(mktemp -d "/tmp/$PRODUCT_SLUG-window-close.XXXXXX")
mkdir -p "$CLOSE_TEST_HOME/config"
out=$(env HOME="$CLOSE_TEST_HOME" CFFIXED_USER_HOME="$CLOSE_TEST_HOME" \
    "${PRODUCT_ENV_PREFIX}_CONFIG_DIR=$CLOSE_TEST_HOME/config" \
    "$BIN" --ui-test-window-close-confirmation 2>&1)
code=$?
rm -rf "$CLOSE_TEST_HOME"
if [ $code -eq 0 ] \
    && grep -Fq "UICLOSE emptyImmediate=true" <<< "$out" \
    && grep -Fq "activeProtected=true" <<< "$out" \
    && grep -Fq "activeClosed=true" <<< "$out" \
    && grep -Fq "ok=true" <<< "$out"; then
  echo "PASS  --ui-test-window-close-confirmation  empty closes; active confirms and closes"
else
  echo "FAIL  --ui-test-window-close-confirmation"
  echo "$out" | tail -24
  FAIL=1
fi

# The lean app must keep Browser discoverable even without a legacy local
# Chromium Extension: View menu, default toolbar, Extensions row, and all
# three native recovery prompts must point at the signed Browser edition.
BROWSER_INSTALL_HOME=$(mktemp -d "/tmp/$PRODUCT_SLUG-browser-install.XXXXXX")
mkdir -p "$BROWSER_INSTALL_HOME/config"
BROWSER_INSTALL_DEFAULTS="$PRODUCT_BUNDLE_IDENTIFIER.browser-install.$PPID.$$"
out=$(env HOME="$BROWSER_INSTALL_HOME" CFFIXED_USER_HOME="$BROWSER_INSTALL_HOME" \
    "${PRODUCT_ENV_PREFIX}_CONFIG_DIR=$BROWSER_INSTALL_HOME/config" \
    "${PRODUCT_ENV_PREFIX}_DEFAULTS_DOMAIN=$BROWSER_INSTALL_DEFAULTS" \
    "$BIN" --ui-test-browser-install-recovery 2>&1)
code=$?
/usr/bin/defaults delete "$BROWSER_INSTALL_DEFAULTS" >/dev/null 2>&1 || true
rm -rf "$BROWSER_INSTALL_HOME"
if [ $code -eq 0 ] && grep -Fq "UIBROWSERINSTALL unavailable=true" <<< "$out" \
    && grep -Fq "menu=true" <<< "$out" \
    && grep -Fq "menuPrompt=true" <<< "$out" \
    && grep -Fq "toolbar=true" <<< "$out" \
    && grep -Fq "toolbarPrompt=true" <<< "$out" \
    && grep -Fq "row=true" <<< "$out" \
    && grep -Fq "rowPrompt=true" <<< "$out" \
    && grep -Fq "ok=true" <<< "$out"; then
  echo "PASS  --ui-test-browser-install-recovery  lean menu, toolbar, row, and prompts passed"
else
  echo "FAIL  --ui-test-browser-install-recovery"
  echo "$out" | tail -24
  FAIL=1
fi

# The compact Finder-style controls live inside the full-size titlebar. Send a
# real mouse down/up to one visible icon so titlebar dragging or toolbar-layout
# normalization cannot silently make the controls unclickable again.
TOOLBAR_TEST_HOME=$(mktemp -d "/tmp/$PRODUCT_SLUG-toolbar-click.XXXXXX")
mkdir -p "$TOOLBAR_TEST_HOME/config"
out=$(env HOME="$TOOLBAR_TEST_HOME" CFFIXED_USER_HOME="$TOOLBAR_TEST_HOME" \
    "${PRODUCT_ENV_PREFIX}_CONFIG_DIR=$TOOLBAR_TEST_HOME/config" \
    "$BIN" --ui-test-custom-toolbar-click 2>&1)
code=$?
rm -rf "$TOOLBAR_TEST_HOME"
if [ $code -eq 0 ] && grep -Fq "UITOOLBARCLICK" <<< "$out" \
    && grep -Fq "ok=true" <<< "$out"; then
  echo "PASS  --ui-test-custom-toolbar-click  reference opacity 0.495/0.8/1.0 and click passed"
else
  echo "FAIL  --ui-test-custom-toolbar-click"
  echo "$out" | tail -20
  FAIL=1
fi

# Reproduce the reported dense attributed-output trackpad path in a real
# window. The app performs the machine-independent assertions itself: viewport
# capture/projection reuse, bounded row rebuilding, correct semantic overlays,
# exact return to the starting scroll position, and at least 75% of the
# hardware-aware presentation budget (including Low Power Mode and thermal
# pressure).
for dense_scroll_pixels in 3 48; do
  DENSE_SCROLL_HOME=$(mktemp -d "/tmp/$PRODUCT_SLUG-dense-scroll.XXXXXX")
  mkdir -p "$DENSE_SCROLL_HOME/config"
  out=$(env HOME="$DENSE_SCROLL_HOME" \
      CFFIXED_USER_HOME="$DENSE_SCROLL_HOME" \
      "${PRODUCT_ENV_PREFIX}_CONFIG_DIR=$DENSE_SCROLL_HOME/config" \
      "$BIN" --ui-test-dense-scroll-profile \
      --ui-test-dense-scroll-failed \
      "--ui-test-dense-scroll-pixels=$dense_scroll_pixels" 2>&1)
  code=$?
  rm -rf "$DENSE_SCROLL_HOME"
  if [ $code -eq 0 ] && grep -Fq "UIDENSESCROLL variant=failed" <<< "$out" \
      && grep -Fq "pixels=$dense_scroll_pixels" <<< "$out" \
      && grep -Fq "ok=true" <<< "$out"; then
    echo "PASS  --ui-test-dense-scroll-profile  ${dense_scroll_pixels}px dense failed-block burst reused viewport"
  else
    echo "FAIL  --ui-test-dense-scroll-profile pixels=$dense_scroll_pixels"
    echo "$out" | tail -20
    FAIL=1
  fi
done

# A 120 Hz selection drag over the same dense failed blocks must remain pure
# overlay geometry. Any text-row rebuild makes selection feel heavy and is a
# deterministic regression; the app also requires 75% of its hardware-aware
# presentation budget.
DENSE_SELECTION_HOME=$(mktemp -d "/tmp/$PRODUCT_SLUG-dense-selection.XXXXXX")
mkdir -p "$DENSE_SELECTION_HOME/config"
out=$(env HOME="$DENSE_SELECTION_HOME" \
    CFFIXED_USER_HOME="$DENSE_SELECTION_HOME" \
    "${PRODUCT_ENV_PREFIX}_CONFIG_DIR=$DENSE_SELECTION_HOME/config" \
    "$BIN" --ui-test-dense-selection-profile 2>&1)
code=$?
rm -rf "$DENSE_SELECTION_HOME"
if [ $code -eq 0 ] && grep -Fq "UISELECTION" <<< "$out" \
    && grep -Fq "rebuilt=0" <<< "$out" \
    && grep -Fq "ok=true" <<< "$out"; then
  echo "PASS  --ui-test-dense-selection-profile  dense drag kept cadence and rebuilt zero text rows"
else
  echo "FAIL  --ui-test-dense-selection-profile"
  echo "$out" | tail -20
  FAIL=1
fi

# Adding and removing a choice from the customization panel must keep the
# visible title-band group compact throughout the edit. AppKit's stock palette
# otherwise reintroduces its much wider per-item slots.
TOOLBAR_CUSTOMIZE_HOME=$(mktemp -d "/tmp/$PRODUCT_SLUG-toolbar-customize.XXXXXX")
mkdir -p "$TOOLBAR_CUSTOMIZE_HOME/config"
out=$(env HOME="$TOOLBAR_CUSTOMIZE_HOME" \
    CFFIXED_USER_HOME="$TOOLBAR_CUSTOMIZE_HOME" \
    "${PRODUCT_ENV_PREFIX}_CONFIG_DIR=$TOOLBAR_CUSTOMIZE_HOME/config" \
    "$BIN" --ui-test-custom-toolbar-customizer 2>&1)
code=$?
rm -rf "$TOOLBAR_CUSTOMIZE_HOME"
if [ $code -eq 0 ] && grep -Fq "UITOOLBARMUTATION" <<< "$out" \
    && grep -Fq "compact=true" <<< "$out" \
    && grep -Fq "gap=6.0" <<< "$out" \
    && grep -Fq "activeTilesStyled=true" <<< "$out" \
    && grep -Fq "ok=true" <<< "$out"; then
  echo "PASS  --ui-test-custom-toolbar-customizer  add/remove stayed at 6pt; active tile styled"
else
  echo "FAIL  --ui-test-custom-toolbar-customizer"
  echo "$out" | tail -20
  FAIL=1
fi

# Split-local detach/close chrome must stay reachable in its reserved bare
# bottom rail and let both glyphs win real AppKit pointer hits
# instead of merely looking like buttons over the terminal surface.
SPLIT_AFFORDANCE_HOME=$(mktemp -d "/tmp/$PRODUCT_SLUG-split-affordance.XXXXXX")
mkdir -p "$SPLIT_AFFORDANCE_HOME/config"
out=$(env HOME="$SPLIT_AFFORDANCE_HOME" \
    CFFIXED_USER_HOME="$SPLIT_AFFORDANCE_HOME" \
    "${PRODUCT_ENV_PREFIX}_CONFIG_DIR=$SPLIT_AFFORDANCE_HOME/config" \
    "$BIN" --ui-test-split-affordance 2>&1)
code=$?
rm -rf "$SPLIT_AFFORDANCE_HOME"
if [ $code -eq 0 ] && grep -Fq "UISPLITAFFORDANCE ready" <<< "$out" \
    && grep -Fq "alwaysVisible=true" <<< "$out" \
    && grep -Fq "clickable=true" <<< "$out" \
    && grep -Fq "bottomRail=true" <<< "$out" \
    && grep -Fq "bare=true" <<< "$out" \
    && grep -Fq "detachClickable=true" <<< "$out" \
    && grep -Fq "detachClick=true" <<< "$out" \
    && grep -Fq "verticalFinelined=true" <<< "$out" \
    && grep -Fq "horizontalFinelined=true" <<< "$out" \
    && grep -Fq "ok=true" <<< "$out"; then
  echo "PASS  --ui-test-split-affordance  bare bottom rail, close click, detach click, and matched hairlines passed"
else
  echo "FAIL  --ui-test-split-affordance"
  echo "$out" | tail -24
    FAIL=1
fi

# Window Grid is AppKit-owned behavior, so exercise real visible NSWindows in
# addition to the pure recursive-layout tests: one/two/three placement, exact
# Window Inset gaps, animated reordering, and restoration when switched off.
WINDOW_GRID_HOME=$(mktemp -d "/tmp/$PRODUCT_SLUG-window-grid.XXXXXX")
mkdir -p "$WINDOW_GRID_HOME/config"
out=$(env HOME="$WINDOW_GRID_HOME" \
    CFFIXED_USER_HOME="$WINDOW_GRID_HOME" \
    "${PRODUCT_ENV_PREFIX}_CONFIG_DIR=$WINDOW_GRID_HOME/config" \
    "$BIN" --ui-test-window-grid 2>&1)
code=$?
rm -rf "$WINDOW_GRID_HOME"
if [ $code -eq 0 ] && grep -Fq "UIWINDOWGRID count=3 inset=10" <<< "$out" \
    && grep -Fq "initial=true" <<< "$out" \
    && grep -Fq "resize=true" <<< "$out" \
    && grep -Fq "compact=true" <<< "$out" \
    && grep -Fq "held=true" <<< "$out" \
    && grep -Fq "reorder=true" <<< "$out" \
    && grep -Fq "restore=true" <<< "$out" \
    && grep -Fq "ok=true" <<< "$out"; then
  echo "PASS  --ui-test-window-grid  native layout, held drag, reorder, and restore passed"
else
  echo "FAIL  --ui-test-window-grid"
  echo "$out" | tail -24
  FAIL=1
fi

# Five-window recursive grids animate several differently-sized neighbors at
# once. The original source must stay sticky, remain under the pointer through
# preview, and land in the exact nested target slot on release.
WINDOW_GRID_NESTED_HOME=$(mktemp -d "/tmp/$PRODUCT_SLUG-window-grid-nested.XXXXXX")
mkdir -p "$WINDOW_GRID_NESTED_HOME/config"
out=$(env HOME="$WINDOW_GRID_NESTED_HOME" \
    CFFIXED_USER_HOME="$WINDOW_GRID_NESTED_HOME" \
    "${PRODUCT_ENV_PREFIX}_CONFIG_DIR=$WINDOW_GRID_NESTED_HOME/config" \
    "$BIN" --ui-test-window-grid-nested 2>&1)
code=$?
rm -rf "$WINDOW_GRID_NESTED_HOME"
if [ $code -eq 0 ] && grep -Fq "UIWINDOWGRIDNESTED count=5" <<< "$out" \
    && grep -Fq "nested=true" <<< "$out" \
    && grep -Fq "source=true" <<< "$out" \
    && grep -Fq "held=true" <<< "$out" \
    && grep -Fq "reorder=true" <<< "$out" \
    && grep -Fq "frames=true" <<< "$out" \
    && grep -Fq "ok=true" <<< "$out"; then
  echo "PASS  --ui-test-window-grid-nested  five-window nested drag kept its source and exact target"
else
  echo "FAIL  --ui-test-window-grid-nested"
  echo "$out" | tail -24
  FAIL=1
fi

# Hammer native create/close faster than the grid animation duration. Only the
# newest topology may settle, and the survivor must reclaim the full screen.
WINDOW_GRID_STRESS_HOME=$(mktemp -d "/tmp/$PRODUCT_SLUG-window-grid-stress.XXXXXX")
mkdir -p "$WINDOW_GRID_STRESS_HOME/config"
out=$(env HOME="$WINDOW_GRID_STRESS_HOME" \
    CFFIXED_USER_HOME="$WINDOW_GRID_STRESS_HOME" \
    "${PRODUCT_ENV_PREFIX}_CONFIG_DIR=$WINDOW_GRID_STRESS_HOME/config" \
    "$BIN" --ui-test-window-grid-stress 2>&1)
code=$?
rm -rf "$WINDOW_GRID_STRESS_HOME"
if [ $code -eq 0 ] \
    && grep -Fq "UIWINDOWGRIDSTRESS pairs=10 burst=8" <<< "$out" \
    && grep -Fq "interleaved=true" <<< "$out" \
    && grep -Fq "peak=true" <<< "$out" \
    && grep -Fq "one=true" <<< "$out" \
    && grep -Fq "shells=true" <<< "$out" \
    && grep -Fq "shellCount=18" <<< "$out" \
    && grep -Fq "uniqueShellCount=18" <<< "$out" \
    && grep -Fq "fills=true" <<< "$out" \
    && grep -Fq "ok=true" <<< "$out"; then
  echo "PASS  --ui-test-window-grid-stress  rapid create/close settled and reaped every closed shell"
else
  echo "FAIL  --ui-test-window-grid-stress"
  echo "$out" | tail -30
  FAIL=1
fi

# Keep a dense Cmd-N burst alive. The last-created window must join the tree
# and reach its assigned tile without needing one more window to heal it.
WINDOW_GRID_ADD_HOME=$(mktemp -d "/tmp/$PRODUCT_SLUG-window-grid-add.XXXXXX")
mkdir -p "$WINDOW_GRID_ADD_HOME/config"
out=$(env HOME="$WINDOW_GRID_ADD_HOME" \
    CFFIXED_USER_HOME="$WINDOW_GRID_ADD_HOME" \
    "${PRODUCT_ENV_PREFIX}_CONFIG_DIR=$WINDOW_GRID_ADD_HOME/config" \
    "$BIN" --ui-test-window-grid-add-stress 2>&1)
code=$?
rm -rf "$WINDOW_GRID_ADD_HOME"
if [ $code -eq 0 ] \
    && grep -Fq "UIWINDOWGRIDADD count=32" <<< "$out" \
    && grep -Fq "participants=32" <<< "$out" \
    && grep -Fq "leaves=32" <<< "$out" \
    && grep -Fq "membership=true" <<< "$out" \
    && grep -Fq "frames=true" <<< "$out" \
    && grep -Fq "ok=true" <<< "$out"; then
  echo "PASS  --ui-test-window-grid-add-stress  dense add-only burst tiled its newest window"
else
  echo "FAIL  --ui-test-window-grid-add-stress"
  echo "$out" | tail -30
  FAIL=1
fi

# Convert a real three-pane split tree into three native grid windows and
# collapse it back. Pane IDs and shell PIDs must survive both directions, and
# the recursive axes/ratios must return unchanged.
WINDOW_GRID_CONVERT_HOME=$(mktemp -d "/tmp/$PRODUCT_SLUG-window-grid-convert.XXXXXX")
mkdir -p "$WINDOW_GRID_CONVERT_HOME/config"
out=$(env HOME="$WINDOW_GRID_CONVERT_HOME" \
    CFFIXED_USER_HOME="$WINDOW_GRID_CONVERT_HOME" \
    "${PRODUCT_ENV_PREFIX}_CONFIG_DIR=$WINDOW_GRID_CONVERT_HOME/config" \
    "$BIN" --ui-test-window-grid-conversion 2>&1)
code=$?
rm -rf "$WINDOW_GRID_CONVERT_HOME"
if [ $code -eq 0 ] \
    && grep -Fq "UIWINDOWGRIDCONVERT broke=true" <<< "$out" \
    && grep -Fq "grid=true" <<< "$out" \
    && grep -Fq "windows=1" <<< "$out" \
    && grep -Fq "panes=3" <<< "$out" \
    && grep -Fq "live=true" <<< "$out" \
    && grep -Fq "conversion=true" <<< "$out" \
    && grep -Fq "geometry=true" <<< "$out" \
    && grep -Fq "ok=true" <<< "$out"; then
  echo "PASS  --ui-test-window-grid-conversion  live splits and grid windows round-tripped exactly"
else
  echo "FAIL  --ui-test-window-grid-conversion"
  echo "$out" | tail -30
  FAIL=1
fi

# A deep 32-window tree forces the surviving host through many native resize
# callbacks while donors close. Reapply stored ratios through that settlement
# so balanced grid columns cannot collapse into right-edge slivers.
WINDOW_GRID_CONVERT_STRESS_HOME=$(mktemp -d "/tmp/$PRODUCT_SLUG-window-grid-convert-stress.XXXXXX")
mkdir -p "$WINDOW_GRID_CONVERT_STRESS_HOME/config"
out=$(env HOME="$WINDOW_GRID_CONVERT_STRESS_HOME" \
    CFFIXED_USER_HOME="$WINDOW_GRID_CONVERT_STRESS_HOME" \
    "${PRODUCT_ENV_PREFIX}_CONFIG_DIR=$WINDOW_GRID_CONVERT_STRESS_HOME/config" \
    "$BIN" --ui-test-window-grid-conversion-stress 2>&1)
code=$?
rm -rf "$WINDOW_GRID_CONVERT_STRESS_HOME"
if [ $code -eq 0 ] \
    && grep -Fq "UIWINDOWGRIDCONVERTSTRESS combined=true" <<< "$out" \
    && grep -Fq "windows=1" <<< "$out" \
    && grep -Fq "panes=32" <<< "$out" \
    && grep -Fq "geometry=true" <<< "$out" \
    && grep -Fq "balanced=true" <<< "$out" \
    && grep -Fq "live=true" <<< "$out" \
    && grep -Fq "ok=true" <<< "$out"; then
  echo "PASS  --ui-test-window-grid-conversion-stress  dense grid stayed balanced as exact live splits"
else
  echo "FAIL  --ui-test-window-grid-conversion-stress"
  echo "$out" | tail -30
  FAIL=1
fi

# The Extensions diagnostic must service the main run loop while external
# processes register commands over HTTP. A fixed main-thread sleep used to make
# this report an empty menu even though the child process was alive.
PLUGIN_CONFIG=$(mktemp -d "/tmp/$PRODUCT_SLUG-plugin-menu.XXXXXX")
mkdir -p "$PLUGIN_CONFIG/extensions"
cp -R Tests/Fixtures/plugin-menu-extension "$PLUGIN_CONFIG/extensions/menu-fixture"
out=$(env "${PRODUCT_ENV_PREFIX}_CONFIG_DIR=$PLUGIN_CONFIG" \
    "$BIN" --plugin-menu 2>&1)
code=$?
rm -rf "$PLUGIN_CONFIG"
plugin_ok=1
[ $code -eq 0 ] || plugin_ok=0
grep -Fq "▸ Menu Fixture" <<< "$out" || plugin_ok=0
grep -Fq "Fixture: One" <<< "$out" || plugin_ok=0
grep -Fq "Fixture: Two" <<< "$out" || plugin_ok=0
grep -Fq "Fixture: Three" <<< "$out" || plugin_ok=0
grep -Fq "● Menu Fixture: ready" <<< "$out" || plugin_ok=0
if [ $plugin_ok -eq 1 ]; then
  echo "PASS  --plugin-menu  authenticated Extension reached ready"
else
  echo "FAIL  --plugin-menu"
  echo "$out" | tail -20
  FAIL=1
fi

# App quit must not abandon an Extension that ignores SIGTERM. The fixture
# preserves its PID across exec, so the process must be gone when the bounded
# deactivate path returns.
STUBBORN_CONFIG=$(mktemp -d "/tmp/$PRODUCT_SLUG-plugin-stubborn.XXXXXX")
mkdir -p "$STUBBORN_CONFIG/extensions"
cp -R Tests/Fixtures/plugin-stubborn-extension \
    "$STUBBORN_CONFIG/extensions/stubborn-fixture"
out=$(env "${PRODUCT_ENV_PREFIX}_CONFIG_DIR=$STUBBORN_CONFIG" \
    "$BIN" --plugin-menu 2>&1)
code=$?
stubborn_pid=$(cat \
    "$STUBBORN_CONFIG/extensions/stubborn-fixture/stubborn.pid" 2>/dev/null \
    || true)
stubborn_alive=0
if [ -n "$stubborn_pid" ] && kill -0 "$stubborn_pid" 2>/dev/null; then
  stubborn_alive=1
  kill -KILL "$stubborn_pid" 2>/dev/null || true
fi
rm -rf "$STUBBORN_CONFIG"
if [ $code -eq 0 ] && [ -n "$stubborn_pid" ] \
    && [ $stubborn_alive -eq 0 ] \
    && grep -Fq "● Stubborn Fixture: ready" <<< "$out"; then
  echo "PASS  --plugin-menu  SIGTERM-resistant Extension was reaped on shutdown"
else
  echo "FAIL  --plugin-menu  SIGTERM-resistant Extension shutdown"
  echo "$out" | tail -20
  FAIL=1
fi

# Unexpected termination must survive process cleanup as a useful failure with
# both the exit status and a bounded final log line.
FAILURE_CONFIG=$(mktemp -d "/tmp/$PRODUCT_SLUG-plugin-failure.XXXXXX")
mkdir -p "$FAILURE_CONFIG/extensions"
cp -R Tests/Fixtures/plugin-failure-extension "$FAILURE_CONFIG/extensions/failure-fixture"
out=$(env "${PRODUCT_ENV_PREFIX}_CONFIG_DIR=$FAILURE_CONFIG" \
    "$BIN" --plugin-menu 2>&1)
code=$?
rm -rf "$FAILURE_CONFIG"
failure_ok=1
[ $code -ne 0 ] || failure_ok=0
grep -Fq "✗ Failure Fixture: failed: exited with status 7" <<< "$out" || failure_ok=0
grep -Fq "intentional fixture failure" <<< "$out" || failure_ok=0
if [ $failure_ok -eq 1 ]; then
  echo "PASS  --plugin-menu  failed Extension reports exit and log"
else
  echo "FAIL  --plugin-menu failure reporting"
  echo "$out" | tail -20
  FAIL=1
fi

exit $FAIL
