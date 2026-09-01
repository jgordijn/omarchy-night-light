#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BAR="$ROOT/BarWidget.qml"
PANEL="$ROOT/Panel.qml"
TIMELINE="$ROOT/DaylightTimeline.qml"
MOON_ICON="$ROOT/MoonPhaseIcon.qml"
TIMELINE_MODEL="$ROOT/TimelineModel.js"
MOON_MODEL="$ROOT/MoonModel.js"

fail() {
  printf 'source-contract-test: FAIL: %s\n' "$*" >&2
  exit 1
}

require_text() {
  local file=$1 pattern=$2 description=$3
  grep -Eq -- "$pattern" "$file" || fail "$description"
}

reject_text() {
  local file=$1 pattern=$2 description=$3
  if grep -Eq -- "$pattern" "$file"; then fail "$description"; fi
}

require_multiline() {
  local file=$1 pattern=$2 description=$3
  grep -Pzq -- "$pattern" "$file" || fail "$description"
}

reject_multiline() {
  local file=$1 pattern=$2 description=$3
  if grep -Pzq -- "$pattern" "$file"; then fail "$description"; fi
}

[[ -f $BAR && -f $PANEL ]] || fail "BarWidget.qml and Panel.qml are required"
for artifact in "$TIMELINE" "$MOON_ICON" "$TIMELINE_MODEL" "$MOON_MODEL"; do
  [[ -f $artifact ]] || fail "Wave 3 package artifact is missing: $(basename "$artifact")"
done

require_text "$BAR" '^BarWidget[[:space:]]*\{' "BarWidget.qml must extend qs.Ui.BarWidget"
require_text "$BAR" 'moduleName:[[:space:]]*"jgordijn\.night-light"' "bar widget must use the canonical module id"
require_text "$BAR" 'serviceFor\("jgordijn\.night-light"\)' "bar widget must resolve the singleton service"
for symbol in 'readonly property bool opened' 'function open\(' 'function close\(' \
              'function closeForPopoutSwitch\(' 'readonly property bool popoutSwitchClosing'; do
  require_text "$BAR" "$symbol" "bar widget is missing Clock ownership member: $symbol"
done
for injection in 'target\.bar = root\.bar' 'target\.settings = root\.settings' \
                 'target\.anchorItem = button' 'target\.hostWidget = root'; do
  require_text "$BAR" "$injection" "bar widget is missing nested-panel injection: $injection"
done
require_text "$BAR" 'fixedWidth: root\.vertical \? -1 : Style\.space\(76\)' "horizontal pill must have stable native width"
require_text "$BAR" 'fixedHeight: root\.vertical \? Style\.bar\.iconSlot : -1' "vertical bar must use one icon slot"
require_text "$BAR" 'openPanelIndicatorWidth' "bar widget must hint the Clock-style horizontal accent"
require_text "$BAR" 'openPanelIndicatorHeight' "bar widget must hint the Clock-style vertical accent"
require_text "$BAR" 'Qt\.RightButton' "bar widget must implement right click"
require_text "$BAR" 'Qt\.MiddleButton' "bar widget must implement middle click"
require_text "$BAR" 'Accessible\.name' "bar affordance must have an accessible name"

require_text "$PANEL" '^Panel[[:space:]]*\{' "Panel.qml must extend qs.Ui.Panel"
require_text "$PANEL" 'readonly property var barIdentity: hostWidget \|\| root' "panel must use the host widget as popout identity"
require_text "$PANEL" 'owner: root\.barIdentity' "KeyboardPanel owner must be the host widget"
require_text "$PANEL" 'switchPanelFrom\(root\.barIdentity, direction\)' "Tab handoff must use the host widget identity"
require_text "$PANEL" 'anchorItem:[[:space:]]*root\.anchorItem' "KeyboardPanel must receive the actual injected WidgetButton"
require_text "$PANEL" 'centerOnBar:[[:space:]]*false' "Night Light panel must use installed edge-aware icon anchoring"
reject_text "$PANEL" 'centerOnBar:[[:space:]]*true' "Night Light panel must not center itself on the screen/bar"
require_text "$PANEL" 'fittedContentWidth\(root\.nominalContentWidth\)' "panel width must use the stable fitted contract"
require_text "$PANEL" 'normalPanelContentHeight:[[:space:]]*panel\.cappedContentHeight\(nominalContentHeight\)' "normal dashboard must retain its stable full height"
require_text "$PANEL" 'readonly property Item activeEditorColumn' "editor height must select one active composition"
require_text "$PANEL" 'editorHeaderImplicitHeight:[[:space:]]*editorTitleLabel\.implicitHeight[[:space:]]*\+' "editor height must include the title/detail/separator chrome"
require_text "$PANEL" 'activeEditorImplicitHeight:[[:space:]]*activeEditorColumn[[:space:]]*\?[[:space:]]*activeEditorColumn\.implicitHeight' "editor height must bind directly to the active mode"
require_text "$PANEL" 'editorCompositionImplicitHeight:[[:space:]]*activeEditorColumn' "editor height must compose active chrome/body geometry"
require_text "$PANEL" 'editorHeaderImplicitHeight[[:space:]]*\+[[:space:]]*activeEditorImplicitHeight[[:space:]]*\+[[:space:]]*editorColumn\.spacing[[:space:]]*\*[[:space:]]*3' "editor height must account for all three outer gaps"
require_text "$PANEL" 'editorPanelContentHeight:[[:space:]]*panel\.fittedContentHeight\(editorCompositionImplicitHeight, nominalContentHeight\)' "editor composition must receive native panel insets and the dashboard cap"
reject_text "$PANEL" 'fittedContentHeight\(editorColumn\.implicitHeight' "editor height must not inherit hidden/max editorColumn geometry"
require_text "$PANEL" 'onEditorModeChanged:' "every editor mode switch must force relayout"
require_text "$PANEL" 'activeColumn\.forceLayout\(\)' "the active editor composition must be polished explicitly"
require_text "$PANEL" 'function editorHeightSnapshot\(' "runtime tests must be able to capture actual editor card geometry"
require_text "$PANEL" 'contentHeight:[[:space:]]*root\.targetPanelContentHeight' "panel must switch between stable dashboard and fitted editor heights"
require_text "$PANEL" 'PanelKeyCatcher' "panel must use native keyboard dispatch"
require_text "$PANEL" 'PanelActionButton' "panel must use native icon actions"
require_text "$PANEL" 'TextField' "manual location must use the native text field"
require_text "$PANEL" 'CursorSurface' "roving focus must use native cursor chrome"
require_text "$PANEL" 'Border\.' "panel must use native borders"
require_text "$PANEL" 'Color\.' "panel must use the native palette"
require_text "$PANEL" 'Style\.' "panel must use scaled native geometry"
require_text "$PANEL" 'text:[[:space:]]*"via " \+ root\.sourceBadge' "location source must follow the location as inline provenance"
require_text "$PANEL" 'font\.italic:[[:space:]]*true' "inline location provenance must be italic"
reject_text "$PANEL" 'id:[[:space:]]*sourcePill' "location provenance must not look like an interactive pill"
require_text "$PANEL" 'updateEntryInline\(root\.moduleName, entry\)' "settings must persist through the shell inline-entry API"
require_text "$PANEL" 'root\.hostWidget\.settings = entry' "settings must update the host immediately"
require_text "$PANEL" 'root\.settings = entry' "settings must update visible controls immediately"
require_text "$PANEL" 'service\.stepNightTemperature\(direction\)' "Warmth steps must use the sole Service writer"
require_text "$PANEL" 'syncSettingsFromService\(\)' "successful Warmth steps must copy canonical Service settings immediately"
require_text "$PANEL" 'Saved automatically · Live during automatic warmth' "Warmth persistence/live behavior copy is missing"
reject_text "$PANEL" 'persistSettings\(\{[[:space:]]*nightTemperature:' "Panel must not persist Warmth directly"
require_text "$PANEL" 'existing !== "nightTemperature"' "generic Panel persistence must not merge stale local Warmth"
require_text "$PANEL" 'key !== "id" && key !== "nightTemperature"' "generic Panel changes must not write Warmth"
require_text "$PANEL" 'canonicalTemperature = serviceEntry \? serviceEntry\.nightTemperature' "generic Panel persistence must restore canonical Service Warmth"
reject_text "$PANEL" 'entry\.nightTemperature[[:space:]]*=[[:space:]]*root\.settings' "Panel must never source a Warmth write from local settings"
require_text "$PANEL" 'Behavior on contentHeight' "fitted editor height changes must be animated"
require_text "$PANEL" 'animateEditorHeight = false' "dashboard restoration must bypass partial-height clipping"
require_text "$PANEL" 'panelHeightAnimation\.stop\(\)' "dashboard restoration must stop an in-flight editor contraction"
require_text "$PANEL" 'duration: 140; easing\.type: Easing\.OutCubic' "content and height transitions must use 140 ms OutCubic"
require_text "$PANEL" 'enabled:[[:space:]]*root\.editorMode === "normal"' "fading dashboard must stop pointer handling in editors"
require_text "$PANEL" 'enabled:[[:space:]]*root\.editorMode !== "normal"' "fading editors must stop pointer handling on the dashboard"
require_text "$PANEL" 'scrollFocusedEditorControl' "editor keyboard focus must remain visible in capped panels"
require_text "$PANEL" 'duration: 160; easing\.type: Easing\.OutCubic' "value transitions must use 160 ms OutCubic"
require_text "$PANEL" 'DaylightTimeline[[:space:]]*\{' "dashboard must instantiate the reusable civil timeline"
require_text "$PANEL" 'snapshot:[[:space:]]*root\.timelineSnapshot' "Timeline must receive the complete atomic Service snapshot"
require_text "$PANEL" 'moonPhase:[[:space:]]*root\.moonPhaseSnapshot' "Timeline must receive the complete lunar Service snapshot"
require_text "$PANEL" 'timelineSnapshot:[[:space:]]*serviceValue\("timeline", null\)' "Panel must consume the Service timeline directly"
require_text "$PANEL" 'timelineDisplayTimes:[[:space:]]*timelineSnapshot' "hero display times must stay in the timeline transaction"
require_text "$PANEL" 'formatProjectedTime\(projectedDisplayTime\("sunset"\)' "sunset hero copy must use projected displayTimes"
require_text "$PANEL" 'formatProjectedTime\(projectedDisplayTime\("sunrise"\)' "sunrise hero copy must use projected displayTimes"
require_text "$PANEL" 'var wall = new Date\(1970, 0, 1, hours, minutes, seconds, milliseconds\)' "projected labels must format civil wall fields only"
reject_text "$PANEL" 'Qt\.formatTime\(new Date\(value\)' "Panel must not format schedule epochs in the shell timezone"
reject_text "$PANEL" 'railProgress|id:[[:space:]]*railTrack|text:[[:space:]]*"SUNSET|text:[[:space:]]*"SUNRISE' "old sunset-to-sunrise static rail must be removed"

# Exact normal roving order: Timeline, Automatic, Warmth, Transition, primary,
# Location, Forget. Automatic remains initial when the panel opens.
require_text "$PANEL" 'root\.focusIndex = 1' "open must initially focus Automatic"
require_text "$PANEL" 'if \(focusIndex === 0\) item = daylightTimeline' "Timeline must lead normal roving order"
require_text "$PANEL" 'else if \(focusIndex === 1\) item = automaticRow' "Automatic must follow Timeline"
require_text "$PANEL" 'else if \(focusIndex === 2\) item = warmthRow' "Warmth roving index changed"
require_text "$PANEL" 'else if \(focusIndex === 3\) item = transitionRow' "Transition roving index changed"
require_text "$PANEL" 'else if \(focusIndex === 4\) item = primaryAction' "primary action roving index changed"
require_text "$PANEL" 'else if \(focusIndex === 5\) item = locationAction' "Location roving index changed"
require_text "$PANEL" 'hasCursor:[[:space:]]*root\.focusIndex === 6' "Forget must end normal roving order"
require_text "$PANEL" 'daylightTimeline\.moveSelection\(direction\)' "Timeline Left/Right selection routing is missing"
require_text "$PANEL" 'daylightTimeline\.activateSelection\(\)' "Timeline Enter/Space activation routing is missing"
require_text "$PANEL" 'daylightTimeline\.clearPin\(\)' "panel close must clear the Timeline pin"
require_text "$PANEL" 'onFocusRequested:[[:space:]]*root\.setFocus\(0\)' "Timeline pointer entry must join roving focus"
require_text "$PANEL" 'sourceRowControl:[[:space:]]*sourceRow' "integration tests need the real source-row collision bound"
require_text "$PANEL" 'automaticRowControl:[[:space:]]*automaticRow' "integration tests need the real Automatic-row collision bound"
require_text "$TIMELINE" '_detailLaneHeight:[[:space:]]*height / 2' "event detail must reserve explicit lanes inside the fixed slot"
require_multiline "$TIMELINE" 'Item\s*\{\s*id:\s*eventTarget\b' "event hit targets must use a non-painting Item"
reject_multiline "$TIMELINE" 'BorderSurface\s*\{\s*id:\s*eventTarget\b' "event hit targets must not paint a small rectangular focus box"
require_text "$TIMELINE" 'font\.bold:[[:space:]]*eventDelegate\.selected && root\.current' "selected arrows need a non-color-only keyboard distinction"
require_multiline "$TIMELINE" 'BorderSurface\s*\{\s*id:\s*focusChrome\b' "whole-row keyboard focus chrome must be retained"
require_text "$TIMELINE" '_detailAvailableWidth\(eventX\)' "event detail must choose bounded horizontal space beside its target"
require_text "$TIMELINE" 'return event && event\.kind === "sunrise" \? 0 : height - heightValue' "sunrise/sunset detail must remain in internal upper/lower lanes"
require_text "$TIMELINE" 'width:[[:space:]]*Math\.min\(naturalWidth, root\._detailAvailableWidth\(eventX\)\)' "pinned detail must stay horizontally bounded"
require_text "$ROOT/test/qml-entrypoints-test.sh" 'detail remains wholly inside the fixed Timeline slot' "entrypoint test must assert full Panel detail bounds"
require_text "$ROOT/test/qml-entrypoints-test.sh" 'detail does not obscure the source row' "entrypoint test must cover source-row collisions"
require_text "$ROOT/test/qml-entrypoints-test.sh" 'detail does not obscure Automatic/On' "entrypoint test must cover Automatic-row collisions"

for copy in \
  'Choose a location' \
  'Night Light is unavailable' \
  'The last display setting was left unchanged\.' \
  'Search uses Open-Meteo only while this editor is open\.' \
  'City or 52\.27115, 5\.13729' \
  'No matching localities\.' \
  'Couldn’t search\. Check your connection and try again\.' \
  'Search is temporarily rate limited\. Try again later\.' \
  'Use approximate location\?' \
  'No IP address or response history is saved\.' \
  'This may be wrong when using a VPN or proxy\.' \
  'Forget Night Light location\?' \
  'Omarchy Weather is unchanged\.' \
  'One Night Light shortcut' \
  'Hide stock shortcut'; do
  require_text "$PANEL" "$copy" "required truthful UI copy is missing: $copy"
done

for key in 'event\.text === "n"' 'event\.text === "a"' 'event\.text === "l"' 'Qt\.Key_Tab' \
           'Qt\.Key_Escape' 'Qt\.Key_Return' 'Qt\.Key_Enter' 'Qt\.Key_Space'; do
  require_text "$PANEL" "$key" "keyboard contract is missing: $key"
done
require_text "$PANEL" 'function handleNormalKey\(event\)' "normal mode must own its conflict-free keyboard map"
require_text "$PANEL" 'focusTarget: root\.editorMode === "normal" \? keyCatcher : editorKeys' "normal mode must focus its conflict-free direct key target"
require_text "$PANEL" 'id: keyCatcher' "normal mode must retain a dedicated key target"
require_text "$PANEL" 'Keys\.onPressed: function\(event\)' "the focused target must own normal key handling"
require_text "$PANEL" 'if \(root\.editorMode === "normal"\) root\.handleNormalKey\(event\)' "the focused target must route keys through the conflict-free handler"
reject_text "$PANEL" 'PanelKeyCatcher[[:space:]]*\{' "normal mode must not reintroduce the native l/right conflict"
require_text "$PANEL" 'else if \(event\.key === Qt\.Key_Right\) root\.moveFocus\(1, 0\)' "normal Right must adjust without consuming the Location shortcut"
require_text "$PANEL" 'else if \(event\.text === "l" \|\| event\.text === "L"\) root\.showEditor\("location"\)' "normal l must open Location"
require_text "$PANEL" 'Accessible\.name' "panel controls must expose accessible names"
require_text "$PANEL" 'Math\.max\(Style\.space\(28\), Style\.spacing\.controlHeight\)' "small icon actions must retain at least a scaled 28 logical-pixel target"
require_text "$PANEL" 'height: Style\.space\(4[048]\)' "primary control rows must retain at least a scaled 40 logical-pixel target"

# The UI may mention providers in disclosure copy, but must not own I/O or clocks.
for file in "$BAR" "$PANEL"; do
  reject_text "$file" '^[[:space:]]*(Timer|SystemClock|ElapsedTimer|Process|FileView|IpcHandler)[[:space:]]*\{' "$(basename "$file") must not own timers, processes, files, or IPC"
  reject_text "$file" 'XMLHttpRequest|\.running[[:space:]]*=|execDetached|/usr/bin/|bash -[cl]|hyprctl' "$(basename "$file") contains forbidden business/backend I/O"
done

printf 'source-contract-test: PASS\n'
