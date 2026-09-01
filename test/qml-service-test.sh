#!/usr/bin/env bash
# Bare Quickshell integration test.  All state, controller traffic and HOME are
# isolated; the fake controller never imports Controller.py or talks to Hyprland.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/qml" "$TMP/state/omarchy/settings" "$TMP/runtime"
chmod 700 "$TMP/runtime"
cp "$ROOT/Service.qml" "$ROOT/SolarModel.js" "$ROOT/ScheduleModel.js" "$ROOT/LocationModel.js" "$TMP/qml/"

# Put the test location near solar noon so the scheduled target is
# deterministically identity regardless of the CI runner's wall-clock hour.
python - "$TMP/state/omarchy/settings/weather.json" "$TMP/private-state.json" <<'PY'
import datetime, json, pathlib, sys
now = datetime.datetime.now(datetime.timezone.utc)
hours = now.hour + now.minute / 60 + now.second / 3600
longitude = ((15 * (12 - hours) + 180) % 360) - 180
weather = {"name": "Test Weather", "latitude": 0, "longitude": longitude}
pathlib.Path(sys.argv[1]).write_text(json.dumps(weather))
pathlib.Path(sys.argv[2]).write_text(json.dumps({
    "schemaVersion": 1, "revision": 4, "mode": "weather", "autoConsentVersion": 0,
    "manual": None,
    "weatherCache": {
        "label": weather["name"], "admin1": "", "country": "",
        "latitude": weather["latitude"], "longitude": weather["longitude"], "timezone": "",
        "source": "weather", "precision": "selected-locality",
        # A fresh Weather read gets a new observation time. That alone must not
        # cause a startup or hot-reload write.
        "observedAt": "2020-01-01T00:00:00Z",
    },
    "autoIpCache": None,
}))
PY

cat >"$TMP/qml/Controller.py" <<'PY'
#!/usr/bin/env python3
import json
import os
import sys
import time

log_path = os.environ["FAKE_CONTROLLER_LOG"]
state_path = os.environ["FAKE_PRIVATE_STATE"]
fail_marker = os.environ["FAKE_WRITE_FAIL_MARKER"]
def emit(value):
    print(json.dumps(value, separators=(",", ":")), flush=True)
def log(value):
    with open(log_path, "a", encoding="utf-8") as stream:
        stream.write(json.dumps(value, separators=(",", ":")) + "\n")

emit({"protocol":1,"type":"ready","daemonPid":1234,"available":True})
# This unsolicited status must not satisfy Service's explicit startup probe.
emit({"protocol":1,"type":"backendStatus","available":True,
      "actual":{"kind":"identity","temperature":6500,"gamma":100},
      "override":None,"error":None})
for line in sys.stdin:
    request = json.loads(line)
    log(request)
    common = {"protocol":1,"requestId":request["requestId"],"generation":request["generation"]}
    operation = request["operation"]
    if operation == "readLocationState":
        # Give the explicit backend probe time to complete first. A service
        # that treats Weather alone as initialized would publish during this gap.
        time.sleep(0.12)
        with open(state_path, encoding="utf-8") as stream:
            state = json.load(stream)
        emit({**common,"type":"locationState","outcome":"valid","state":state})
    elif operation == "probe":
        emit({**common,"type":"backendStatus","available":True,
              "actual":{"kind":"identity","temperature":6500,"gamma":100},
              "override":None,"error":None})
    elif operation == "writeLocationState":
        if not os.path.exists(fail_marker):
            open(fail_marker, "w", encoding="utf-8").close()
            # Leave a deterministic window for a newer QML intent to queue
            # behind this write before its failure is delivered.
            time.sleep(0.25)
            emit({**common,"type":"error","code":"state-not-writable",
                  "message":"location state could not be written"})
            continue
        # Keep the successor in flight long enough for the harness to prove
        # that the failed Weather preview was not transiently published.
        time.sleep(0.20)
        with open(state_path, encoding="utf-8") as stream:
            previous = json.load(stream)
        state = request["state"]
        state["revision"] = previous["revision"] + 1
        with open(state_path, "w", encoding="utf-8") as stream:
            json.dump(state, stream)
        emit({**common,"type":"locationState","outcome":"valid","state":state})
        # Same request id after completion is stale and must not replace the
        # committed Weather schedule.
        stale = dict(state)
        stale["mode"] = "none"
        emit({**common,"type":"locationState","outcome":"valid","state":stale})
    elif operation == "setDesired":
        emit({**common,"type":"backendStatus","available":True,
              "actual":{"kind":"identity","temperature":6500,"gamma":100},
              "override":None,"error":None})
        emit({**common,"type":"backendStatus","available":False,
              "actual":{"kind":"temperature","temperature":1234,"gamma":1},
              "override":None,"error":"apply-failed"})
    elif operation == "cancel":
        emit({**common,"type":"networkResult","cancelled":True})
PY
chmod +x "$TMP/qml/Controller.py"

cat >"$TMP/qml/shell.qml" <<'QML'
import QtQuick
import Quickshell
import Quickshell.Io
import "."

ShellRoot {
  id: harness
  property bool failed: false
  property QtObject fakeShell: QtObject {
    property var shellConfig: ({
      version: 1,
      bar: { layout: { left: [], center: [], right: [{
        id: "jgordijn.night-light", automationEnabled: true,
        nightTemperature: 4000, transitionMinutes: 45,
        stockIndicator: { choice: "pending", before: null, after: null }
      }] } },
      plugins: []
    })
    function updateEntryInline(id, value) { return true }
    function summon(id, payload) { return id === "jgordijn.night-light" }
    function hide(id) { return id === "jgordijn.night-light" }
    function toggle(id, payload) { return id === "jgordijn.night-light" }
  }

  Component {
    id: serviceComponent
    Service {
      shell: harness.fakeShell
      manifest: ({ __sourceDir: Qt.resolvedUrl(".").toString().replace("file://", "") })
    }
  }

  Loader {
    id: serviceLoader
    active: true
    sourceComponent: serviceComponent
  }

  Process {
    id: stateBreaker
    property int nextStage: 3
    command: ["/usr/bin/python", "-c",
      "import json,os,pathlib; p=os.environ['FAKE_PRIVATE_STATE']; s=json.load(open(p)); s['weatherCache']['latitude']=20; json.dump(s,open(p,'w')); pathlib.Path(os.environ['FAKE_WRITE_FAIL_MARKER']).unlink(missing_ok=True)"]
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        console.error("SERVICE_TEST_FAIL state breaker", exitCode)
        Qt.quit()
        return
      }
      serviceLoader.active = false
      serviceTest.stage = nextStage
      serviceTest.ticks = 0
      Qt.callLater(function() { serviceLoader.active = true })
    }
  }

  Process {
    id: successStateBreaker
    command: ["/usr/bin/python", "-c",
      "import json,os; p=os.environ['FAKE_PRIVATE_STATE']; s=json.load(open(p)); w=json.load(open(os.path.join(os.environ['XDG_STATE_HOME'],'omarchy/settings/weather.json'))); s['mode']='weather'; s['autoConsentVersion']=1; s['weatherCache']={'label':w['name'],'admin1':'','country':'','latitude':20,'longitude':w['longitude'],'timezone':'','source':'weather','precision':'selected-locality','observedAt':'2020-01-01T00:00:00Z'}; json.dump(s,open(p,'w'))"]
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        console.error("SERVICE_TEST_FAIL success state breaker", exitCode)
        Qt.quit()
        return
      }
      serviceLoader.active = false
      serviceTest.stage = 8
      serviceTest.ticks = 0
      Qt.callLater(function() { serviceLoader.active = true })
    }
  }

  Timer {
    id: serviceTest
    interval: 50
    running: true
    repeat: true
    property int ticks: 0
    property int stage: 0

    function good(service) {
      return service && service.initialized && !service.busy && service.available &&
        service.mode === "scheduled" && service.target && service.target.kind === "identity" &&
        service.error === null && service.actual && service.actual.kind === "identity" &&
        service.location && service.location.label === "Test Weather"
    }

    onTriggered: {
      ++ticks
      var service = serviceLoader.item
      if (stage === 0 && good(service)) {
        // Matching canonical Weather state must make cold startup observational,
        // even though this read has a newer observedAt value.
        service.refresh()
        stage = 1
        ticks = 0
        return
      }
      if (stage === 1 && ticks >= 6 && good(service)) {
        // Destroy/recreate the attachment as a focused equality regression.
        serviceLoader.active = false
        stage = 2
        ticks = 0
        Qt.callLater(function() { serviceLoader.active = true })
        return
      }
      if (stage === 2 && ticks >= 2 && good(service)) {
        // Make the saved cache usefully different and storage fail once. The
        // next startup must still install current Weather from memory.
        stage = 20
        ticks = 0
        stateBreaker.running = true
        return
      }
      var warning = service && service.error && service.error.code === "state-persistence-failed"
      var usingCurrentWeather = service && service.activeScheduleLocation &&
        Number(service.activeScheduleLocation.latitude) === 0
      if (stage === 3 && service && service.initialized && !service.busy &&
          service.mode === "scheduled" && warning && usingCurrentWeather) {
        service.refresh() // Explicitly retry the nonblocking persistence warning.
        stage = 4
        ticks = 0
        return
      }
      if (stage === 4 && ticks >= 2 && good(service) && usingCurrentWeather) {
        // Repeat the failing startup write, then queue manual B while Weather A
        // is in flight. This preserves the no-newer-intent Weather fallback
        // above and separately exercises latest-wins failure draining.
        stateBreaker.nextStage = 5
        stage = 40
        ticks = 0
        stateBreaker.running = true
        return
      }
      if (stage === 5 && service && service._initializationInFlight && service._stateBusy) {
        stage = 6
        ticks = 0
        if (!service.useManualCoordinates("10, 20") || !service._queuedStateWrite) {
          console.error("SERVICE_TEST_FAIL manual B was not queued")
          Qt.quit()
        }
        return
      }
      if (stage === 6) {
        // During B's delayed response, stale Weather A must never become the
        // active schedule merely because its persistence failed.
        if (service && service.activeScheduleLocation &&
            service.activeScheduleLocation.source === "weather") {
          console.error("SERVICE_TEST_FAIL stale Weather A published")
          Qt.quit()
          return
        }
        var manualCommitted = service && service.initialized && !service.busy &&
          service.mode === "scheduled" && service.error === null &&
          service.privateLocationState && service.privateLocationState.mode === "manual" &&
          service.activeScheduleLocation && service.activeScheduleLocation.source === "manual-coordinates" &&
          Number(service.activeScheduleLocation.latitude) === 10 &&
          Number(service.activeScheduleLocation.longitude) === 20
        if (manualCommitted) {
          // Restore a stale Weather state without resetting the write-failure
          // marker. Startup Weather A will now succeed while manual B queues.
          stage = 70
          ticks = 0
          successStateBreaker.running = true
          return
        }
      }
      if (stage === 8 && service && service._initializationInFlight && service._stateBusy) {
        stage = 9
        ticks = 0
        if (!service.useManualCoordinates("30, 40") || !service._queuedStateWrite) {
          console.error("SERVICE_TEST_FAIL success-path manual B was not queued")
          Qt.quit()
        }
        return
      }
      if (stage === 9) {
        var successRebaseCommitted = service && service.initialized && !service.busy &&
          service.mode === "scheduled" && service.error === null &&
          service.privateLocationState && service.privateLocationState.mode === "manual" &&
          service.privateLocationState.revision === 8 &&
          service.privateLocationState.autoConsentVersion === 1 &&
          service.privateLocationState.weatherCache &&
          Number(service.privateLocationState.weatherCache.latitude) === 0 &&
          service.activeScheduleLocation && service.activeScheduleLocation.source === "manual-coordinates" &&
          Number(service.activeScheduleLocation.latitude) === 30 &&
          Number(service.activeScheduleLocation.longitude) === 40
        if (successRebaseCommitted) {
          console.log("SERVICE_TEST_PASS", JSON.stringify(service.statusObject()))
          Qt.quit()
          return
        }
      }
      if (ticks > 120) {
        console.error("SERVICE_TEST_FAIL timeout", service ? JSON.stringify(service.statusObject()) : "no service")
        Qt.quit()
      }
    }
  }
}
QML

OUTPUT="$TMP/output.log"
set +e
timeout 12s env \
  HOME="$TMP/home" \
  XDG_STATE_HOME="$TMP/state" \
  XDG_RUNTIME_DIR="$TMP/runtime" \
  FAKE_CONTROLLER_LOG="$TMP/controller.log" \
  FAKE_PRIVATE_STATE="$TMP/private-state.json" \
  FAKE_WRITE_FAIL_MARKER="$TMP/write-failed-once" \
  QT_QPA_PLATFORM=offscreen \
  quickshell --no-color -p "$TMP/qml/shell.qml" >"$OUTPUT" 2>&1
RC=$?
set -e
if [[ $RC -ne 0 ]]; then
  cat "$OUTPUT" >&2
  echo "qml-service-test: FAIL: Quickshell exited $RC" >&2
  exit 1
fi
if ! grep -q 'SERVICE_TEST_PASS' "$OUTPUT"; then
  cat "$OUTPUT" >&2
  echo "qml-service-test: FAIL: harness did not pass" >&2
  exit 1
fi
if grep -Eiq 'SERVICE_TEST_FAIL|TypeError|ReferenceError|is not a type|Cannot assign|Unable to assign|binding loop' "$OUTPUT"; then
  cat "$OUTPUT" >&2
  echo "qml-service-test: FAIL: QML runtime warning/error" >&2
  exit 1
fi

python - "$TMP/controller.log" <<'PY'
import json, pathlib, sys
rows = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
ops = [row["operation"] for row in rows]
# Cold startup and one hot reload have canonically equal Weather caches and
# issue no private write. The third startup has a useful cache change: its first
# write fails, the schedule still runs from memory, and refresh retries once.
# On the fourth startup, manual B queues behind failing Weather A and must be
# sent immediately without ever publishing A's otherwise-useful preview. On
# the fifth, Weather A succeeds before queued manual B; B must be canonically
# rebased onto committed A rather than merely having its revision rewritten.
assert ops.count("readLocationState") == 5, ops
assert ops.count("probe") >= 7, ops
assert ops.count("writeLocationState") == 6, ops
assert ops.count("setDesired") == 0, ops
first_write = ops.index("writeLocationState")
assert ops[:first_write].count("readLocationState") == 3, ops
writes = [row for row in rows if row["operation"] == "writeLocationState"]
assert [row["state"]["mode"] for row in writes] == [
    "weather", "weather", "weather", "manual", "weather", "manual"
], writes
assert all(row["state"]["weatherCache"]["label"] == "Test Weather" for row in writes[:3])
assert all(row["state"]["weatherCache"]["latitude"] == 0 for row in writes[:3])
assert [row["expectedRevision"] for row in writes] == [4, 4, 5, 5, 6, 7], writes
assert writes[3]["state"]["revision"] == 5, writes[3]
assert writes[3]["state"]["manual"]["latitude"] == 10, writes[3]
assert writes[3]["state"]["manual"]["longitude"] == 20, writes[3]
# The failed A path rebases B onto pre-A state; the successful A path rebases B
# onto A's revision-7 Weather cache and preserves unrelated consent state.
assert writes[3]["state"]["weatherCache"]["latitude"] == 20, writes[3]
assert writes[4]["state"]["weatherCache"]["latitude"] == 0, writes[4]
assert writes[5]["state"]["revision"] == 7, writes[5]
assert writes[5]["state"]["manual"]["latitude"] == 30, writes[5]
assert writes[5]["state"]["manual"]["longitude"] == 40, writes[5]
assert writes[5]["state"]["weatherCache"]["latitude"] == 0, writes[5]
assert writes[5]["state"]["autoConsentVersion"] == 1, writes[5]
PY

printf 'qml-service-test: PASS\n'
