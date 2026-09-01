#!/usr/bin/env bash
# Atomic civil-timeline and isolated lunar Service integration.  The controller,
# location store, backend, HOME, and runtime are all fake/private.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/qml" "$TMP/state/omarchy/settings" "$TMP/runtime"
chmod 700 "$TMP/runtime"
cp "$ROOT/Service.qml" "$ROOT/SolarModel.js" "$ROOT/ScheduleModel.js" \
  "$ROOT/LocationModel.js" "$ROOT/TimelineModel.js" "$ROOT/MoonModel.js" "$TMP/qml/"

python - "$TMP/private-state.json" <<'PY'
import json, pathlib, sys
location = {
    "label": "Timeline fixture", "admin1": "", "country": "",
    "latitude": 0, "longitude": 0, "timezone": "Etc/UTC",
    "source": "manual-coordinates", "precision": "coordinates",
    "observedAt": "2026-09-01T00:00:00Z",
}
pathlib.Path(sys.argv[1]).write_text(json.dumps({
    "schemaVersion": 1, "revision": 1, "mode": "manual",
    "autoConsentVersion": 0, "manual": location,
    "weatherCache": None, "autoIpCache": None,
}))
PY
: >"$TMP/controller.log"

cat >"$TMP/qml/Controller.py" <<'PY'
#!/usr/bin/env python3
import datetime as dt
import json
import os
import pathlib
import sys
import threading
import time
from zoneinfo import ZoneInfo

log_path = pathlib.Path(os.environ["FAKE_CONTROLLER_LOG"])
state_path = pathlib.Path(os.environ["FAKE_PRIVATE_STATE"])
output_lock = threading.Lock()
bounds_seen = {}
project_seen = 0
cold_field = os.environ.get("FAKE_COLD_FIELD", "marker")
cold_error = os.environ.get("FAKE_COLD_ERROR", "")
UTC = dt.timezone.utc
EPOCH = dt.datetime(1970, 1, 1, tzinfo=UTC)

def emit(value):
    with output_lock:
        print(json.dumps(value, separators=(",", ":")), flush=True)

def log(value):
    with log_path.open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(value, separators=(",", ":")) + "\n")

def epoch_datetime(epoch_ms, zone):
    return (EPOCH + dt.timedelta(milliseconds=epoch_ms)).astimezone(zone)

def epoch_ms(value):
    delta = value.astimezone(UTC) - EPOCH
    return (delta.days * 86400 + delta.seconds) * 1000 + delta.microseconds // 1000

def projected(epoch, zone):
    value = epoch_datetime(epoch, zone)
    offset = value.utcoffset()
    return {
        "epochMs": epoch,
        "dateKey": value.date().isoformat(),
        "wallMs": ((value.hour * 60 + value.minute) * 60 + value.second) * 1000
                  + value.microsecond // 1000,
        "offsetMinutes": int(offset.total_seconds() / 60),
        "fold": value.fold,
        "ambiguous": False,
    }

def projection(request):
    zone_id = request.get("zoneId") or "Etc/UTC"
    zone = ZoneInfo(zone_id)
    now = epoch_datetime(request["nowMs"], zone)
    start = dt.datetime.combine(now.date(), dt.time(), tzinfo=zone)
    end = dt.datetime.combine(now.date() + dt.timedelta(days=1), dt.time(), tzinfo=zone)
    events = []
    for item in request.get("events", []):
        value = projected(item["epochMs"], zone)
        if value["dateKey"] == now.date().isoformat():
            events.append({"kind": item["kind"], **value})
    events.sort(key=lambda item: item["epochMs"])
    display = {}
    for key, value in request.get("displayTimes", {}).items():
        display[key] = None if value is None else projected(value, zone)
    marker = projected(request["nowMs"], zone)
    result = {
        "dateKey": now.date().isoformat(), "zoneId": zone_id,
        "zoneSource": "location", "dayStartMs": epoch_ms(start),
        "dayEndMs": epoch_ms(end), "markerWallMs": marker["wallMs"],
        "markerOffsetMinutes": marker["offsetMinutes"],
        "markerFold": marker["fold"], "markerAmbiguous": False,
        "events": events, "displayTimes": display,
    }
    # Cold startup receives one malformed bounds shell, then a clean eventless
    # retry from which Service can publish neutral without becoming timezone
    # authority. Replacement cases corrupt each civil-shell field while a prior
    # valid normal snapshot exists. GMT-3 keeps the separate malformed-final gate.
    if not request.get("events"):
        bounds_seen[zone_id] = bounds_seen.get(zone_id, 0) + 1
        if zone_id == "Etc/UTC" and bounds_seen[zone_id] <= 2:
            if cold_field == "date":
                result["dateKey"] = "2026-9-01"
            elif cold_field == "zone":
                result["zoneId"] = ""
            elif cold_field == "marker":
                result["markerWallMs"] = 86400000
            elif cold_field == "offset":
                result["markerOffsetMinutes"] = 1441
            elif cold_field == "fold":
                result["markerFold"] = 2
        elif zone_id == "Etc/GMT-4":
            result["dateKey"] = "2026-9-01"
        elif zone_id == "Etc/GMT-5":
            result["zoneId"] = ""
        elif zone_id == "Etc/GMT-6":
            result["markerWallMs"] = 86400000
        elif zone_id == "Etc/GMT-7":
            result["markerOffsetMinutes"] = 1441
        elif zone_id == "Etc/GMT-8":
            result["markerFold"] = 2
    if zone_id == "Etc/GMT-3" and events:
        result["markerWallMs"] = 86400000
    return result

def civil_response(request):
    return {
        "protocol": 1, "type": "civilDay",
        "requestId": request["requestId"], "generation": request["generation"],
        "projection": projection(request),
    }

emit({"protocol": 1, "type": "ready", "daemonPid": 1234, "available": True})
for line in sys.stdin:
    request = json.loads(line)
    log(request)
    common = {"protocol": 1, "requestId": request["requestId"],
              "generation": request["generation"]}
    operation = request["operation"]
    if operation == "readLocationState":
        # Leaves a deterministic startup window in which lunar data must
        # already exist while controller/location initialization is incomplete.
        time.sleep(0.20)
        emit({**common, "type": "locationState", "outcome": "valid",
              "state": json.loads(state_path.read_text())})
    elif operation == "probe":
        emit({**common, "type": "backendStatus", "available": True,
              "actual": {"kind": "identity", "temperature": 6500, "gamma": 100},
              "override": None, "error": None})
    elif operation == "projectCivilDay":
        project_seen += 1
        cold_eventless = request.get("zoneId") == "Etc/UTC" and not request.get("events")
        if cold_eventless and ((cold_error == "bounds" and project_seen == 1) or
                               (cold_error == "neutral" and project_seen == 2)):
            emit({**common, "type": "error", "code": "invalid-request",
                  "message": "focused cold projection error"})
            continue
        response = civil_response(request)
        # Delay only A's final response.  The reader remains live, allowing B's
        # newer generation to publish before this stale complete transaction.
        if request.get("zoneId") == "Etc/GMT-1" and request.get("events"):
            threading.Timer(0.35, lambda value=response: emit(value)).start()
        else:
            emit(response)
    else:
        emit({**common, "type": "error", "code": "unexpected-operation",
              "message": operation})
PY
chmod +x "$TMP/qml/Controller.py"

cat >"$TMP/qml/shell.qml" <<'QML'
import QtQuick
import Quickshell
import "."

ShellRoot {
  id: harness
  property bool failed: false
  function fail(message) {
    if (failed) return
    failed = true
    console.error("TIMELINE_SERVICE_TEST_FAIL", message)
    Qt.quit()
  }
  function check(value, message) { if (!value) fail(message) }
  function clone(value) { return JSON.parse(JSON.stringify(value)) }
  function pendingFinal(zone) {
    for (var id in service._pendingRequests) {
      var item = service._pendingRequests[id]
      if (item.operation === "projectCivilDay" && item.context &&
          item.context.stage === "final" && item.context.location &&
          item.context.location.timezone === zone) return true
    }
    return false
  }

  property QtObject fakeShell: QtObject {
    property int writes: 0
    property var shellConfig: ({version:1,bar:{layout:{left:[],center:[],right:[{
      id:"jgordijn.night-light", automationEnabled:false,
      nightTemperature:4000, transitionMinutes:45,
      stockIndicator:{choice:"keep",before:null,after:null}
    }]}},plugins:[]})
    function updateEntryInline(id, value) { writes++; return true }
  }

  Service {
    id: service
    shell: harness.fakeShell
    manifest: ({__sourceDir:Qt.resolvedUrl(".").toString().replace("file://", "")})
  }

  Timer {
    interval: 20
    running: true
    repeat: true
    property int stage: 0
    property int ticks: 0
    property bool startupMoonSeen: false
    property bool coldFallbackSeen: false
    property var malformedZones: ["Etc/GMT-4", "Etc/GMT-5", "Etc/GMT-6", "Etc/GMT-7", "Etc/GMT-8"]
    property int malformedIndex: 0
    property var baseline: null
    property int baselineRevision: -1
    property int replacementRevision: -1
    property string replacementEvents: ""

    onTriggered: {
      ticks++
      if (failed) return
      if (stage === 0) {
        if (!service.initialized && service.moonPhase && service.moonPhase.ok &&
            service.moonPhase.orientationSource === "default") startupMoonSeen = true
        if (!service.initialized || !service.timeline) {
          if (ticks > 100) harness.fail("startup timeline timeout")
          return
        }
        if (!coldFallbackSeen) {
          harness.check(service.timeline.status === "unavailable",
                        "malformed cold bounds did not publish neutral")
          harness.check(service.timeline.events.length === 0 &&
                        service.timeline.daylightSegments.length === 0 && !service.timeline.isDayNow,
                        "cold fallback retained daylight/event claims")
          harness.check(service.timeline.displayTimes.sunset === null &&
                        service.timeline.displayTimes.sunrise === null &&
                        service.timeline.displayTimes.nextBoundary === null &&
                        service.timeline.displayTimes.overrideUntil === null,
                        "cold fallback retained display claims")
          coldFallbackSeen = true
          harness.check(service._requestTimeline(), "cold fallback recovery was not requested")
          ticks = 0
          return
        }
        if (service.timeline.status === "unavailable") {
          if (ticks > 100) harness.fail("normal recovery after cold fallback timed out")
          return
        }
        harness.check(startupMoonSeen, "lunar snapshot waited for controller/location startup")
        harness.check(service.moonPhase.ok && service.moonPhase.orientationSource === "location",
                      "location orientation was not refreshed")
        harness.check(service.timeline.events.length <= 2, "more than two civil events")
        harness.check(service.timeline.dateKey && service.timeline.zoneId === "Etc/UTC",
                      "initial civil context is incomplete")
        harness.check(service.timeline.displayTimes.sunset !== undefined &&
                      service.timeline.displayTimes.sunrise !== undefined &&
                      service.timeline.displayTimes.nextBoundary !== undefined &&
                      service.timeline.displayTimes.overrideUntil !== undefined,
                      "display times were not projected atomically")
        var statusKeys = Object.keys(service.statusObject()).sort().join(",")
        harness.check(statusKeys === "actual,available,busy,error,location,mode,nextBoundary,nextUpdate,overrideUntil,phase,schemaVersion,sunrise,sunset,target",
                      "stable status schema changed: " + statusKeys)
        harness.check(service._timelineTimerInterval > 0 && service._timelineTimerInterval <= 60000,
                      "minute timer is not aligned/bounded")
        harness.check(service._lunarTimerInterval > 0 && service._lunarTimerInterval <= 900000,
                      "lunar timer is not aligned/bounded")

        // Lunar refresh has no controller, settings, schedule, or timeline side effect.
        var requests = service._requestSequence
        var writes = harness.fakeShell.writes
        var schedule = JSON.stringify(service._schedule)
        var timeline = service.timeline
        service._activeScheduleLocation.latitude = -45
        harness.check(service._refreshMoon(1788270540000), "southern lunar refresh failed")
        harness.check(service.moonPhase.orientation === "southern" &&
                      service.moonPhase.orientationSource === "location",
                      "southern orientation was not published")
        harness.check(service._requestSequence === requests && harness.fakeShell.writes === writes &&
                      JSON.stringify(service._schedule) === schedule && service.timeline === timeline,
                      "lunar refresh caused a side effect")
        service._activeScheduleLocation.latitude = 100
        harness.check(!service._refreshMoon(1788270540000), "invalid latitude was accepted")
        harness.check(JSON.stringify(service.moonPhase) ===
                      '{"ok":false,"error":"invalid-latitude","calculatedAtMs":1788270540000}',
                      "lunar failure retained fabricated fields")
        harness.check(service.scheduleTarget !== null && service.error === null,
                      "lunar failure leaked into solar/manual state")
        service._activeScheduleLocation.latitude = 0
        service._refreshMoon(Date.now())

        baseline = service.timeline
        baselineRevision = service.timeline.revision
        service._activeScheduleLocation.timezone = "Etc/GMT-1"
        harness.check(service._requestTimeline(), "replacement A was not requested")
        stage = 1; ticks = 0; return
      }
      if (stage === 1) {
        if (!pendingFinal("Etc/GMT-1")) {
          if (ticks > 50) harness.fail("delayed final A was not pending")
          return
        }
        harness.check(service.timeline === baseline, "partial bounds transaction published")
        service._activeScheduleLocation.timezone = "Etc/GMT-2"
        harness.check(service._requestTimeline(), "replacement B was not requested")
        stage = 2; ticks = 0; return
      }
      if (stage === 2) {
        if (service.timeline.zoneId !== "Etc/GMT-2" || service.timeline.status === "unavailable") {
          if (ticks > 50) harness.fail("newer replacement B did not publish")
          return
        }
        replacementRevision = service.timeline.revision
        replacementEvents = JSON.stringify(service.timeline.events)
        harness.check(replacementRevision > baselineRevision,
                      "location/zone replacement retained revision")
        stage = 3; ticks = 0; return
      }
      if (stage === 3) {
        if (ticks < 22) return
        harness.check(service.timeline.zoneId === "Etc/GMT-2" &&
                      service.timeline.revision === replacementRevision &&
                      JSON.stringify(service.timeline.events) === replacementEvents,
                      "stale delayed A replaced newer B")
        harness.check(service._requestTimeline(), "marker refresh was not requested")
        stage = 4; ticks = 0; return
      }
      if (stage === 4) {
        if (service.timeline.zoneId !== "Etc/GMT-2" || pendingFinal("Etc/GMT-2")) {
          if (ticks > 50) harness.fail("marker refresh timeout")
          return
        }
        harness.check(service.timeline.revision === replacementRevision,
                      "marker-only refresh changed revision")
        service._activeScheduleLocation.timezone = malformedZones[malformedIndex]
        harness.check(service._requestTimeline(), "malformed bounds transaction was not requested")
        stage = 5; ticks = 0; return
      }
      if (stage === 5) {
        if (!service.timeline || service.timeline.status !== "unavailable") {
          if (ticks > 50) harness.fail("malformed bounds did not publish fallback " + malformedZones[malformedIndex])
          return
        }
        harness.check(service.timeline.events.length === 0 &&
                      service.timeline.daylightSegments.length === 0 && !service.timeline.isDayNow,
                      "bounds fallback retained a solar claim")
        harness.check(service.timeline.displayTimes.sunset === null &&
                      service.timeline.displayTimes.sunrise === null &&
                      service.timeline.displayTimes.nextBoundary === null &&
                      service.timeline.displayTimes.overrideUntil === null,
                      "bounds fallback retained mixed display times")
        harness.check(service.timeline.dateKey && service.timeline.zoneId === "Etc/GMT-2" &&
                      service.timeline.markerWallMs >= 0 && service.timeline.markerWallMs < 86400000 &&
                      service.timeline.markerOffsetMinutes >= -1440 &&
                      service.timeline.markerOffsetMinutes <= 1440 &&
                      (service.timeline.markerFold === 0 || service.timeline.markerFold === 1),
                      "bounds fallback reused malformed civil shell")
        harness.check(service.error === null && service.scheduleTarget !== null,
                      "bounds failure invalidated working schedule")
        service._activeScheduleLocation.timezone = "Etc/GMT-2"
        harness.check(service._requestTimeline(), "normal bounds recovery was not requested")
        stage = 6; ticks = 0; return
      }
      if (stage === 6) {
        if (service.timeline.zoneId !== "Etc/GMT-2" || service.timeline.status === "unavailable") {
          if (ticks > 50) harness.fail("normal recovery after malformed bounds timed out")
          return
        }
        malformedIndex++
        if (malformedIndex < malformedZones.length) {
          service._activeScheduleLocation.timezone = malformedZones[malformedIndex]
          harness.check(service._requestTimeline(), "next malformed bounds transaction was not requested")
          stage = 5; ticks = 0; return
        }
        service._activeScheduleLocation.timezone = "Etc/GMT-3"
        harness.check(service._requestTimeline(), "malformed final transaction was not requested")
        stage = 7; ticks = 0; return
      }
      if (stage === 7) {
        if (!service.timeline || service.timeline.status !== "unavailable") {
          if (ticks > 50) harness.fail("malformed final did not publish fallback")
          return
        }
        harness.check(service.timeline.events.length === 0 &&
                      service.timeline.daylightSegments.length === 0 && !service.timeline.isDayNow,
                      "final fallback retained a solar claim")
        harness.check(service.timeline.displayTimes.sunset === null &&
                      service.timeline.displayTimes.sunrise === null &&
                      service.timeline.displayTimes.nextBoundary === null &&
                      service.timeline.displayTimes.overrideUntil === null,
                      "final fallback retained mixed display times")
        harness.check(service.error === null && service.scheduleTarget !== null,
                      "final timeline failure invalidated working schedule")
        console.log("TIMELINE_SERVICE_TEST_PASS")
        Qt.quit()
      }
      if (ticks > 120) harness.fail("stage timeout " + stage)
    }
  }
}
QML

OUTPUT="$TMP/output.log"
set +e
timeout 12s env \
  HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" XDG_RUNTIME_DIR="$TMP/runtime" \
  FAKE_CONTROLLER_LOG="$TMP/controller.log" FAKE_PRIVATE_STATE="$TMP/private-state.json" \
  FAKE_COLD_FIELD="marker" QT_QPA_PLATFORM=offscreen \
  quickshell --no-color -p "$TMP/qml/shell.qml" >"$OUTPUT" 2>&1
RC=$?
set -e
if [[ $RC -ne 0 ]] || ! grep -q 'TIMELINE_SERVICE_TEST_PASS' "$OUTPUT"; then
  cat "$OUTPUT" >&2
  echo "qml-timeline-service-test: FAIL" >&2
  exit 1
fi
if grep -Eiq 'TIMELINE_SERVICE_TEST_FAIL|TypeError|ReferenceError|is not a type|Cannot assign|Unable to assign|binding loop' "$OUTPUT"; then
  cat "$OUTPUT" >&2
  echo "qml-timeline-service-test: FAIL: QML runtime warning/error" >&2
  exit 1
fi

python - "$TMP/controller.log" <<'PY'
import json, pathlib, sys
rows = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
ops = [row["operation"] for row in rows]
assert ops.count("readLocationState") == 1, ops
assert ops.count("probe") >= 1, ops
assert "setDesired" not in ops, ops
assert "writeLocationState" not in ops, ops
assert "geocode" not in ops and "autoLocate" not in ops, ops
projects = [row for row in rows if row["operation"] == "projectCivilDay"]
assert len(projects) >= 21, len(projects)
assert all(len(row.get("events", [])) <= 2 for row in projects), projects
assert sum(row.get("zoneId") == "Etc/UTC" and not row.get("events") for row in projects) >= 3
assert any(row.get("zoneId") == "Etc/GMT-1" and row.get("events") for row in projects)
assert any(row.get("zoneId") == "Etc/GMT-2" and row.get("events") for row in projects)
assert any(row.get("zoneId") == "Etc/GMT-3" and row.get("events") for row in projects)
for zone in ["Etc/GMT-4", "Etc/GMT-5", "Etc/GMT-6", "Etc/GMT-7", "Etc/GMT-8"]:
    assert any(row.get("zoneId") == zone and not row.get("events") for row in projects), zone
generations = [row["generation"] for row in projects]
assert generations == sorted(generations) and len(set(generations)) == len(generations), generations
PY

# Recreate Service from a true cold state for every malformed civil-shell field.
# In each run both the bounds response and the one bounded neutral retry remain
# malformed; the second failure must still publish a complete deterministic
# unavailable snapshot rather than leaving timeline null.
cat >"$TMP/qml/cold-shell.qml" <<'QML'
import QtQuick
import Quickshell
import "."

ShellRoot {
  id: harness
  readonly property string field: Quickshell.env("FAKE_COLD_FIELD")
  function fail(message) {
    console.error("COLD_TIMELINE_TEST_FAIL", field, message)
    Qt.quit()
  }
  property QtObject fakeShell: QtObject {
    property var shellConfig: ({version:1,bar:{layout:{left:[],center:[],right:[{
      id:"jgordijn.night-light", automationEnabled:false,
      nightTemperature:4000, transitionMinutes:45,
      stockIndicator:{choice:"keep",before:null,after:null}
    }]}},plugins:[]})
    function updateEntryInline(id, value) { return true }
  }
  Service {
    id: service
    shell: harness.fakeShell
    manifest: ({__sourceDir:Qt.resolvedUrl(".").toString().replace("file://", "")})
  }
  Timer {
    interval: 20
    running: true
    repeat: true
    property int ticks: 0
    onTriggered: {
      ticks++
      if (!service.timeline) {
        if (ticks > 100) harness.fail("timeline remained null")
        return
      }
      var value = service.timeline
      if (value.status !== "unavailable" || value.stateAtMidnight !== null ||
          value.isDayNow || value.events.length !== 0 || value.daylightSegments.length !== 0)
        return harness.fail("fallback retained a solar claim")
      if (value.displayTimes.sunset !== null || value.displayTimes.sunrise !== null ||
          value.displayTimes.nextBoundary !== null || value.displayTimes.overrideUntil !== null)
        return harness.fail("fallback retained a display claim")
      if (!value.dateKey || !value.zoneId ||
          value.markerWallMs < 0 || value.markerWallMs >= 86400000 ||
          value.markerOffsetMinutes < -1440 || value.markerOffsetMinutes > 1440 ||
          (value.markerFold !== 0 && value.markerFold !== 1) ||
          typeof value.markerAmbiguous !== "boolean")
        return harness.fail("fallback civil shell is invalid")
      if (field === "zone") {
        if (value.zoneId !== "UTC" || value.zoneSource !== "system" ||
            value.dateKey !== "1970-01-01" || value.markerWallMs !== 0)
          return harness.fail("invalid zone did not use deterministic sentinel")
      } else if (value.zoneId !== "Etc/UTC" || value.zoneSource !== "location") {
        return harness.fail("valid controller timezone authority was discarded")
      }
      if (field === "date" && value.dateKey !== "1970-01-01")
        return harness.fail("invalid date was retained")
      if ((field === "marker" || field === "offset" || field === "fold") &&
          (value.markerWallMs !== 0 || value.markerOffsetMinutes !== 0 || value.markerFold !== 0))
        return harness.fail("malformed marker tuple was partially retained")
      if (service.error !== null || service.scheduleTarget === null)
        return harness.fail("fallback leaked into schedule/backend truth")
      console.log("COLD_TIMELINE_TEST_PASS", field)
      Qt.quit()
    }
  }
}
QML

for field in date zone marker offset fold; do
  COLD_OUTPUT="$TMP/cold-$field.log"
  COLD_CONTROLLER_LOG="$TMP/cold-controller-$field.log"
  : >"$COLD_CONTROLLER_LOG"
  set +e
  timeout 5s env \
    HOME="$TMP/home-$field" XDG_STATE_HOME="$TMP/state" XDG_RUNTIME_DIR="$TMP/runtime" \
    FAKE_CONTROLLER_LOG="$COLD_CONTROLLER_LOG" FAKE_PRIVATE_STATE="$TMP/private-state.json" \
    FAKE_COLD_FIELD="$field" QT_QPA_PLATFORM=offscreen \
    quickshell --no-color -p "$TMP/qml/cold-shell.qml" >"$COLD_OUTPUT" 2>&1
  COLD_RC=$?
  set -e
  if [[ $COLD_RC -ne 0 ]] || ! grep -q "COLD_TIMELINE_TEST_PASS $field" "$COLD_OUTPUT"; then
    cat "$COLD_OUTPUT" >&2
    echo "qml-timeline-service-test: FAIL: persistent cold $field" >&2
    exit 1
  fi
  if grep -Eiq 'COLD_TIMELINE_TEST_FAIL|TypeError|ReferenceError|is not a type|Cannot assign|Unable to assign|binding loop' "$COLD_OUTPUT"; then
    cat "$COLD_OUTPUT" >&2
    echo "qml-timeline-service-test: FAIL: persistent cold $field warning/error" >&2
    exit 1
  fi
  python - "$COLD_CONTROLLER_LOG" <<'PY'
import json, pathlib, sys
rows = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
projects = [row for row in rows if row["operation"] == "projectCivilDay"]
assert len(projects) == 2, projects
assert all(not row.get("events") and row.get("displayTimes") == {} for row in projects), projects
assert projects[1]["generation"] > projects[0]["generation"], projects
assert not any(row["operation"] in {"setDesired", "writeLocationState", "geocode", "autoLocate"}
               for row in rows), rows
PY
done

# Protocol/controller errors use the identical two-generation cold path.  The
# bounds-error case proves admission of one neutral request; the neutral-error
# case proves that its correlated terminal error publishes deterministically.
for error_stage in bounds neutral; do
  if [[ $error_stage == bounds ]]; then
    field=none
  else
    field=marker
  fi
  ERROR_OUTPUT="$TMP/cold-error-$error_stage.log"
  ERROR_CONTROLLER_LOG="$TMP/cold-error-controller-$error_stage.log"
  : >"$ERROR_CONTROLLER_LOG"
  set +e
  timeout 5s env \
    HOME="$TMP/home-error-$error_stage" XDG_STATE_HOME="$TMP/state" XDG_RUNTIME_DIR="$TMP/runtime" \
    FAKE_CONTROLLER_LOG="$ERROR_CONTROLLER_LOG" FAKE_PRIVATE_STATE="$TMP/private-state.json" \
    FAKE_COLD_FIELD="$field" FAKE_COLD_ERROR="$error_stage" QT_QPA_PLATFORM=offscreen \
    quickshell --no-color -p "$TMP/qml/cold-shell.qml" >"$ERROR_OUTPUT" 2>&1
  ERROR_RC=$?
  set -e
  if [[ $ERROR_RC -ne 0 ]] || ! grep -q "COLD_TIMELINE_TEST_PASS $field" "$ERROR_OUTPUT"; then
    cat "$ERROR_OUTPUT" >&2
    echo "qml-timeline-service-test: FAIL: cold $error_stage error" >&2
    exit 1
  fi
  if grep -Eiq 'COLD_TIMELINE_TEST_FAIL|TypeError|ReferenceError|is not a type|Cannot assign|Unable to assign|binding loop' "$ERROR_OUTPUT"; then
    cat "$ERROR_OUTPUT" >&2
    echo "qml-timeline-service-test: FAIL: cold $error_stage error warning/error" >&2
    exit 1
  fi
  python - "$ERROR_CONTROLLER_LOG" "$error_stage" <<'PY'
import json, pathlib, sys
rows = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
projects = [row for row in rows if row["operation"] == "projectCivilDay"]
assert len(projects) == 2, (sys.argv[2], projects)
assert [row["generation"] for row in projects] == [3, 4], (sys.argv[2], projects)
assert [row["requestId"] for row in projects] == ["qml-3", "qml-4"], (sys.argv[2], projects)
assert all(not row.get("events") and row.get("displayTimes") == {} for row in projects), projects
assert not any(row["operation"] in {"setDesired", "writeLocationState", "geocode", "autoLocate"}
               for row in rows), rows
PY
done

printf 'qml-timeline-service-test: PASS\n'
