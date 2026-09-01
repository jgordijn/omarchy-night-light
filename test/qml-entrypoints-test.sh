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
PANEL_CAPTURE_DIR=${NIGHT_LIGHT_PANEL_CAPTURE_DIR:-$ROOT/.work/captures/panel-timeline}
mkdir -p "$CONFIG" "$TMP/home" "$PANEL_CAPTURE_DIR"
rm -f -- "$PANEL_CAPTURE_DIR/panel-timeline-sunrise.png" \
  "$PANEL_CAPTURE_DIR/panel-timeline-sunset.png"
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
  readonly property string panelCaptureDir: Quickshell.env("NIGHT_LIGHT_PANEL_CAPTURE_DIR")
  property var failures: []
  property var widget: null
  property int settingsWrites: 0
  property int switchCalls: 0
  property var heightCaptures: ({})
  property var afterSettleCallback: null
  property var panelCaptureCallback: null

  function fail(message) { failures.push(String(message)) }
  function check(condition, message) { if (!condition) fail(message) }
  function equal(actual, expected, message) {
    if (actual !== expected) fail(message + " expected=" + expected + " actual=" + actual)
  }
  function finite(value) { return isFinite(Number(value)) && Number(value) >= 0 }
  function clamp(value, low, high) { return Math.max(low, Math.min(value, high)) }
  function assertIconAnchoredPanel(panel, position) {
    var origin = panel.cardOrigin
    var expectedX = 0
    var expectedY = 0
    if (position === "bottom") {
      expectedX = panel.anchorScreenPos.x + panel.anchorW / 2 - panel.contentWidth / 2
      expectedY = panel.screenH - panel.barH - panel.contentHeight - panel.gap
    } else if (position === "left") {
      expectedX = panel.barW + panel.gap
      expectedY = panel.anchorScreenPos.y + panel.anchorH / 2 - panel.contentHeight / 2
    } else if (position === "right") {
      expectedX = panel.screenW - panel.barW - panel.contentWidth - panel.gap
      expectedY = panel.anchorScreenPos.y + panel.anchorH / 2 - panel.contentHeight / 2
    } else {
      expectedX = panel.anchorScreenPos.x + panel.anchorW / 2 - panel.contentWidth / 2
      expectedY = panel.barH + panel.gap
    }
    expectedX = Math.round(clamp(expectedX, panel.margin,
                                 panel.screenW - panel.contentWidth - panel.margin))
    expectedY = Math.round(clamp(expectedY, panel.margin,
                                 panel.screenH - panel.contentHeight - panel.margin))
    equal(origin.x, expectedX, position + " panel follows installed icon-anchor x contract")
    equal(origin.y, expectedY, position + " panel follows installed icon-anchor y contract")
    check(origin.x >= panel.margin &&
          origin.x + panel.contentWidth <= panel.screenW - panel.margin,
          position + " panel is horizontally screen-edge clamped")
    check(origin.y >= panel.margin &&
          origin.y + panel.contentHeight <= panel.screenH - panel.margin,
          position + " panel is vertically screen-edge clamped")
  }
  function itemBounds(item, ancestor) {
    var point = item.mapToItem(ancestor, 0, 0)
    return ({ left: point.x, top: point.y, right: point.x + item.width,
              bottom: point.y + item.height, width: item.width, height: item.height })
  }
  function intersects(left, right) {
    return left.left < right.right - 0.01 && left.right > right.left + 0.01 &&
      left.top < right.bottom - 0.01 && left.bottom > right.top + 0.01
  }
  function assertIntegratedDetail(panel, timeline, name) {
    var ancestor = panel.normalKeyboardTarget
    var label = timeline._pinnedLabelItem
    var detail = itemBounds(label, ancestor)
    var slot = itemBounds(timeline, ancestor)
    var source = itemBounds(panel.sourceRowControl, ancestor)
    var automatic = itemBounds(panel.automaticRowControl, ancestor)
    check(label.visible, name + " integrated detail is visible")
    check(detail.left >= slot.left - 0.01 && detail.right <= slot.right + 0.01 &&
          detail.top >= slot.top - 0.01 && detail.bottom <= slot.bottom + 0.01,
          name + " detail remains wholly inside the fixed Timeline slot")
    check(!intersects(detail, source), name + " detail does not obscure the source row")
    check(!intersects(detail, automatic), name + " detail does not obscure Automatic/On")
    check(label.width + 0.01 >= label.naturalWidth,
          name + " detail remains fully legible without integrated elision")
  }

  function afterPanelCaptureSettle(callback) {
    panelCaptureCallback = callback
    panelCaptureSettleTimer.restart()
  }

  function capturePanelTimeline(panel, timeline, done) {
    panel.setFocus(0)
    timeline.clearPin()
    timeline._selectedEventKey = timeline._events[0].key
    timeline.activateSelection()
    afterPanelCaptureSettle(function() {
      assertIntegratedDetail(panel, timeline, "sunrise")
      panel.normalKeyboardTarget.grabToImage(function(sunriseImage) {
        check(sunriseImage && sunriseImage.saveToFile(
          panelCaptureDir + "/panel-timeline-sunrise.png"),
          "full Panel sunrise collision capture saves")
        timeline.clearPin()
        timeline._selectedEventKey = timeline._events[1].key
        timeline.activateSelection()
        afterPanelCaptureSettle(function() {
          assertIntegratedDetail(panel, timeline, "sunset")
          panel.normalKeyboardTarget.grabToImage(function(sunsetImage) {
            check(sunsetImage && sunsetImage.saveToFile(
              panelCaptureDir + "/panel-timeline-sunset.png"),
              "full Panel sunset collision capture saves")
            timeline.clearPin()
            panel.setFocus(1)
            done()
          })
        })
      })
    })
  }

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
      assertIconAnchoredPanel(nightPanel.keyboardPanel, positions[i])
      check(nightPanel.keyboardPanel.contentWidth > 0 && nightPanel.keyboardPanel.contentWidth <= nightPanel.nominalContentWidth, positions[i] + " panel width stays fitted and bounded")
      check(nightPanel.keyboardPanel.contentHeight > 0 && nightPanel.keyboardPanel.contentHeight <= nightPanel.nominalContentHeight, positions[i] + " panel height stays fitted and bounded")
      if (fakeBar.vertical) equal(widget.implicitHeight, Style.bar.iconSlot, positions[i] + " uses one vertical icon slot")
    }
    fakeBar.position = "top"
    fakeBar.vertical = false
    fakeBar.barSize = Style.bar.sizeHorizontal
    afterEditorSettle(function() {
      capturePanelTimeline(nightPanel, nightPanel.timelineControl, function() {
        root.finishRuntimeChecksAfterCapture(widget, nightPanel)
      })
    })
  }

  function finishRuntimeChecksAfterCapture(widget, nightPanel) {
    var forwardTab = ({ key: Qt.Key_Tab, text: "", modifiers: 0, accepted: false })
    nightPanel.handleNormalKey(forwardTab)
    equal(forwardTab.accepted, true, "Tab remains owned by neighboring-panel handoff")
    var backwardTab = ({ key: Qt.Key_Backtab, text: "", modifiers: Qt.ShiftModifier, accepted: false })
    nightPanel.handleNormalKey(backwardTab)
    equal(backwardTab.accepted, true, "Shift+Tab remains owned by neighboring-panel handoff")
    equal(switchCalls, 2, "both keyboard handoff directions route through the bar")
    nightPanel.switchPanel(1)
    equal(switchCalls, 3, "panel handoff uses bar switch routing")
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
    id: panelCaptureSettleTimer
    interval: 80
    repeat: false
    onTriggered: {
      var callback = root.panelCaptureCallback
      root.panelCaptureCallback = null
      if (callback) callback()
    }
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
    property var settings: ({ id: "jgordijn.night-light", automationEnabled: true, nightTemperature: 4000, transitionMinutes: 45,
                              stockIndicator: { choice: "keep", before: null, after: null } })
    property var inlineSettings: settings
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
    property var timeline: ({
      revision: 7,
      dateKey: "2026-09-01",
      zoneId: "Europe/Amsterdam",
      zoneSource: "location",
      nowMs: 1788273420000,
      markerWallMs: 59820000,
      markerOffsetMinutes: 120,
      markerFold: 0,
      markerAmbiguous: false,
      status: "normal",
      stateAtMidnight: "night",
      isDayNow: true,
      events: [
        ({ key: "sunrise:1788238305216:120:0", kind: "sunrise",
           epochMs: 1788238305216, dateKey: "2026-09-01", wallMs: 24705216,
           offsetMinutes: 120, fold: 0, ambiguous: false }),
        ({ key: "sunset:1788287423925:120:0", kind: "sunset",
           epochMs: 1788287423925, dateKey: "2026-09-01", wallMs: 73823925,
           offsetMinutes: 120, fold: 0, ambiguous: false })
      ],
      daylightSegments: [({ startWallMs: 24705216, endWallMs: 73823925 })],
      displayTimes: ({
        sunset: ({ epochMs: 1788287423925, dateKey: "2026-09-01", wallMs: 73823925,
                   offsetMinutes: 120, fold: 0, ambiguous: false }),
        sunrise: ({ epochMs: 1788325200000, dateKey: "2026-09-02", wallMs: 25200000,
                    offsetMinutes: 120, fold: 0, ambiguous: false }),
        nextBoundary: ({ epochMs: 1788287423925, dateKey: "2026-09-01", wallMs: 73823925,
                         offsetMinutes: 120, fold: 0, ambiguous: false }),
        overrideUntil: null
      })
    })
    property var moonPhase: ({
      ok: true, calculatedAtMs: 1788273420000, phase: 0.6495230623756667,
      ageDays: 19.180798505557288, illumination: 0.7948970595391965,
      trend: "waning", phaseId: "waning-gibbous", phaseName: "Waning Gibbous",
      orientation: "northern", orientationSource: "location"
    })
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
    property int warmthStepCalls: 0
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
    function stepNightTemperature(direction) {
      warmthStepCalls++
      if (direction !== -1 && direction !== 1) return false
      var next = Math.max(1000, Math.min(6500, Number(settings.nightTemperature) + direction * 250))
      if (next === Number(settings.nightTemperature)) return false
      var entry = JSON.parse(JSON.stringify(settings))
      entry.nightTemperature = next
      settings = entry
      inlineSettings = entry
      return true
    }
  }

  QtObject {
    id: fakeShell
    property var shellConfig: ({ bar: { layout: { left: [], center: [], right: [{ id: "omarchy.indicators" }] } } })
    property var lastSettingsEntry: null
    function serviceFor(id) { return id === "jgordijn.night-light" ? fakeService : null }
    function updateEntryInline(id, entry) {
      root.settingsWrites++
      if (id === "jgordijn.night-light") lastSettingsEntry = JSON.parse(JSON.stringify(entry))
      return true
    }
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
        var timelineControl = nightPanel.timelineControl
        check(timelineControl !== null, "dashboard instantiates DaylightTimeline")
        check(timelineControl.snapshot === fakeService.timeline,
              "panel binds the complete atomic Service timeline snapshot")
        check(timelineControl.moonPhase === fakeService.moonPhase,
              "panel binds the complete Service lunar snapshot")
        equal(timelineControl.height, Style.space(58), "timeline replaces the old slot without changing geometry")
        equal(nightPanel.stateDetail,
              "Sunset at " + nightPanel.formatProjectedTime(fakeService.timeline.displayTimes.sunset),
              "hero event copy uses the projected civil display time")
        var projectedFixture = fakeService.timeline
        var missingProjection = JSON.parse(JSON.stringify(projectedFixture))
        missingProjection.displayTimes.sunset = null
        missingProjection.displayTimes.nextBoundary = null
        fakeService.timeline = missingProjection
        equal(nightPanel.stateDetail, "Sunset at —",
              "missing projection never falls back to the stable epoch in the shell timezone")
        fakeService.timeline = projectedFixture
        var projectedOverride = JSON.parse(JSON.stringify(projectedFixture))
        projectedOverride.displayTimes.nextBoundary = projectedOverride.displayTimes.sunrise
        projectedOverride.displayTimes.overrideUntil = projectedOverride.displayTimes.sunrise
        fakeService.timeline = projectedOverride
        fakeService.mode = "override"
        fakeService.phase = "evening-transition"
        fakeService.overrideUntil = fakeService.sunrise
        equal(nightPanel.stateDetail,
              "Automatic resumes at sunrise · " +
                nightPanel.formatProjectedTime(projectedOverride.displayTimes.sunrise),
              "override boundary name follows the projected event, not the transition phase")
        fakeService.timeline = projectedFixture
        fakeService.mode = "scheduled"
        fakeService.phase = "day"
        fakeService.overrideUntil = 0
        equal(nightPanel.focusIndex, 1, "Automatic is the initial normal focus")
        check(nightPanel.keyboardPanel.owner === widget, "KeyboardPanel owner is host widget")
        check(nightPanel.anchorItem !== null &&
              nightPanel.keyboardPanel.anchorItem === nightPanel.anchorItem &&
              nightPanel.keyboardPanel.anchorItem !== widget,
              "actual injected WidgetButton is the KeyboardPanel anchor")
        equal(nightPanel.keyboardPanel.centerOnBar, false,
              "panel opts into installed edge-aware icon anchoring")
        assertIconAnchoredPanel(nightPanel.keyboardPanel, "top")

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

        nightPanel.persistSettings({ transitionMinutes: 30 })
        equal(widget.settings.transitionMinutes, 30, "settings update host immediately")
        equal(nightPanel.settings.transitionMinutes, 30, "settings update panel immediately")
        equal(root.settingsWrites, 1, "ordinary settings persist through updateEntryInline")
        nightPanel.stepWarmth(1)
        equal(fakeService.warmthStepCalls, 1, "one warmth step makes exactly one Service call")
        equal(widget.settings.nightTemperature, 4250, "Service warmth updates host immediately")
        equal(nightPanel.settings.nightTemperature, 4250, "Service warmth updates panel immediately")
        equal(root.settingsWrites, 1, "Panel performs no direct Warmth persistence")

        // Exact stale multi-panel regression: Service has canonically committed
        // 4250 K while this panel and host still show their old 4000 K snapshot.
        var stalePanelEntry = JSON.parse(JSON.stringify(nightPanel.settings))
        stalePanelEntry.nightTemperature = 4000
        nightPanel.settings = stalePanelEntry
        widget.settings = JSON.parse(JSON.stringify(stalePanelEntry))
        equal(fakeService.inlineSettings.nightTemperature, 4250,
          "stale-panel setup retains Service canonical 4250 K")
        nightPanel.stepTransition(1)
        equal(root.settingsWrites, 2, "other keyboard value changes persist complete transactions")
        equal(fakeShell.lastSettingsEntry.nightTemperature, 4250,
          "transition edit retains canonical Service 4250 K over stale panel 4000 K")
        equal(nightPanel.settings.nightTemperature, 4250,
          "transition transaction repairs the stale panel Warmth snapshot")
        equal(widget.settings.nightTemperature, 4250,
          "transition transaction repairs the stale host Warmth snapshot")

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
        check(nightPanel.keyboardPanel.focusTarget === nightPanel.normalKeyboardTarget,
          "normal mode routes live focus to its conflict-free key target")
        equal(nightPanel.focusIndex, 1, "keyboard open starts on Automatic, not Timeline")
        equal(timelineControl._revealArrows, false,
              "keyboard open on Automatic leaves Timeline arrows at rest")

        var upToTimeline = ({ key: Qt.Key_Up, text: "", modifiers: 0, accepted: false })
        nightPanel.handleNormalKey(upToTimeline)
        equal(upToTimeline.accepted, true, "Up from Automatic is consumed")
        equal(nightPanel.focusIndex, 0, "Up from Automatic reaches Timeline")
        check(timelineControl.current, "Timeline receives native roving focus chrome")
        check(timelineControl._selectedEventKey.indexOf("sunset:") === 0,
              "first Timeline focus selects the next real event")

        var timelineLeft = ({ key: Qt.Key_Left, text: "", modifiers: 0, accepted: false })
        nightPanel.handleNormalKey(timelineLeft)
        check(timelineControl._selectedEventKey.indexOf("sunrise:") === 0,
              "Timeline Left routes to event selection")
        var timelineRight = ({ key: Qt.Key_Right, text: "", modifiers: 0, accepted: false })
        nightPanel.handleNormalKey(timelineRight)
        check(timelineControl._selectedEventKey.indexOf("sunset:") === 0,
              "Timeline Right routes to event selection")
        var timelineEnter = ({ key: Qt.Key_Return, text: "", modifiers: 0, accepted: false })
        nightPanel.handleNormalKey(timelineEnter)
        check(timelineControl._pinnedEventKey.indexOf("sunset:") === 0,
              "Timeline Enter pins the selected event")
        var timelineSpace = ({ key: Qt.Key_Space, text: " ", modifiers: 0, accepted: false })
        nightPanel.handleNormalKey(timelineSpace)
        equal(timelineControl._pinnedEventKey, "", "Timeline Space unpins the selected event")

        timelineControl.focusRequested()
        equal(nightPanel.focusIndex, 0, "pointer entry moves roving focus to Timeline")
        var downToAutomatic = ({ key: Qt.Key_Down, text: "", modifiers: 0, accepted: false })
        nightPanel.handleNormalKey(downToAutomatic)
        equal(nightPanel.focusIndex, 1, "Down from Timeline returns to Automatic")

        var firstAtomicTimeline = fakeService.timeline
        var replacementTimeline = JSON.parse(JSON.stringify(firstAtomicTimeline))
        replacementTimeline.revision = 8
        replacementTimeline.markerWallMs = 60000000
        fakeService.timeline = replacementTimeline
        check(timelineControl.snapshot === replacementTimeline,
              "timeline replacement crosses the binding as one object")
        equal(timelineControl._timeline.revision, 8,
              "component consumes the replacement transaction atomically")
        fakeService.timeline = firstAtomicTimeline

        nightPanel.setFocus(0)
        nightPanel.handleNormalKey(({ key: Qt.Key_Return, text: "", modifiers: 0, accepted: false }))
        check(timelineControl._pinnedEventKey !== "", "close-clear test prepared a pin")
        var closeKey = ({ key: Qt.Key_Escape, text: "", modifiers: 0, accepted: false })
        nightPanel.handleNormalKey(closeKey)
        equal(closeKey.accepted, true, "Escape remains an immediate close")
        check(!widget.opened, "Escape closes without a two-step pin dismissal")
        equal(timelineControl._pinnedEventKey, "", "close clears the Timeline pin")
        widget.open()
        equal(nightPanel.focusIndex, 1, "reopen restores Automatic initial focus")

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
NIGHT_LIGHT_PANEL_CAPTURE_DIR="$PANEL_CAPTURE_DIR" \
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
if grep -E '(BarWidget\.qml|Panel\.qml|DaylightTimeline\.qml).*(Error|is not a type|Cannot assign|ReferenceError|TypeError|Unable to assign|Binding loop|NaN)' "$LOG" >&2; then
  fail "plugin-specific QML diagnostics were emitted"
fi

for panel_capture in panel-timeline-sunrise.png panel-timeline-sunset.png; do
  [[ -s $PANEL_CAPTURE_DIR/$panel_capture ]] ||
    fail "missing full Panel collision capture: $panel_capture"
done
if command -v identify >/dev/null 2>&1; then
  SUNRISE_GEOMETRY=$(identify -format '%wx%h' "$PANEL_CAPTURE_DIR/panel-timeline-sunrise.png")
  SUNSET_GEOMETRY=$(identify -format '%wx%h' "$PANEL_CAPTURE_DIR/panel-timeline-sunset.png")
  [[ $SUNRISE_GEOMETRY == "$SUNSET_GEOMETRY" ]] ||
    fail "Panel collision capture geometry changed between pin states"
fi

CAPTURE=${NIGHT_LIGHT_QML_HEIGHT_CAPTURE:-$ROOT/.work/captures/ui-editor-heights.json}
mkdir -p -- "$(dirname -- "$CAPTURE")"
jq '{editorHeights}' "$RESULT" >"$CAPTURE"
printf 'qml-entrypoints-test: runtime heights dashboard=%s location=%s manual=%s\n' \
  "$(jq -r '.editorHeights.dashboard.actual' "$RESULT")" \
  "$(jq -r '.editorHeights.location.actual' "$RESULT")" \
  "$(jq -r '.editorHeights.manual.actual' "$RESULT")"
printf 'qml-entrypoints-test: height capture %s\n' "$CAPTURE"
printf 'qml-entrypoints-test: panel collision captures %s\n' "$PANEL_CAPTURE_DIR"
printf 'qml-entrypoints-test: PASS\n'
