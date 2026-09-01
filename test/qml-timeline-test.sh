#!/usr/bin/env bash
# Isolated reusable DaylightTimeline harness. It uses only frozen timeline/moon
# snapshots and never instantiates Service.qml, Panel.qml, or Controller.py.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/qml" "$TMP/home" "$TMP/runtime"
chmod 700 "$TMP/runtime"

mapfile -t API_PROPERTIES < <(
  grep -E '^  (required )?property (var|bool|color|string) [a-z]' "$ROOT/DaylightTimeline.qml" |
    sed -E 's/^  (required )?property (var|bool|color|string) ([A-Za-z0-9_]+).*/\3/'
)
[[ ${API_PROPERTIES[*]} == "snapshot moonPhase current foreground fontFamily" ]] || {
  printf 'qml-timeline-test: FAIL: public properties changed: %s\n' "${API_PROPERTIES[*]}" >&2
  exit 1
}
mapfile -t API_FUNCTIONS < <(
  grep -E '^  function [a-z]' "$ROOT/DaylightTimeline.qml" |
    sed -E 's/^  function ([A-Za-z0-9_]+).*/\1/'
)
[[ ${API_FUNCTIONS[*]} == "moveSelection activateSelection clearPin" ]] || {
  printf 'qml-timeline-test: FAIL: public functions changed: %s\n' "${API_FUNCTIONS[*]}" >&2
  exit 1
}
[[ $(grep -Ec '^  signal focusRequested\(\)' "$ROOT/DaylightTimeline.qml") -eq 1 ]] || {
  printf 'qml-timeline-test: FAIL: focusRequested API changed\n' >&2
  exit 1
}
if grep -Eq '\b(Timer|SystemClock|ElapsedTimer|Process|FileView|WheelHandler|DragHandler)[[:space:]]*\{|Date\.now\(' "$ROOT/DaylightTimeline.qml"; then
  printf 'qml-timeline-test: FAIL: component owns a forbidden clock/I/O/drag primitive\n' >&2
  exit 1
fi

cp "$ROOT/DaylightTimeline.qml" "$ROOT/MoonPhaseIcon.qml" \
   "$ROOT/TimelineModel.js" "$TMP/qml/"
ln -s /usr/share/omarchy/shell/Commons "$TMP/qml/Commons"
ln -s /usr/share/omarchy/shell/Ui "$TMP/qml/Ui"

CAPTURE=${NIGHT_LIGHT_TIMELINE_CAPTURE:-$ROOT/.work/captures/timeline-fixtures.png}
REFERENCE="$ROOT/test/reference/timeline/timeline-fixtures.png"
mkdir -p -- "$(dirname -- "$CAPTURE")"

cat >"$TMP/qml/shell.qml" <<'QML'
import QtQuick
import Quickshell
import qs.Commons
import "."

ShellRoot {
  id: harness
  property bool failed: false
  property int stage: 0
  property real oldProgress: 0
  property int focusRequests: 0
  property bool captureSaved: false
  property var normal: makeSnapshot({})
  property var moon: ({
    ok:true, calculatedAtMs:1788273420000, phase:0.6495230623756667,
    ageDays:19.180798505557288, illumination:0.7948970595391965,
    trend:"waning", phaseId:"waning-gibbous", phaseName:"Waning Gibbous",
    orientation:"northern", orientationSource:"location"
  })

  function fail(message) {
    if (failed) return
    failed = true
    console.error("TIMELINE_TEST_FAIL", message)
    Qt.quit()
  }
  function check(value, message) { if (!value) fail(message) }
  function equal(actual, expected, message) {
    if (actual !== expected) fail(message + " expected=" + expected + " actual=" + actual)
  }
  function near(actual, expected, tolerance, message) {
    if (!isFinite(actual) || Math.abs(actual - expected) > tolerance)
      fail(message + " expected≈" + expected + " actual=" + actual)
  }
  function clone(value) { return JSON.parse(JSON.stringify(value)) }
  function wall(hours, minutes, seconds) {
    return ((hours * 60 + minutes) * 60 + (seconds || 0)) * 1000
  }
  function event(kind, epochMs, wallMs, offset, fold, ambiguous) {
    return {
      kind:kind, epochMs:epochMs, dateKey:"2026-09-01", wallMs:wallMs,
      offsetMinutes:offset === undefined ? 120 : offset,
      fold:fold === undefined ? 0 : fold,
      ambiguous:ambiguous === true
    }
  }
  function makeSnapshot(overrides) {
    var value = {
      revision:7, dateKey:"2026-09-01", zoneId:"Europe/Amsterdam",
      zoneSource:"location", nowMs:1788273420000, markerWallMs:59820000,
      markerOffsetMinutes:120, markerFold:0, markerAmbiguous:false,
      status:"normal", stateAtMidnight:"night", isDayNow:true,
      events:[
        event("sunrise",1788238305216,24705216),
        event("sunset",1788287423925,73823925)
      ],
      daylightSegments:[{startWallMs:24705216,endWallMs:73823925}],
      displayTimes:{sunset:null,sunrise:null,nextBoundary:null,overrideUntil:null}
    }
    for (var key in overrides) value[key] = overrides[key]
    return value
  }
  function findObject(item, prefix) {
    if (!item) return null
    if (String(item.objectName || "").indexOf(prefix) === 0) return item
    var list = item.children || []
    for (var i = 0; i < list.length; i++) {
      var found = findObject(list[i], prefix)
      if (found) return found
    }
    return null
  }
  function countObjects(item, prefix) {
    if (!item) return 0
    var count = String(item.objectName || "").indexOf(prefix) === 0 ? 1 : 0
    var list = item.children || []
    for (var i = 0; i < list.length; i++) count += countObjects(list[i], prefix)
    return count
  }
  function checkDetailGeometry(timeline, event, target, label, context) {
    var gap = Style.spacing.sm
    var arrow = findObject(timeline, "eventArrow-" + event.kind)
    var eventX = timeline._railStart + timeline._railSpan * event.wallMs / 86400000
    check(label.visible, context + " detail is visible")
    check(timeline.z > 0, context + " detail raises above track primitives")
    check(timeline._revealArrows, context + " detail keeps arrows revealed")
    near(arrow.x + arrow.width / 2, eventX, 0.001,
         context + " arrow remains anchored to its event")
    check(label.x >= -0.001 && label.x + label.width <= timeline.width + 0.001,
          context + " detail clamps horizontally")
    check(label.y >= -0.001 && label.y + label.height <= timeline.height + 0.001,
          context + " detail stays inside the fixed slot")
    check(label.x + label.width <= target.x - gap + 0.001 ||
          label.x >= target.x + target.width + gap - 0.001,
          context + " detail clears its anchored event target horizontally")
    if (event.kind === "sunrise")
      check(label.y + label.height <= timeline._railY + 0.001,
            context + " detail uses the upper internal label lane")
    else
      check(label.y >= timeline._railY - 0.001,
            context + " detail uses the lower internal label lane")
  }

  FloatingWindow {
    id: window
    visible: true
    color: "#101315"
    implicitWidth: 560
    implicitHeight: 430
    minimumSize: Qt.size(560, 430)
    maximumSize: Qt.size(560, 430)

    Item {
      id: captureBoard
      anchors.fill: parent

      Rectangle { anchors.fill: parent; color: "#101315"; z: -1 }

      Column {
        anchors.fill: parent
        anchors.margins: 24
        spacing: 38

        Text { text:"REST · DAY"; color:"#e8eaed"; font.family:Style.font.family; font.pixelSize:Style.font.caption }
        DaylightTimeline {
          id: timeline
          objectName: "testedTimeline"
          width: 512
          snapshot: harness.normal
          moonPhase: harness.moon
          foreground: "#e8eaed"
          fontFamily: Style.font.family
          onFocusRequested: harness.focusRequests++
        }

        Text { text:"PIN → HOVER · 40 MS CONTINUITY"; color:"#e8eaed"; font.family:Style.font.family; font.pixelSize:Style.font.caption }
        DaylightTimeline {
          id: nightCapture
          width: 512
          current: true
          snapshot: harness.makeSnapshot({
            revision:8, nowMs:1788300000000, markerWallMs:harness.wall(22,15),
            isDayNow:false
          })
          moonPhase: harness.moon
          foreground: "#e8eaed"
          Component.onCompleted: activateSelection()
        }

        Text { text:"POLAR DAY"; color:"#e8eaed"; font.family:Style.font.family; font.pixelSize:Style.font.caption }
        DaylightTimeline {
          id: polarCapture
          width: 512
          snapshot: harness.makeSnapshot({
            revision:9, status:"polar-day", stateAtMidnight:"day",
            events:[], daylightSegments:[{startWallMs:0,endWallMs:86400000}],
            isDayNow:true, markerWallMs:harness.wall(12,0)
          })
          moonPhase: ({ok:false,error:"invalid-epoch",calculatedAtMs:1788273420000})
          foreground: "#e8eaed"
        }
      }
    }
  }

  Timer {
    id: stages
    interval: 40
    repeat: true
    running: true
    property int ticks: 0

    onTriggered: {
      ticks++
      if (failed) return
      if (stage === 0) {
        equal(timeline.implicitHeight, Style.space(58), "slot height")
        equal(timeline.height, Style.space(58), "fixed component height")
        near(timeline._railStart, Style.space(16) / 2, 0.001, "rail marker-radius inset")
        near(timeline._railSpan, timeline.width - Style.space(16), 0.001, "rail span")
        near(timeline._markerProgress, 59820000 / 86400000, 0.000001,
             "installed civil marker position")
        equal(countObjects(timeline, "daylightSegment"), 1, "one daylight segment")
        var segment = findObject(timeline, "daylightSegment")
        near(segment.x, timeline._railStart + timeline._railSpan * 24705216 / 86400000,
             0.001, "daylight start shares rail geometry")
        near(segment.width, timeline._railSpan * (73823925 - 24705216) / 86400000,
             0.001, "daylight width shares rail geometry")
        equal(countObjects(timeline, "eventTarget-"), 2, "two event targets")
        var riseArrow = findObject(timeline, "eventArrow-sunrise")
        var setArrow = findObject(timeline, "eventArrow-sunset")
        equal(riseArrow.opacity, 0, "idle sunrise arrow is hidden")
        equal(setArrow.opacity, 0, "idle sunset arrow is hidden")
        var riseTarget = findObject(timeline, "eventTarget-sunrise-")
        var setTarget = findObject(timeline, "eventTarget-sunset-")
        check(riseTarget && setTarget, "event targets are discoverable")
        check(riseTarget.width >= Style.space(32) && riseTarget.height >= Style.space(32),
              "sunrise target is at least 32 square")
        check(setTarget.width >= Style.space(32) && setTarget.height >= Style.space(32),
              "sunset target is at least 32 square")
        check(riseTarget.y !== setTarget.y, "event targets are vertically displaced")
        check(!("color" in riseTarget) && !("borderSpec" in riseTarget) &&
              !("color" in setTarget) && !("borderSpec" in setTarget),
              "32 px event targets paint no rectangular selection box")
        equal(riseTarget.children.length, 1,
              "sunrise hit target contains only its pointer handler")
        equal(setTarget.children.length, 1,
              "sunset hit target contains only its pointer handler")
        var markerTarget = findObject(timeline, "markerTarget")
        check(markerTarget.width >= Style.space(32) && markerTarget.height >= Style.space(32),
              "marker target is at least 32 square")
        equal(timeline.Accessible.name, "24-hour daylight timeline", "timeline accessible name")
        check(String(timeline.Accessible.description).indexOf("Daylight from ") === 0,
              "normal accessible description")
        equal(timeline._markerTooltipText(),
              "Current time · " + timeline._currentTimeText,
              "day marker tooltip copy")
        check(String(nightCapture._markerTooltipText()).indexOf(
              "Waning Gibbous · 79% illuminated\nCurrent time · ") === 0,
              "night marker tooltip has exact lunar and current-time lines")
        check(String(findObject(nightCapture, "currentMarker").Accessible.name).indexOf(
              "Waning Gibbous, 79% illuminated") > 0,
              "night marker accessibility includes lunar phase")
        check(String(riseTarget.Accessible.name).indexOf("Sunrise, ") === 0,
              "sunrise accessible button name")

        // Pointer hover asks the owner for focus, reveals exact native tooltip
        // copy, temporarily wins over a pin, then restores that pin.
        var riseMouse = findObject(timeline, "eventMouse-sunrise")
        var setMouse = findObject(timeline, "eventMouse-sunset")
        var focusBefore = harness.focusRequests
        riseMouse.entered()
        equal(harness.focusRequests, focusBefore + 1, "pointer entry requests focus")
        check(timeline._revealArrows, "event hover reveals arrows")
        check(timeline._hoveredEventKey.indexOf("sunrise:") === 0,
              "hover requests sunrise through the native delay")
        equal(timeline._displayedEventKey, "",
              "unpinned hover does not claim detail before native delay")
        check(String(timeline._eventLabel(timeline._events[0])).indexOf("Sunrise ") === 0 &&
              String(timeline._eventLabel(timeline._events[0])).indexOf("Sunrise ·") < 0,
              "ordinary sunrise tooltip copy is exact")
        riseMouse.clicked(null)
        check(timeline._pinnedEventKey.indexOf("sunrise:") === 0,
              "left click pins immediately")
        var pinnedLabel = findObject(timeline, "pinnedEventLabel")
        checkDetailGeometry(timeline, timeline._events[0], riseTarget, pinnedLabel,
                            "sunrise pin")
        check(timeline._revealArrows, "pinned detail keeps arrows revealed")
        setMouse.entered()
        check(timeline._displayedEventKey.indexOf("sunrise:") === 0,
              "pin remains displayed while sunset hover delay starts")
        check(pinnedLabel.visible, "native hover delay has no blank handoff")
        equal(timeline._hoverDetailReadyKey, "", "hover is not ready immediately")
        setMouse.exited()
        check(timeline._displayedEventKey.indexOf("sunrise:") === 0,
              "early hover leave keeps the pin continuously")
        checkDetailGeometry(timeline, timeline._events[0], riseTarget, pinnedLabel,
                            "continuous sunrise pin")
        setMouse.entered()
        setMouse.clicked(null)
        check(timeline._pinnedEventKey.indexOf("sunset:") === 0,
              "click transfers the pin to sunset")
        checkDetailGeometry(timeline, timeline._events[1], setTarget, pinnedLabel,
                            "sunset transfer")
        setMouse.clicked(null)
        equal(timeline._pinnedEventKey, "", "second left click unpins")
        riseMouse.exited()

        // First focus selects the next real epoch (sunset), then clamps without wrap.
        timeline._selectedEventKey = ""
        timeline.current = true
        equal(timeline._selectedEventKey, harness.normal.events[1].kind + ":" +
              harness.normal.events[1].epochMs + ":120:0", "first-focus epoch selection")
        var focusChrome = findObject(timeline, "timelineFocusChrome")
        check(focusChrome && focusChrome.borderTop > 0,
              "whole-row focus cue remains visible")
        check(setArrow.font.bold && !riseArrow.font.bold,
              "selected sunset glyph carries keyboard selection without a target box")
        check(timeline.moveSelection(-1), "left selects sunrise")
        check(riseArrow.font.bold && !setArrow.font.bold,
              "selected sunrise glyph carries keyboard selection without a target box")
        check(!timeline.moveSelection(-1), "left clamps")
        check(timeline.moveSelection(1), "right selects sunset")
        check(setArrow.font.bold && !riseArrow.font.bold,
              "right restores selected-glyph keyboard clarity")
        check(!timeline.moveSelection(1), "right clamps")
        check(!timeline.moveSelection(0), "invalid direction is ignored")
        check(timeline.activateSelection(), "keyboard activation pins")
        check(timeline._pinnedEventKey !== "", "keyboard pin is retained")
        check(timeline.activateSelection(), "keyboard activation unpins")
        equal(timeline._pinnedEventKey, "", "keyboard unpin")

        // Accessibility Press is exactly the same pin toggle as click/keyboard.
        riseTarget.Accessible.pressAction()
        check(timeline._pinnedEventKey.indexOf("sunrise:") === 0,
              "accessible Press pins sunrise")
        riseTarget.Accessible.pressAction()
        equal(timeline._pinnedEventKey, "", "accessible Press unpins sunrise")

        // Ambiguous projected wall labels use U+2212 offsets and stay distinct.
        var folded = harness.makeSnapshot({
          revision:10, zoneId:"America/New_York", markerOffsetMinutes:-300,
          stateAtMidnight:"night", events:[
            harness.event("sunrise",1000,harness.wall(1,30),-240,0,true),
            harness.event("sunset",2000,harness.wall(1,30),-300,1,true)
          ], daylightSegments:[]
        })
        timeline.current = false
        timeline.snapshot = folded
        equal(timeline._events.length, 2, "same-wall folds remain distinct")
        check(timeline._eventLabel(timeline._events[0]).indexOf("UTC−04:00") > 0,
              "fold zero offset label")
        check(timeline._eventLabel(timeline._events[1]).indexOf("UTC−05:00") > 0,
              "fold one offset label")
        var foldedRise = findObject(timeline, "eventTarget-sunrise-")
        var foldedSet = findObject(timeline, "eventTarget-sunset-")
        check(foldedRise.y !== foldedSet.y, "same-wall fold targets do not coincide vertically")

        // A short two-minute day is still two independently sized targets.
        timeline.snapshot = harness.makeSnapshot({
          revision:11, events:[
            harness.event("sunrise",1000,harness.wall(11,59)),
            harness.event("sunset",2000,harness.wall(12,1))
          ], daylightSegments:[{startWallMs:harness.wall(11,59),endWallMs:harness.wall(12,1)}]
        })
        equal(countObjects(timeline, "eventTarget-"), 2, "short day keeps two targets")
        timeline.current = true
        check(!timeline.moveSelection(-1) || timeline._selectedEventKey.indexOf("sunrise:") === 0,
              "short-day selection remains epoch ordered")

        var oneRise = harness.makeSnapshot({
          revision:111, events:[harness.event("sunrise",1000,harness.wall(6,0))],
          daylightSegments:[{startWallMs:harness.wall(6,0),endWallMs:86400000}],
          nowMs:999, isDayNow:false
        })
        timeline.snapshot = oneRise
        timeline.current = true
        check(!timeline.moveSelection(-1) && !timeline.moveSelection(1),
              "one-event selection is a no-op")
        check(timeline.activateSelection(), "one event remains keyboard activatable")
        timeline.clearPin()

        // Edge targets clamp while their glyph/event geometry remains exact.
        timeline.snapshot = harness.makeSnapshot({
          revision:112, events:[
            harness.event("sunrise",1000,0),
            harness.event("sunset",2000,86399999)
          ], daylightSegments:[{startWallMs:0,endWallMs:86399999}]
        })
        riseTarget = findObject(timeline, "eventTarget-sunrise-")
        setTarget = findObject(timeline, "eventTarget-sunset-")
        check(riseTarget.x >= 0 && riseTarget.x + riseTarget.width <= timeline.width,
              "midnight event target clamps inside")
        check(setTarget.x >= 0 && setTarget.x + setTarget.width <= timeline.width,
              "day-end event target clamps inside")

        // Polar and malformed snapshots fail closed without changing geometry.
        timeline.snapshot = harness.makeSnapshot({
          revision:12, status:"polar-night", stateAtMidnight:"night",
          events:[], daylightSegments:[], isDayNow:false
        })
        equal(countObjects(timeline, "daylightSegment"), 0, "polar night has no daylight")
        equal(countObjects(timeline, "eventTarget-"), 0, "polar night fabricates no event")
        equal(timeline.Accessible.description,
              "Night all day. Current time " + timeline._currentTimeText + ".",
              "polar-night accessible description")
        timeline.snapshot = harness.makeSnapshot({
          revision:13, status:"unavailable", stateAtMidnight:null,
          events:[], daylightSegments:[], isDayNow:false
        })
        check(findObject(timeline, "neutralMarker").visible,
              "valid unavailable snapshot uses a neutral marker")
        equal(timeline.Accessible.description,
              "Solar events unavailable. Current time " + timeline._currentTimeText + ".",
              "unavailable accessible description")
        timeline.snapshot = ({bad:true})
        check(timeline._timeline === null, "malformed snapshot is rejected")
        near(timeline._markerProgress, 0.5, 0.000001, "malformed marker is neutral and finite")
        equal(timeline.Accessible.description,
              "Solar events unavailable. Current time —.", "malformed accessible fallback")
        check(findObject(timeline, "neutralMarker").visible, "malformed snapshot uses neutral marker")
        equal(timeline.height, Style.space(58), "malformed state keeps height")

        // Geometry remains finite and token-scaled for narrow/wide edge-hosted
        // slots, light/dark foregrounds, and 1x/1.5x/2x style scales.
        timeline.snapshot = harness.normal
        timeline.current = false
        var widths = [96, 512, 900]
        for (var widthIndex = 0; widthIndex < widths.length; widthIndex++) {
          timeline.width = widths[widthIndex]
          riseTarget = findObject(timeline, "eventTarget-sunrise-")
          setTarget = findObject(timeline, "eventTarget-sunset-")
          check(isFinite(timeline._railStart) && isFinite(timeline._railSpan),
                "edge-hosted width has finite rail geometry")
          check(riseTarget.x >= 0 && riseTarget.x + riseTarget.width <= timeline.width,
                "sunrise target stays bounded at width " + timeline.width)
          check(setTarget.x >= 0 && setTarget.x + setTarget.width <= timeline.width,
                "sunset target stays bounded at width " + timeline.width)
          timeline.current = true
          timeline._selectedEventKey = timeline._events[0].key
          timeline.activateSelection()
          checkDetailGeometry(timeline, timeline._events[0], riseTarget,
                              findObject(timeline, "pinnedEventLabel"),
                              "sunrise width " + timeline.width)
          timeline._selectedEventKey = timeline._events[1].key
          timeline.activateSelection()
          checkDetailGeometry(timeline, timeline._events[1], setTarget,
                              findObject(timeline, "pinnedEventLabel"),
                              "sunset width " + timeline.width)
          timeline.clearPin()
          timeline.current = false
        }
        timeline.foreground = "#151515"
        equal(timeline.height, Style.space(58), "light foreground keeps geometry")
        timeline.foreground = "#eeeeee"
        equal(timeline.height, Style.space(58), "dark foreground keeps geometry")
        Style.spacingScaleWithFont = false
        Style.spacingScale = 1.5
        equal(timeline.height, Style.space(58), "1.5x slot follows native token")
        equal(findObject(timeline, "markerTarget").width, Style.space(32),
              "1.5x marker target follows native token")
        timeline.current = true
        timeline._selectedEventKey = timeline._events[0].key
        timeline.activateSelection()
        checkDetailGeometry(timeline, timeline._events[0],
                            findObject(timeline, "eventTarget-sunrise-"),
                            findObject(timeline, "pinnedEventLabel"), "sunrise 1.5x")
        timeline.clearPin()
        Style.spacingScale = 2
        equal(timeline.height, Style.space(58), "2x slot follows native token")
        equal(findObject(timeline, "eventTarget-sunrise-").width, Style.space(32),
              "2x event target follows native token")
        timeline._selectedEventKey = timeline._events[1].key
        timeline.activateSelection()
        checkDetailGeometry(timeline, timeline._events[1],
                            findObject(timeline, "eventTarget-sunset-"),
                            findObject(timeline, "pinnedEventLabel"), "sunset 2x")
        timeline.clearPin()
        timeline.current = false
        Style.spacingScale = 1
        Style.spacingScaleWithFont = true
        timeline.width = 512

        // Exact event disappearance clears a pin even inside one revision.
        timeline.current = true
        timeline.activateSelection()
        check(timeline._pinnedEventKey !== "", "normal pin prepared")
        var disappeared = harness.clone(harness.normal)
        disappeared.events = [disappeared.events[0]]
        disappeared.daylightSegments = [{startWallMs:24705216,endWallMs:86400000}]
        timeline.snapshot = disappeared
        equal(timeline._pinnedEventKey, "", "disappeared exact event clears pin")

        // Reinstall normal, pin, then prove marker-only update retains the pin
        // and starts only the allowed nearby 160 ms animation.
        timeline.snapshot = harness.normal
        timeline.current = true
        timeline.activateSelection()
        check(timeline._pinnedEventKey !== "", "normal marker pin prepared")
        oldProgress = timeline._markerProgress
        var nearby = harness.clone(harness.normal)
        nearby.nowMs += 60000
        nearby.markerWallMs += 60000
        timeline.snapshot = nearby
        check(timeline._pinnedEventKey !== "", "marker-only update retains pin")
        near(timeline._markerProgress, oldProgress, 0.00001,
             "allowed marker animation does not jump immediately")
        stage = 1; ticks = 0; return
      }
      if (stage === 1) {
        if (ticks < 6) return
        near(timeline._markerProgress, (59820000 + 60000) / 86400000, 0.00001,
             "marker animation reaches nearby target")
        var replacement = harness.clone(harness.normal)
        replacement.revision = 99
        replacement.markerWallMs = harness.wall(2,0)
        timeline.snapshot = replacement
        equal(timeline._pinnedEventKey, "", "revision replacement clears pin")
        near(timeline._markerProgress, harness.wall(2,0) / 86400000, 0.000001,
             "context replacement snaps marker")
        equal(timeline.height, Style.space(58), "pin/focus/update never changes height")
        timeline.current = false
        timeline.clearPin()
        stage = 2; ticks = 0; return
      }
      if (stage === 2) {
        if (ticks < 5) return
        var captureEvent = nightCapture._eventForKey(nightCapture._pinnedEventKey)
        var captureTarget = findObject(nightCapture,
          "eventTarget-" + captureEvent.kind + "-")
        var captureLabel = findObject(nightCapture, "pinnedEventLabel")
        var captureArrow = findObject(nightCapture, "eventArrow-" + captureEvent.kind)
        checkDetailGeometry(nightCapture, captureEvent, captureTarget, captureLabel,
                            "settled capture pin")
        near(captureArrow.opacity, 1, 0.001,
             "settled pinned arrow remains fully revealed")

        // Start a real native-delay handoff from pinned sunset to hovered
        // sunrise. The pin must remain throughout the 400 ms delay.
        var delayedHoverMouse = findObject(nightCapture, "eventMouse-sunrise")
        delayedHoverMouse.entered()
        equal(nightCapture._hoverDetailReadyKey, "",
              "native delayed hover is initially unready")
        check(captureLabel.visible, "pin remains visible at handoff start")
        check(nightCapture._displayedEventKey.indexOf("sunset:") === 0,
              "pin remains the displayed detail at handoff start")
        stage = 3; ticks = 0; return
      }
      if (stage === 3) {
        if (ticks < 1) return
        var waitingLabel = findObject(nightCapture, "pinnedEventLabel")
        equal(nightCapture._hoverDetailReadyKey, "",
              "hover remains unready at 40 ms in the native delay")
        check(waitingLabel.visible, "pin has no 40 ms blank flash")
        check(nightCapture._displayedEventKey.indexOf("sunset:") === 0,
              "pin remains displayed at 40 ms")
        check(nightCapture._revealArrows, "delay handoff keeps arrows revealed")

        // Freeze the temporal 40 ms state: the old pin is intentionally
        // still present while the native hover popup is waiting to open.
        stage = 4; ticks = 0
        captureBoard.grabToImage(function(result) {
          if (!result.saveToFile(Quickshell.env("TIMELINE_CAPTURE"))) {
            harness.fail("could not save delay-continuity fixture capture")
            return
          }
          harness.captureSaved = true
        })
        return
      }
      if (stage === 4) {
        if (nightCapture._hoverDetailReadyKey === "") {
          if (ticks > 15) harness.fail("native hover tooltip did not open after delay")
          return
        }
        var readyLabel = findObject(nightCapture, "pinnedEventLabel")
        check(nightCapture._hoverDetailReadyKey.indexOf("sunrise:") === 0,
              "native hover becomes ready only when about to show")
        check(!readyLabel.visible, "ready hover replaces pin without overlap")
        check(nightCapture._displayedEventKey.indexOf("sunrise:") === 0,
              "ready hover atomically becomes displayed detail")
        check(nightCapture._revealArrows, "ready hover keeps arrows revealed")
        near(findObject(nightCapture, "eventArrow-sunrise").opacity, 1, 0.001,
             "ready hover arrow remains fully revealed")
        findObject(nightCapture, "eventMouse-sunrise").exited()
        stage = 5; ticks = 0; return
      }
      if (stage === 5) {
        if (nightCapture._hoverDetailReadyKey !== "") {
          if (ticks > 10) harness.fail("native hover tooltip did not close")
          return
        }
        var restoredEvent = nightCapture._eventForKey(nightCapture._pinnedEventKey)
        var restoredTarget = findObject(nightCapture,
          "eventTarget-" + restoredEvent.kind + "-")
        var restoredLabel = findObject(nightCapture, "pinnedEventLabel")
        checkDetailGeometry(nightCapture, restoredEvent, restoredTarget, restoredLabel,
                            "post-hover restored pin")
        check(nightCapture._displayedEventKey.indexOf("sunset:") === 0,
              "hover leave restores pin without overlap")
        if (!harness.captureSaved) {
          if (ticks > 10) harness.fail("delay-continuity capture did not finish")
          return
        }
        console.log("TIMELINE_TEST_PASS")
        Qt.quit()
      }
      if (ticks > 100) harness.fail("stage timeout " + stage)
    }
  }
}
QML

OUTPUT="$TMP/output.log"
set +e
timeout 15s env \
  HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config" \
  XDG_CACHE_HOME="$TMP/home/.cache" XDG_STATE_HOME="$TMP/home/.local/state" \
  XDG_RUNTIME_DIR="$TMP/runtime" QT_QPA_PLATFORM=offscreen QT_SCALE_FACTOR=1 \
  TIMELINE_CAPTURE="$CAPTURE" \
  quickshell --no-color -p "$TMP/qml/shell.qml" >"$OUTPUT" 2>&1
RC=$?
set -e
if [[ $RC -ne 0 ]] || ! grep -q 'TIMELINE_TEST_PASS' "$OUTPUT"; then
  cat "$OUTPUT" >&2
  printf 'qml-timeline-test: FAIL\n' >&2
  exit 1
fi
if grep -Eiq 'TIMELINE_TEST_FAIL|TypeError|ReferenceError|is not a type|Cannot assign|Unable to assign|binding loop|NaN|Infinity' "$OUTPUT"; then
  cat "$OUTPUT" >&2
  printf 'qml-timeline-test: FAIL: QML runtime warning/error\n' >&2
  exit 1
fi
[[ -s $CAPTURE ]] || { printf 'qml-timeline-test: FAIL: missing capture %s\n' "$CAPTURE" >&2; exit 1; }
if command -v identify >/dev/null 2>&1; then
  read -r WIDTH HEIGHT < <(identify -format '%w %h\n' "$CAPTURE")
  [[ $WIDTH -eq 560 && $HEIGHT -eq 430 ]] || {
    printf 'qml-timeline-test: FAIL: capture geometry %sx%s\n' "$WIDTH" "$HEIGHT" >&2
    exit 1
  }
fi
if [[ ${UPDATE_TIMELINE_REFERENCE:-0} == 1 ]]; then
  mkdir -p -- "$(dirname -- "$REFERENCE")"
  cp "$CAPTURE" "$REFERENCE"
fi
[[ -s $REFERENCE ]] || {
  printf 'qml-timeline-test: FAIL: missing frozen reference %s\n' "$REFERENCE" >&2
  exit 1
}
if command -v magick >/dev/null 2>&1; then
  METRIC=$(magick compare -metric RMSE "$REFERENCE" "$CAPTURE" null: 2>&1 || true)
  NORMALIZED=$(printf '%s\n' "$METRIC" | sed -nE 's/.*\(([0-9.]+)\).*/\1/p')
  [[ -n $NORMALIZED ]] || { printf 'qml-timeline-test: FAIL: capture comparison failed\n' >&2; exit 1; }
  awk -v value="$NORMALIZED" 'BEGIN { exit !(value <= 0.03) }' || {
    printf 'qml-timeline-test: FAIL: frozen capture changed (RMSE=%s)\n' "$NORMALIZED" >&2
    exit 1
  }
fi
printf 'qml-timeline-test: capture %s\n' "$CAPTURE"
printf 'qml-timeline-test: PASS\n'
