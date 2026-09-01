#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BAR="$ROOT/BarWidget.qml"
PANEL="$ROOT/Panel.qml"

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

[[ -f $BAR && -f $PANEL ]] || fail "BarWidget.qml and Panel.qml are required"

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
require_text "$PANEL" 'centerOnBar: true' "Night Light panel must center on the bar"
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
require_text "$PANEL" 'updateEntryInline\(root\.moduleName, entry\)' "settings must persist through the shell inline-entry API"
require_text "$PANEL" 'root\.hostWidget\.settings = entry' "settings must update the host immediately"
require_text "$PANEL" 'root\.settings = entry' "settings must update visible controls immediately"
require_text "$PANEL" 'Behavior on contentHeight' "fitted editor height changes must be animated"
require_text "$PANEL" 'animateEditorHeight = false' "dashboard restoration must bypass partial-height clipping"
require_text "$PANEL" 'panelHeightAnimation\.stop\(\)' "dashboard restoration must stop an in-flight editor contraction"
require_text "$PANEL" 'duration: 140; easing\.type: Easing\.OutCubic' "content and height transitions must use 140 ms OutCubic"
require_text "$PANEL" 'enabled:[[:space:]]*root\.editorMode === "normal"' "fading dashboard must stop pointer handling in editors"
require_text "$PANEL" 'enabled:[[:space:]]*root\.editorMode !== "normal"' "fading editors must stop pointer handling on the dashboard"
require_text "$PANEL" 'scrollFocusedEditorControl' "editor keyboard focus must remain visible in capped panels"
require_text "$PANEL" 'duration: 160; easing\.type: Easing\.OutCubic' "rail/value transitions must use 160 ms OutCubic"

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
require_text "$PANEL" 'focusTarget: root\.editorMode === "normal" \? normalKeys : editorKeys' "normal mode must focus its conflict-free child key target"
require_text "$PANEL" 'id: normalKeys' "the native host must contain a dedicated normal key target"
require_text "$PANEL" 'Keys\.onPressed: function\(event\) \{ root\.handleNormalKey\(event\) \}' "the focused child must route keys through the conflict-free handler"
require_text "$PANEL" 'id: keyCatcher' "the native semantic content host must remain present"
require_text "$PANEL" 'focus: false' "the native host itself must not compete with its focused child"
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
