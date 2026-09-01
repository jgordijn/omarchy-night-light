#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=""
QS_PID=""

fail() {
  printf 'qml-entrypoints-test: FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n ${QS_PID:-} ]] && kill -0 "$QS_PID" 2>/dev/null; then
    kill "$QS_PID" 2>/dev/null || true
    wait "$QS_PID" 2>/dev/null || true
  fi
  [[ -z ${TMP:-} ]] || rm -rf -- "$TMP"
}
trap cleanup EXIT

command -v quickshell >/dev/null 2>&1 || fail "quickshell is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"
[[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] || fail "a running Hyprland compositor is required"
hyprctl monitors >/dev/null 2>&1 || fail "the Hyprland compositor is not reachable"

TMP=$(mktemp -d)
CONFIG="$TMP/night-light-qml"
RESULT="$TMP/result.json"
LOG="$TMP/quickshell.log"
mkdir -p "$CONFIG" "$TMP/home"
ln -s /usr/share/omarchy/shell/Ui "$CONFIG/Ui"
ln -s /usr/share/omarchy/shell/Commons "$CONFIG/Commons"

cat >"$CONFIG/shell.qml" <<'QML'
import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons

ShellRoot {
  id: root

  readonly property string resultPath: Quickshell.env("NIGHT_LIGHT_QML_RESULT")
  readonly property string widgetUrl: Quickshell.env("NIGHT_LIGHT_WIDGET_URL")
  property var failures: []
  property var widget: null
  property int settingsWrites: 0
  property int switchCalls: 0
  property var heightCaptures: ({})
  property var afterSettleCallback: null

  function fail(message) { failures.push(String(message)) }
  function check(condition, message) { if (!condition) fail(message) }
  function equal(actual, expected, message) {
    if (actual !== expected) fail(message + " expected=" + expected + " actual=" + actual)
  }
  function finite(value) { return isFinite(Number(value)) && Number(value) >= 0 }

  function captureEditorHeight(name, panel) {
    heightCaptures[name] = panel.editorHeightSnapshot()
  }

  function afterEditorSettle(callback) {
    afterSettleCallback = callback
    editorSettleTimer.restart()
  }

  function finish() {
    var payload = JSON.stringify({ ok: failures.length === 0, failures: failures,
                                   editorHeights: heightCaptures })
    Quickshell.execDetached(["/usr/bin/python", "-c",
      "import sys; open(sys.argv[1], 'w').write(sys.argv[2])", resultPath, payload])
  }

  function finishRuntimeChecks(widget, nightPanel, dashboardHeight) {
    nightPanel.cancelEditor(true)
    equal(nightPanel.targetPanelContentHeight, dashboardHeight, "normal dashboard target does not inherit editor height")
    equal(nightPanel.keyboardPanel.contentHeight, dashboardHeight, "dashboard restores at full height without clipped expansion")
    var positions = ["top", "bottom", "left", "right"]
    for (var i = 0; i < positions.length; i++) {
      fakeBar.position = positions[i]
      fakeBar.vertical = positions[i] === "left" || positions[i] === "right"
      fakeBar.barSize = fakeBar.vertical ? Style.bar.sizeVertical : Style.bar.sizeHorizontal
      check(finite(widget.implicitWidth) && finite(widget.implicitHeight), positions[i] + " bar geometry remains finite")
      check(finite(nightPanel.keyboardPanel.cardOrigin.x) && finite(nightPanel.keyboardPanel.cardOrigin.y), positions[i] + " panel origin remains finite")
      check(nightPanel.keyboardPanel.contentWidth > 0 && nightPanel.keyboardPanel.contentWidth <= nightPanel.nominalContentWidth, positions[i] + " panel width stays fitted and bounded")
      check(nightPanel.keyboardPanel.contentHeight > 0 && nightPanel.keyboardPanel.contentHeight <= nightPanel.nominalContentHeight, positions[i] + " panel height stays fitted and bounded")
      if (fakeBar.vertical) equal(widget.implicitHeight, Style.bar.iconSlot, positions[i] + " uses one vertical icon slot")
    }
    fakeBar.position = "top"
    fakeBar.vertical = false
    fakeBar.barSize = Style.bar.sizeHorizontal
    nightPanel.switchPanel(1)
    equal(switchCalls, 1, "panel handoff uses bar switch routing")
    widget.closeForPopoutSwitch()
    check(!widget.opened, "handoff close forwards immediately")

    fakeService.mode = "override"
    fakeService.phase = "night"
    fakeService.actual = ({ kind: "temperature", temperature: 4100, gamma: 100 })
    fakeService.overrideUntil = fakeService.sunrise
    Qt.callLater(function() {
      check(widget.overridden, "override has a non-color-only state")
      equal(widget.barLabel, "4.1k", "override shows the adopted actual temperature")
      equal(nightPanel.stateTitle, "Manual override", "override panel copy")
      fakeService.available = false
      fakeService.error = ({ code: "backend-unavailable", message: "test" })
      Qt.callLater(function() {
        equal(widget.barLabel, "ERR", "backend failure stays visible")
        equal(nightPanel.stateTitle, "Night Light is unavailable", "backend error panel copy")
        widget.destroy()
        finish()
      })
    })
  }

  Timer {
    id: editorSettleTimer
    interval: 220
    repeat: false
    onTriggered: {
      var callback = root.afterSettleCallback
      root.afterSettleCallback = null
      if (callback) callback()
    }
  }

  QtObject {
    id: fakeService
    property var settings: ({ automationEnabled: true, nightTemperature: 4000, transitionMinutes: 45,
                              stockIndicator: { choice: "keep", before: null, after: null } })
    property bool initialized: true
    property bool busy: false
    property bool available: true
    property string mode: "scheduled"
    property string phase: "day"
    property var actual: ({ kind: "identity", temperature: 6500, gamma: 100 })
    property var target: ({ kind: "identity", temperature: 6500 })
    property var location: ({ mode: "weather", source: "weather", label: "Hilversumse Meent",
                              precision: "selected-locality", stale: false, observedAt: "2026-09-01T10:00:00Z" })
    property var privateLocationState: ({ autoConsentVersion: 0, weatherCache: ({ label: "Hilversumse Meent", source: "weather" }) })
    property real sunset: 1788285600000
    property real sunrise: 1788325200000
    property real nextBoundary: sunset
    property real overrideUntil: 0
    property var error: null
    property var searchResults: []
    property var automaticCandidate: null
    property bool locationEditorOpen: false
    property bool _networkBusy: false
    property var _networkError: null
    property var _weatherRead: ({ ok: true, location: ({ label: "Hilversumse Meent", source: "weather" }) })
    property int warmCalls: 0
    property int daylightCalls: 0
    property int resumeCalls: 0
    property int refreshCalls: 0
    property int openEditorCalls: 0
    property int closeEditorCalls: 0
    property int manualQueryCalls: 0
    property int weatherCalls: 0
    property int autoConsentCalls: 0
    property int autoRefreshCalls: 0
    property int autoAcceptCalls: 0
    property int forgetCalls: 0
    property int stockKeepCalls: 0
    property int stockHideCalls: 0
    function warm() { warmCalls++; return true }
    function daylight() { daylightCalls++; return true }
    function resume() { resumeCalls++; return true }
    function refresh() { refreshCalls++; return true }
    function openLocationEditor() { openEditorCalls++; locationEditorOpen = true }
    function closeLocationEditor() { closeEditorCalls++; locationEditorOpen = false }
    function setManualQuery(value, language) { manualQueryCalls++; return ({}) }
    function useManualCoordinates(value) { return true }
    function commitManualLocation(value) { return true }
    function useWeatherLocation() { weatherCalls++; return true }
    function consentAutomaticLocation() { autoConsentCalls++; return true }
    function refreshAutomaticLocation() { autoRefreshCalls++; return true }
    function acceptAutomaticCandidate() { autoAcceptCalls++; return true }
    function forgetLocation(confirm) { if (confirm === "confirm") forgetCalls++; return confirm === "confirm" }
    function keepStockIndicator() { stockKeepCalls++; return true }
    function hideStockIndicator(items) { stockHideCalls++; return items.indexOf("NightLight") >= 0 }
    function restoreStockIndicator() { return "not-hidden" }
  }

  QtObject {
    id: fakeShell
    property var shellConfig: ({ bar: { layout: { left: [], center: [], right: [{ id: "omarchy.indicators" }] } } })
    function serviceFor(id) { return id === "jgordijn.night-light" ? fakeService : null }
    function updateEntryInline(id, entry) { root.settingsWrites++; return true }
  }

  QtObject {
    id: fakeBar
    property bool vertical: false
    property int barSize: Style.bar.sizeHorizontal
    property string position: "top"
    property string fontFamily: "monospace"
    property color foreground: "#eeeeee"
    property color barForeground: foreground
    property color background: "#111111"
    property color urgent: "#dd6666"
    property bool foregroundAnimationEnabled: false
    property bool centerHoverRevealSuppressed: false
    property var shell: fakeShell
    property var activePopout: null
    property var clickTargets: []
    function requestPopout(owner) { activePopout = owner }
    function releasePopout(owner) { if (activePopout === owner) activePopout = null }
    function switchPanelFrom(owner, direction) { root.switchCalls++; return true }
    function registerClickTarget(target) {}
    function unregisterClickTarget(target) {}
    function showTooltip(target, text) {}
    function hideTooltip(target) {}
    function moduleWidgets(id) { return root.widget ? [root.widget] : [] }
  }

  PanelWindow {
    id: barWindow
    visible: true
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "night-light-qml-test-bar"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    anchors { top: true; left: true; right: true }
    implicitHeight: Style.bar.sizeHorizontal

    Item {
      id: host
      width: Style.space(100)
      height: Style.bar.sizeHorizontal
      anchors.right: parent.right
    }
  }

  Timer {
    interval: 1
    running: true
    repeat: false
    onTriggered: {
      var component = Qt.createComponent(root.widgetUrl, Component.PreferSynchronous)
      check(component.status === Component.Ready, "BarWidget component loads: " + component.errorString())
      if (component.status !== Component.Ready) { finish(); return }

      widget = component.createObject(host, { settings: ({}) })
      check(widget !== null, "BarWidget instantiates without an injected bar")
      if (!widget) { finish(); return }
      check(widget.bar === null, "bar starts uninjected")
      widget.bar = fakeBar
      check(widget.bar === fakeBar, "bar accepts delayed injection")

      Qt.callLater(function() {
        var nightPanel = widget.nestedPanel
        check(nightPanel !== null, "nested Panel.qml loads")
        check(finite(widget.implicitWidth) && finite(widget.implicitHeight), "bar geometry is finite")
        equal(widget.barLabel, "DAY", "day bar hierarchy")
        equal(nightPanel.stateTitle, "Daylight", "day panel copy")
        equal(nightPanel.nominalContentWidth, Style.space(520), "nominal panel width")
        equal(nightPanel.nominalContentHeight, Style.space(440), "nominal panel height")
        check(nightPanel.keyboardPanel.owner === widget, "KeyboardPanel owner is host widget")
        check(nightPanel.keyboardPanel.anchorItem !== null, "actual WidgetButton is the anchor")

        fakeService.initialized = false
        equal(widget.barLabel, "…", "loading remains visible and truthful")
        equal(nightPanel.stateTitle, "Loading Night Light", "loading panel copy")
        fakeService.initialized = true
        fakeService.mode = "setup"
        fakeService.phase = "setup"
        fakeService.location = null
        equal(widget.barLabel, "SET", "setup remains visible")
        equal(nightPanel.stateTitle, "Choose a location", "setup panel copy")

        fakeService.mode = "scheduled"
        fakeService.location = ({ mode: "weather", source: "weather", label: "Hilversumse Meent",
                                  precision: "selected-locality", stale: false, observedAt: "2026-09-01T10:00:00Z" })
        fakeService.phase = "evening-transition"
        fakeService.actual = ({ kind: "temperature", temperature: 4800, gamma: 100 })
        equal(widget.barLabel, "4.8k", "transition uses actual verified temperature")
        equal(nightPanel.stateTitle, "Warming", "evening panel copy")
        fakeService.phase = "night"
        equal(nightPanel.stateTitle, "Night light", "night panel copy")
        fakeService.phase = "morning-transition"
        equal(nightPanel.stateTitle, "Cooling", "morning panel copy")
        fakeService.phase = "polar-day"
        equal(nightPanel.stateTitle, "Midnight sun", "polar-day panel copy")
        fakeService.phase = "polar-night"
        equal(nightPanel.stateTitle, "Polar night", "polar-night panel copy")
        fakeService.phase = "day"
        fakeService.actual = ({ kind: "identity", temperature: 6500, gamma: 100 })

        widget.toggleManual()
        equal(fakeService.warmCalls, 1, "right-click action uses service warmth")
        widget.resumeAutomatic()
        equal(fakeService.resumeCalls, 0, "middle-click is a no-op while automatic")

        nightPanel.persistSettings({ nightTemperature: 4250 })
        equal(widget.settings.nightTemperature, 4250, "settings update host immediately")
        equal(nightPanel.settings.nightTemperature, 4250, "settings update panel immediately")
        equal(root.settingsWrites, 1, "settings persist through updateEntryInline")
        nightPanel.stepWarmth(1)
        nightPanel.stepTransition(1)
        check(root.settingsWrites >= 3, "keyboard value changes persist complete transactions")

        var dashboardTargetHeight = nightPanel.targetPanelContentHeight
        equal(dashboardTargetHeight, nightPanel.normalPanelContentHeight, "normal dashboard keeps its composed height")

        var locationShortcut = ({ key: 0, text: "l", modifiers: 0, accepted: false })
        nightPanel.handleNormalKey(locationShortcut)
        equal(locationShortcut.accepted, true, "location shortcut consumes the key")
        equal(fakeService.openEditorCalls, 1, "l opens the service location editor")
        equal(nightPanel.editorTitle(), "Location", "location chooser renders in fitted viewport")
        check(nightPanel.targetPanelContentHeight < dashboardTargetHeight, "location editor removes the empty lower canvas")
        check(nightPanel.targetPanelContentHeight === nightPanel.editorPanelContentHeight, "location editor height follows laid-out content")
        var locationTargetHeight = nightPanel.targetPanelContentHeight

        nightPanel.showEditor("manual")
        equal(nightPanel.editorTitle(), "Manual location", "manual editor renders")
        check(nightPanel.targetPanelContentHeight < locationTargetHeight, "sparse manual editor fits more closely than location choices (location=" + locationTargetHeight + ", manual=" + nightPanel.targetPanelContentHeight + ")")
        check(nightPanel.targetPanelContentHeight > 0, "manual editor retains a usable viewport")
        var sparseManualHeight = nightPanel.targetPanelContentHeight
        fakeService.searchResults = [
          ({ label: "One" }), ({ label: "Two" }), ({ label: "Three" }),
          ({ label: "Four" }), ({ label: "Five" })
        ]
        nightPanel.forceEditorLayout()
        check(nightPanel.targetPanelContentHeight > sparseManualHeight, "manual results grow the fitted editor")
        check(nightPanel.targetPanelContentHeight <= dashboardTargetHeight, "manual results stay capped to the dashboard maximum")
        check(nightPanel.editorViewport.contentHeight > nightPanel.editorViewport.height,
          "overflowing manual results retain a scrollable narrow-screen viewport")
        fakeService.searchResults = []

        nightPanel.showEditor("consent")
        equal(nightPanel.editorTitle(), "Use approximate location?", "consent disclosure state renders")
        check(nightPanel.targetPanelContentHeight < dashboardTargetHeight, "consent disclosure fits its content")
        nightPanel.showEditor("forget")
        equal(nightPanel.editorTitle(), "Forget Night Light location?", "forget confirmation state renders")
        check(nightPanel.targetPanelContentHeight < dashboardTargetHeight, "forget confirmation fits its content")
        nightPanel.showEditor("stock")
        equal(nightPanel.editorTitle(), "One Night Light shortcut", "first-run setup choice renders")
        check(nightPanel.targetPanelContentHeight < dashboardTargetHeight, "first-run setup choice fits its content")

        fakeService.automaticCandidate = ({ location: ({ label: "Elsewhere" }), assessment: ({ changed: true }) })
        nightPanel.showEditor("auto")
        equal(nightPanel.editorTitle(), "Approximate location changed", "large automatic jump requires review")
        check(nightPanel.targetPanelContentHeight <= dashboardTargetHeight, "automatic review remains capped to dashboard height")
        nightPanel.cancelEditor(true)
        equal(nightPanel.targetPanelContentHeight, dashboardTargetHeight, "leaving editors restores stable dashboard height")
        equal(fakeService.closeEditorCalls, 1, "cancel closes service editor and drafts")

        widget.open()
        check(widget.opened, "open forwards to nested panel")
        check(fakeBar.activePopout === widget, "open claims popout as host widget")
        var fixedWidth = nightPanel.keyboardPanel.contentWidth
        var dashboardHeight = nightPanel.targetPanelContentHeight
        heightCaptures.dashboard = ({ mode: "normal", target: dashboardHeight,
                                      actual: nightPanel.keyboardPanel.contentHeight })
        nightPanel.showEditor("location")
        equal(nightPanel.keyboardPanel.contentWidth, fixedWidth, "editor keeps stable panel width")
        check(nightPanel.targetPanelContentHeight < dashboardHeight, "open location editor requests a fitted height")
        check(nightPanel.keyboardPanel.contentHeight >= nightPanel.targetPanelContentHeight,
          "height transition never undershoots fitted location content")

        afterEditorSettle(function() {
          captureEditorHeight("location", nightPanel)
          var locationCapture = heightCaptures.location
          equal(locationCapture.mode, "location", "runtime location capture records the active mode")
          equal(locationCapture.actual, locationCapture.target, "actual location card settles to its fitted target")
          equal(locationCapture.target, Math.round(locationCapture.composition + locationCapture.verticalInset),
            "location card is exactly chrome + active rows + spacings + insets")
          check(locationCapture.actual < heightCaptures.dashboard.actual,
            "actual location card is shorter than the dashboard")

          nightPanel.showEditor("manual")
          afterEditorSettle(function() {
            captureEditorHeight("manual", nightPanel)
            var manualCapture = heightCaptures.manual
            equal(manualCapture.mode, "manual", "runtime manual capture records the active mode")
            equal(manualCapture.actual, manualCapture.target, "actual manual card settles to its fitted target")
            equal(manualCapture.target, Math.round(manualCapture.composition + manualCapture.verticalInset),
              "manual card is exactly chrome + field/helper/cancel + spacings + insets")
            check(manualCapture.body < locationCapture.body,
              "manual field/helper/cancel body is tighter than the location rows")
            check(manualCapture.actual < locationCapture.actual,
              "actual manual and location card heights differ (location=" + locationCapture.actual +
              ", manual=" + manualCapture.actual + ")")
            finishRuntimeChecks(widget, nightPanel, dashboardHeight)
          })
        })
      })
    }
  }
}
QML

NIGHT_LIGHT_QML_RESULT="$RESULT" \
NIGHT_LIGHT_WIDGET_URL="file://$ROOT/BarWidget.qml" \
HOME="$TMP/home" \
XDG_CONFIG_HOME="$TMP/home/.config" \
XDG_CACHE_HOME="$TMP/home/.cache" \
XDG_STATE_HOME="$TMP/home/.local/state" \
QML2_IMPORT_PATH="$CONFIG${QML2_IMPORT_PATH:+:$QML2_IMPORT_PATH}" \
QML_IMPORT_PATH="$CONFIG${QML_IMPORT_PATH:+:$QML_IMPORT_PATH}" \
  quickshell -p "$CONFIG" --no-color >"$LOG" 2>&1 &
QS_PID=$!

for _ in {1..120}; do
  [[ -s $RESULT ]] && break
  if ! kill -0 "$QS_PID" 2>/dev/null; then
    sed -n '1,260p' "$LOG" >&2
    fail "quickshell exited before writing the harness result"
  fi
  sleep 0.1
done

[[ -s $RESULT ]] || {
  sed -n '1,260p' "$LOG" >&2
  fail "isolated QML harness timed out"
}

if ! jq -e '.ok == true' "$RESULT" >/dev/null; then
  jq . "$RESULT" >&2
  sed -n '1,300p' "$LOG" >&2
  fail "isolated QML assertions failed"
fi

# Runtime loading is authoritative. Reject diagnostics attributable to these files.
if grep -E '(BarWidget\.qml|Panel\.qml).*(Error|is not a type|Cannot assign|ReferenceError|TypeError|Unable to assign|Binding loop|NaN)' "$LOG" >&2; then
  fail "plugin-specific QML diagnostics were emitted"
fi

CAPTURE=${NIGHT_LIGHT_QML_HEIGHT_CAPTURE:-$ROOT/.work/captures/ui-editor-heights.json}
mkdir -p -- "$(dirname -- "$CAPTURE")"
jq '{editorHeights}' "$RESULT" >"$CAPTURE"
printf 'qml-entrypoints-test: runtime heights dashboard=%s location=%s manual=%s\n' \
  "$(jq -r '.editorHeights.dashboard.actual' "$RESULT")" \
  "$(jq -r '.editorHeights.location.actual' "$RESULT")" \
  "$(jq -r '.editorHeights.manual.actual' "$RESULT")"
printf 'qml-entrypoints-test: capture %s\n' "$CAPTURE"
printf 'qml-entrypoints-test: PASS\n'
