#!/usr/bin/env bash
# Persisted-first Warmth harness. All controller/display traffic is fake and
# isolated; this test never imports the real Controller.py or reaches Hyprland.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/qml" "$TMP/state/omarchy/settings" "$TMP/runtime"
chmod 700 "$TMP/runtime"
cp "$ROOT/Service.qml" "$ROOT/SolarModel.js" "$ROOT/ScheduleModel.js" "$ROOT/LocationModel.js" \
  "$ROOT/TimelineModel.js" "$ROOT/MoonModel.js" "$TMP/qml/"

FIXTURES=$(node - "$TMP/private-state.json" <<'JS'
const fs = require('fs')
const Solar = require('./SolarModel.js')
const Schedule = require('./ScheduleModel.js')
const statePath = process.argv[2]
const now = Date.now()
const settings = {automationEnabled:true, nightTemperature:4000, transitionMinutes:45}
const found = {}
for (let longitude = -180; longitude <= 180 && Object.keys(found).length < 4; longitude += 0.25) {
  const location = {latitude:0, longitude, timezone:'Etc/UTC'}
  const result = Schedule.evaluate(now, Solar.surroundingEvents(now, 0, longitude), settings)
  const transition = result.phase === 'evening-transition' || result.phase === 'morning-transition'
  if (result.ok && ['day','night','evening-transition','morning-transition'].includes(result.phase) &&
      (!transition || (result.warmth > 0.25 && result.warmth < 0.75)) && !found[result.phase])
    found[result.phase] = location
}
for (const phase of ['day','night','evening-transition','morning-transition']) {
  if (!found[phase]) throw new Error('could not construct ' + phase + ' fixture')
}
const initial = found.day
const location = {
  label:'Live preview fixture', admin1:'', country:'', latitude:initial.latitude,
  longitude:initial.longitude, timezone:'Etc/UTC', source:'manual-coordinates',
  precision:'coordinates', observedAt:new Date(now).toISOString()
}
fs.writeFileSync(statePath, JSON.stringify({
  schemaVersion:1, revision:1, mode:'manual', autoConsentVersion:0,
  manual:location, weatherCache:null, autoIpCache:null
}))
process.stdout.write(JSON.stringify(found))
JS
)
: >"$TMP/persisted.json"
: >"$TMP/controller.log"

cat >"$TMP/qml/Controller.py" <<'PY'
#!/usr/bin/env python3
import json, os, pathlib, sys

log_path = pathlib.Path(os.environ["FAKE_CONTROLLER_LOG"])
state_path = pathlib.Path(os.environ["FAKE_PRIVATE_STATE"])
marker_path = pathlib.Path(os.environ["FAKE_PERSIST_MARKER"])

def emit(value):
    print(json.dumps(value, separators=(",", ":")), flush=True)

def log(value):
    with log_path.open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(value, separators=(",", ":")) + "\n")

actual = {"kind":"identity","temperature":6500,"gamma":100}
failed_once = False
emit({"protocol":1,"type":"ready","daemonPid":1234,"available":True})
for line in sys.stdin:
    request = json.loads(line)
    common = {"protocol":1,"requestId":request["requestId"],"generation":request["generation"]}
    operation = request["operation"]
    if operation == "readLocationState":
        emit({**common,"type":"locationState","outcome":"valid","state":json.loads(state_path.read_text())})
    elif operation == "probe":
        emit({**common,"type":"backendStatus","available":True,
              "actual":actual,"override":None,"error":None})
    elif operation == "setDesired":
        # FileView.setText is Omarchy's write primitive. Its marker must already
        # contain the complete canonical transaction when controller traffic arrives.
        persisted = json.loads(marker_path.read_text())
        row = dict(request)
        row["persistedAtSubmission"] = persisted
        desired = request["desired"]
        if desired.get("temperature") == 3250 and not failed_once:
            failed_once = True
            guarded = request["ifActual"]
            actual = {"kind":guarded["kind"],"temperature":guarded.get("temperature",6500),"gamma":100}
            row["outcome"] = "failed"
            log(row)
            emit({**common,"type":"backendStatus","available":False,
                  "actual":actual,"override":None,"error":"apply-failed"})
        else:
            actual = {"kind":desired["kind"],"temperature":desired.get("temperature",6500),"gamma":100}
            row["outcome"] = "applied"
            log(row)
            emit({**common,"type":"backendStatus","available":True,
                  "actual":actual,"override":None,"error":None})
    elif operation == "cancel":
        emit({**common,"type":"networkResult","cancelled":True})
    else:
        emit({**common,"type":"error","code":"unknown-operation","message":"unexpected fake operation"})
PY
chmod +x "$TMP/qml/Controller.py"

cat >"$TMP/qml/shell.qml" <<'QML'
import QtQuick
import Quickshell
import Quickshell.Io
import "."

ShellRoot {
  id: harness
  property var fixtures: JSON.parse(Quickshell.env("FAKE_FIXTURES"))
  property bool failed: false

  function fail(message) {
    if (failed) return
    failed = true
    console.error("LIVE_PREVIEW_TEST_FAIL", message)
    Qt.quit()
  }
  function check(value, message) { if (!value) fail(message) }
  function clone(value) { return JSON.parse(JSON.stringify(value)) }

  FileView { id: persistMarker; path: Quickshell.env("FAKE_PERSIST_MARKER"); printErrors: true }

  property QtObject fakeShell: QtObject {
    property int writes: 0
    property var shellConfig: ({version:1, bar:{layout:{left:[],center:[],right:[{
      id:"jgordijn.night-light", automationEnabled:true, nightTemperature:4000,
      transitionMinutes:45, unrelatedKey:{keep:"yes"},
      stockIndicator:{choice:"keep",before:null,after:null}
    }]}},plugins:[]})
    function updateEntryInline(id, value) {
      writes++
      var copy = harness.clone(value)
      // Model Omarchy's synchronous canonical publication before initiating
      // FileView.setText, including preservation of unrelated inline keys.
      shellConfig = ({version:1,bar:{layout:{left:[],center:[],right:[copy]}},plugins:[]})
      persistMarker.setText(JSON.stringify(copy))
      return true
    }
  }

  Service {
    id: service
    shell: harness.fakeShell
    manifest: ({__sourceDir:Qt.resolvedUrl(".").toString().replace("file://", "")})
  }

  Timer {
    id: test
    interval: 30
    repeat: true
    running: true
    property int stage: 0
    property int ticks: 0

    function location(name) {
      var item = harness.clone(harness.fixtures[name])
      item.label = name
      item.source = "manual-coordinates"
      item.precision = "coordinates"
      item.observedAt = "2026-09-01T00:00:00Z"
      return item
    }

    function settings(temperature, automatic) {
      return {
        automationEnabled: automatic,
        nightTemperature: temperature,
        transitionMinutes: 45,
        stockIndicator: {choice:"keep",before:null,after:null}
      }
    }

    function prepare(name, temperature, automatic, backendAvailable, backendProbed, overrideValue) {
      var loc = location(name)
      service._activeScheduleLocation = loc
      service._committedLocation = harness.clone(loc)
      service._settings = settings(temperature, automatic)
      service._inlineEntry = ({
        id:"jgordijn.night-light", automationEnabled:automatic,
        nightTemperature:temperature, transitionMinutes:45,
        unrelatedKey:{keep:"yes"}, stockIndicator:{choice:"keep",before:null,after:null}
      })
      var calculated = service._calculate(Date.now(), loc)
      harness.check(calculated.ok && calculated.phase === name,
                    "fixture phase " + name + " became " + calculated.phase)
      service._schedule = calculated
      service._scheduleValid = true
      service._backendAvailable = backendAvailable
      service._backendProbed = backendProbed
      service._override = overrideValue
      service._actual = ({kind:calculated.target.kind,
        temperature:calculated.target.temperature,gamma:100})
      service._applyBusy = false
    }

    function one(name, temperature, direction, automatic, backendAvailable, backendProbed,
                 overrideValue, expectSend) {
      prepare(name, temperature, automatic, backendAvailable, backendProbed, overrideValue)
      var requests = service._requestSequence
      var writes = harness.fakeShell.writes
      var expected = temperature + direction * 250
      var overrideBefore = JSON.stringify(service._override)
      harness.check(service.stepNightTemperature(direction) === true,
                    name + " step was rejected")
      harness.check(service.inlineSettings.nightTemperature === expected,
                    name + " canonical setting was not immediate")
      harness.check(service.settings.nightTemperature === expected,
                    name + " validated setting was not immediate")
      harness.check(service.inlineSettings.unrelatedKey.keep === "yes",
                    name + " dropped an unrelated inline key")
      harness.check(harness.fakeShell.writes === writes + 1,
                    name + " did not initiate exactly one persistence write")
      harness.check(service._requestSequence === requests + (expectSend ? 1 : 0),
                    name + " controller submission predicate was wrong")
      if (overrideValue)
        harness.check(JSON.stringify(service._override) === overrideBefore,
                      name + " changed the exact override")
      if (expectSend) {
        harness.check(service.scheduleTarget.kind === "temperature",
                      name + " sent a non-temperature target")
        if (name.indexOf("transition") >= 0) {
          harness.check(service.scheduleTarget.temperature % 10 === 0,
                        name + " target was not quantized to 10 K")
          harness.check(service.scheduleTarget.temperature !== expected,
                        name + " jumped directly to the endpoint Kelvin")
        }
      }
    }

    onTriggered: {
      ticks++
      if (failed) return
      if (stage === 0) {
        if (!service.initialized || service.busy || service.mode !== "scheduled") {
          if (ticks > 100) harness.fail("startup timeout")
          return
        }
        one("night", 4000, -1, true, true, true, null, true)
        stage = 1; ticks = 0; return
      }
      if (stage === 1 && !service._applyBusy) {
        one("evening-transition", 3750, 1, true, true, true, null, true)
        stage = 2; ticks = 0; return
      }
      if (stage === 2 && !service._applyBusy) {
        one("morning-transition", 4000, -1, true, true, true, null, true)
        stage = 3; ticks = 0; return
      }
      if (stage === 3 && !service._applyBusy) {
        one("day", 3750, 1, true, true, true, null, false)
        one("night", 4000, -1, false, true, true, null, false)
        var held = {target:{kind:"temperature",temperature:3333},until:987654,source:"external"}
        one("night", 3750, 1, true, true, true, held, false)
        one("night", 4000, -1, true, false, true, null, false)
        one("night", 3750, 1, true, true, false, null, false)

        // A failed live apply keeps the newly persisted preference while its
        // response retains the last verified actual state.
        one("night", 3500, -1, true, true, true, null, true)
        stage = 4; ticks = 0; return
      }
      if (stage === 4 && !service._applyBusy && !service._backendAvailable) {
        harness.check(service.inlineSettings.nightTemperature === 3250,
                      "failed apply rolled back the preference")
        harness.check(service.actual.temperature === 3500,
                      "failed apply published optimistic actual state")
        harness.check(service.error && service.error.code === "apply-failed",
                      "failed apply was not exposed truthfully")
        var requestsBeforeSavedOnly = service._requestSequence
        var writesBeforeSavedOnly = harness.fakeShell.writes
        harness.check(service.stepNightTemperature(-1), "failure-time latest step was rejected")
        harness.check(service.inlineSettings.nightTemperature === 3000,
                      "failure-time latest preference was not committed")
        harness.check(service._requestSequence === requestsBeforeSavedOnly,
                      "backend-unavailable edit submitted optimistically")
        harness.check(harness.fakeShell.writes === writesBeforeSavedOnly + 1,
                      "backend-unavailable edit was not persisted")
        service._probeBackend(false)
        stage = 5; ticks = 0; return
      }
      if (stage === 5 && !service._applyBusy && service._backendAvailable &&
          service.actual.temperature === 3000) {
        harness.check(service.error === null, "latest health recovery retained an error")
        prepare("night", 4000, true, true, true, null)
        var requestStart = service._requestSequence
        var writeStart = harness.fakeShell.writes
        harness.check(service.stepNightTemperature(-1), "rapid step one failed")
        harness.check(service.stepNightTemperature(-1), "rapid step two failed")
        harness.check(service.stepNightTemperature(-1), "rapid step three failed")
        harness.check(service.inlineSettings.nightTemperature === 3250,
                      "rapid steps did not commit every preference")
        harness.check(harness.fakeShell.writes === writeStart + 3,
                      "rapid steps did not initiate every persistence transaction")
        harness.check(service._requestSequence === requestStart + 3,
                      "rapid steps did not submit latest-wins generations")
        stage = 6; ticks = 0; return
      }
      if (stage === 6 && !service._applyBusy) {
        prepare("night", 6500, true, true, true, null)
        var writesAtBound = harness.fakeShell.writes
        var requestsAtBound = service._requestSequence
        harness.check(service.stepNightTemperature(1) === false, "upper bound step wrote")
        harness.check(service.stepNightTemperature(0) === false, "invalid zero direction wrote")
        harness.check(service.stepNightTemperature(1.5) === false, "fractional direction wrote")
        harness.check(service.setNightTemperature(undefined) === false, "undefined absolute setting wrote")
        harness.check(service.setNightTemperature("4000") === false, "string absolute setting wrote")
        harness.check(harness.fakeShell.writes === writesAtBound,
                      "invalid/bound steps persisted")
        harness.check(service._requestSequence === requestsAtBound,
                      "invalid/bound steps submitted")
        console.log("LIVE_PREVIEW_TEST_PASS")
        Qt.quit()
      }
      if (ticks > 100) harness.fail("stage timeout " + stage)
    }
  }
}
QML

OUTPUT="$TMP/output.log"
set +e
timeout 12s env \
  HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" XDG_RUNTIME_DIR="$TMP/runtime" \
  FAKE_CONTROLLER_LOG="$TMP/controller.log" FAKE_PRIVATE_STATE="$TMP/private-state.json" \
  FAKE_PERSIST_MARKER="$TMP/persisted.json" FAKE_FIXTURES="$FIXTURES" \
  QT_QPA_PLATFORM=offscreen quickshell --no-color -p "$TMP/qml/shell.qml" >"$OUTPUT" 2>&1
RC=$?
set -e
if [[ $RC -ne 0 ]] || ! grep -q 'LIVE_PREVIEW_TEST_PASS' "$OUTPUT"; then
  cat "$OUTPUT" >&2
  echo "qml-live-preview-test: FAIL" >&2
  exit 1
fi
if grep -Eiq 'LIVE_PREVIEW_TEST_FAIL|TypeError|ReferenceError|is not a type|Cannot assign|Unable to assign|binding loop' "$OUTPUT"; then
  cat "$OUTPUT" >&2
  echo "qml-live-preview-test: FAIL: QML runtime warning/error" >&2
  exit 1
fi

python - "$TMP/controller.log" <<'PY'
import json, pathlib, sys
rows = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
assert len(rows) == 8, rows
# Full night applies the exact committed endpoint. Both transitions use the
# fresh quantized smoothstep target rather than their newly committed endpoint.
assert rows[0]["desired"] == {"kind":"temperature","temperature":3750}, rows[0]
assert rows[1]["desired"]["kind"] == "temperature" and rows[1]["desired"]["temperature"] % 10 == 0, rows[1]
assert rows[1]["desired"]["temperature"] != 4000, rows[1]
assert rows[2]["desired"]["kind"] == "temperature" and rows[2]["desired"]["temperature"] % 10 == 0, rows[2]
assert rows[2]["desired"]["temperature"] != 3750, rows[2]
# Every mutating schedule request carries only identity/Kelvin CAS state.
assert all(set(row["ifActual"]) <= {"kind", "temperature"} for row in rows), rows
assert all("gamma" not in row["ifActual"] for row in rows), rows
# Fake Omarchy persistence was initiated before every backend submission and
# retained an unrelated inline key.
assert all(row["persistedAtSubmission"]["unrelatedKey"] == {"keep":"yes"} for row in rows), rows
# Failure retains verified actual and health recovery submits only the newest
# preference saved while unavailable, never the stale failed endpoint.
assert rows[3]["desired"]["temperature"] == 3250 and rows[3]["outcome"] == "failed", rows
assert rows[4]["desired"]["temperature"] == 3000 and rows[4]["outcome"] == "applied", rows
# Rapid steps commit all preferences while backend generations make the newest
# request authoritative. Controller.py's physical-write coalescing is covered
# by controller-test.py with a blocked/rate-limited fake backend.
assert [row["desired"]["temperature"] for row in rows[-3:]] == [3750,3500,3250], rows
assert rows[-1]["generation"] > rows[-2]["generation"] > rows[-3]["generation"], rows
PY

printf 'qml-live-preview-test: PASS\n'
