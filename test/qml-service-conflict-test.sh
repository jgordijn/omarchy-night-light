#!/usr/bin/env bash
# Focused Service CAS regressions: stale A triggers an authoritative read,
# retries are bounded, and C cannot be lost when it queues behind rebased B.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/qml" "$TMP/state/omarchy/settings" "$TMP/runtime"
chmod 700 "$TMP/runtime"
cp "$ROOT/Service.qml" "$ROOT/SolarModel.js" "$ROOT/ScheduleModel.js" "$ROOT/LocationModel.js" \
  "$ROOT/TimelineModel.js" "$ROOT/MoonModel.js" "$TMP/qml/"

# Keep Weather and every manual A/B/C transaction safely in model-verified
# daytime regardless of the wall-clock phase when this race suite runs.
FIXTURE_JSON=$(node "$ROOT/test/solar-noon-fixture.cjs")
DAY_LONGITUDE=$(python -c 'import json,sys; print(json.load(sys.stdin)["longitude"])' <<<"$FIXTURE_JSON")
python - "$TMP/state/omarchy/settings/weather.json" "$TMP/private-state.json" "$DAY_LONGITUDE" <<'PY'
import json, pathlib, sys
longitude = float(sys.argv[3])
weather = {"name": "Conflict Weather", "latitude": 0, "longitude": longitude}
pathlib.Path(sys.argv[1]).write_text(json.dumps(weather))
location = {
    "label": weather["name"], "admin1": "", "country": "", "latitude": 20,
    "longitude": weather["longitude"], "timezone": "", "source": "weather",
    "precision": "selected-locality", "observedAt": "2020-01-01T00:00:00Z",
}
pathlib.Path(sys.argv[2]).write_text(json.dumps({
    "schemaVersion": 1, "revision": 5, "mode": "weather", "autoConsentVersion": 0,
    "manual": None, "weatherCache": location, "autoIpCache": None,
}))
PY
printf queued >"$TMP/phase"

cat >"$TMP/qml/Controller.py" <<'PY'
#!/usr/bin/env python3
import json, os, sys, time

state_path = os.environ["FAKE_PRIVATE_STATE"]
phase_path = os.environ["FAKE_CONFLICT_PHASE"]
log_path = os.environ["FAKE_CONTROLLER_LOG"]

def emit(value):
    print(json.dumps(value, separators=(",", ":")), flush=True)

def log(value):
    with open(log_path, "a", encoding="utf-8") as stream:
        stream.write(json.dumps(value, separators=(",", ":")) + "\n")

def load():
    with open(state_path, encoding="utf-8") as stream:
        return json.load(stream)

def save(state):
    with open(state_path, "w", encoding="utf-8") as stream:
        json.dump(state, stream)

def conflict(common, request, current):
    emit({**common, "type": "error", "code": "revision-conflict",
          "message": "location state changed", "currentRevision": current["revision"]})

emit({"protocol": 1, "type": "ready", "daemonPid": 1234, "available": True})
for line in sys.stdin:
    request = json.loads(line)
    log(request)
    common = {"protocol": 1, "requestId": request["requestId"], "generation": request["generation"]}
    operation = request["operation"]
    if operation == "probe":
        emit({**common, "type": "backendStatus", "available": True,
              "actual": {"kind": "identity", "temperature": 6500, "gamma": 100},
              "override": None, "error": None})
    elif operation == "readLocationState":
        state = load()
        # Expose the conflict-resolution interval to the QML harness.
        if state["revision"] != 5:
            time.sleep(0.15)
        emit({**common, "type": "locationState", "outcome": "valid", "state": state})
    elif operation == "writeLocationState":
        phase = open(phase_path, encoding="utf-8").read().strip()
        current = load()
        expected = request.get("expectedRevision")
        if expected != current["revision"]:
            conflict(common, request, current)
            continue
        if request["state"]["mode"] == "weather":
            # A real competing CAS winner advances the private state before A
            # is rejected. In repeat mode the once-rebased retry loses too.
            current["revision"] += 1
            current["autoConsentVersion"] = 1
            save(current)
            time.sleep(0.20 if expected == 5 else 0.05)
            conflict(common, request, current)
            continue
        latitude = request["state"]["manual"]["latitude"]
        if phase == "combined" and latitude == 10:
            # Rebased B loses after C has had time to queue behind it.
            current["revision"] += 1
            current["autoConsentVersion"] = 0
            save(current)
            time.sleep(0.25)
            conflict(common, request, current)
            continue
        if phase == "repeat" or (phase == "combined" and latitude != 30):
            raise RuntimeError("unexpected manual write in " + phase)
        state = request["state"]
        state["revision"] = current["revision"] + 1
        save(state)
        emit({**common, "type": "locationState", "outcome": "valid", "state": state})
PY
chmod +x "$TMP/qml/Controller.py"

cat >"$TMP/qml/shell.qml" <<'QML'
import QtQuick
import Quickshell
import Quickshell.Io
import "."

ShellRoot {
  id: harness
  readonly property real dayLongitude: Number(Quickshell.env("FAKE_DAY_LONGITUDE"))
  function manualCoordinates(latitude) { return String(latitude) + ", " + String(dayLongitude) }
  property QtObject fakeShell: QtObject {
    property var shellConfig: ({ version: 1, bar: { layout: { left: [], center: [], right: [{
      id: "jgordijn.night-light", automationEnabled: true, nightTemperature: 4000,
      transitionMinutes: 45, stockIndicator: { choice: "pending", before: null, after: null }
    }] } }, plugins: [] })
    function updateEntryInline(id, value) { return true }
  }

  Component {
    id: serviceComponent
    Service {
      shell: harness.fakeShell
      manifest: ({ __sourceDir: Qt.resolvedUrl(".").toString().replace("file://", "") })
    }
  }
  Loader { id: loader; active: true; sourceComponent: serviceComponent }

  Process {
    id: resetter
    property string phase: "repeat"
    property int nextStage: 3
    command: ["/usr/bin/python", "-c",
      "import json,os,sys; p=os.environ['FAKE_PRIVATE_STATE']; s=json.load(open(p)); s['revision']=5; s['mode']='weather'; s['autoConsentVersion']=0; s['manual']=None; s['weatherCache']['latitude']=20; json.dump(s,open(p,'w')); open(os.environ['FAKE_CONFLICT_PHASE'],'w').write(sys.argv[1])",
      phase]
    onExited: function(exitCode) {
      if (exitCode !== 0) { console.error("CONFLICT_TEST_FAIL reset", exitCode); Qt.quit(); return }
      loader.active = false
      test.stage = nextStage
      test.ticks = 0
      Qt.callLater(function() { loader.active = true })
    }
  }

  Timer {
    id: test
    interval: 40
    repeat: true
    running: true
    property int stage: 0
    property int ticks: 0
    property bool weatherOperational: false

    onTriggered: {
      ++ticks
      var service = loader.item
      if (stage === 0 && service && service._initializationInFlight && service._stateBusy) {
        stage = 1
        ticks = 0
        if (!service.useManualCoordinates(harness.manualCoordinates(10)) || !service._queuedStateWrite) {
          console.error("CONFLICT_TEST_FAIL B not queued")
          Qt.quit()
        }
        return
      }
      if (stage === 1) {
        // The conflicted startup cache remains a usable Weather schedule while
        // Service reads revision 6 and retries the rebased manual intent.
        if (service && service._stateBusy && service.activeScheduleLocation &&
            service.activeScheduleLocation.source === "weather" && service.scheduleTarget)
          weatherOperational = true
        var committed = service && service.initialized && !service.busy && service.error === null &&
          service.privateLocationState && service.privateLocationState.revision === 7 &&
          service.privateLocationState.mode === "manual" && service.activeScheduleLocation &&
          service.activeScheduleLocation.source === "manual-coordinates"
        if (committed) {
          if (!weatherOperational) {
            console.error("CONFLICT_TEST_FAIL Weather was not operational during resolution")
            Qt.quit()
            return
          }
          stage = 20
          ticks = 0
          resetter.running = true
          return
        }
      }
      if (stage === 3) {
        var bounded = service && service.initialized && !service.busy &&
          service.error && service.error.code === "revision-conflict" &&
          service.error.message.toLowerCase().indexOf("refresh") >= 0 &&
          service._queuedStateWrite && service._queuedStateWrite.reason === "startup" &&
          service.mode === "scheduled" && service.activeScheduleLocation &&
          service.activeScheduleLocation.source === "weather" && service.scheduleTarget
        if (bounded) {
          stage = 4
          ticks = 0
          return
        }
      }
      if (stage === 4 && ticks >= 8) {
        // A terminal retry stays retained without spinning. Now reproduce the
        // combined A conflict → B retry → C queued → B conflict sequence.
        resetter.phase = "combined"
        resetter.nextStage = 5
        stage = 40
        ticks = 0
        resetter.running = true
        return
      }
      if (stage === 5 && service && service._initializationInFlight && service._stateBusy) {
        stage = 6
        ticks = 0
        if (!service.useManualCoordinates(harness.manualCoordinates(10)) || !service._queuedStateWrite) {
          console.error("CONFLICT_TEST_FAIL combined B not queued")
          Qt.quit()
        }
        return
      }
      if (stage === 6 && service && service._stateBusy && service.privateLocationState &&
          service.privateLocationState.revision === 6 && !service._queuedStateWrite) {
        stage = 7
        ticks = 0
        if (!service.useManualCoordinates(harness.manualCoordinates(30)) || !service._queuedStateWrite ||
            Number(service._queuedStateWrite.candidate.manual.latitude) !== 30) {
          console.error("CONFLICT_TEST_FAIL C not queued behind B")
          Qt.quit()
        }
        return
      }
      if (stage === 7) {
        var latestCommitted = service && service.initialized && !service.busy &&
          service.error === null && service.privateLocationState &&
          service.privateLocationState.revision === 8 && service.privateLocationState.mode === "manual" &&
          service.activeScheduleLocation && service.activeScheduleLocation.source === "manual-coordinates" &&
          Number(service.activeScheduleLocation.latitude) === 30 &&
          Math.abs(Number(service.activeScheduleLocation.longitude) - harness.dayLongitude) < 0.000000001
        if (latestCommitted) {
          console.log("CONFLICT_TEST_PASS", JSON.stringify(service.statusObject()))
          Qt.quit()
          return
        }
      }
      if (ticks > 150) {
        console.error("CONFLICT_TEST_FAIL timeout", stage,
                      service ? JSON.stringify(service.statusObject()) : "no service")
        Qt.quit()
      }
    }
  }
}
QML

OUTPUT="$TMP/output.log"
set +e
timeout 15s env \
  HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" XDG_RUNTIME_DIR="$TMP/runtime" \
  FAKE_CONTROLLER_LOG="$TMP/controller.log" FAKE_PRIVATE_STATE="$TMP/private-state.json" \
  FAKE_CONFLICT_PHASE="$TMP/phase" FAKE_DAY_LONGITUDE="$DAY_LONGITUDE" QT_QPA_PLATFORM=offscreen \
  quickshell --no-color -p "$TMP/qml/shell.qml" >"$OUTPUT" 2>&1
RC=$?
set -e
if [[ $RC -ne 0 ]] || ! grep -q 'CONFLICT_TEST_PASS' "$OUTPUT"; then
  cat "$OUTPUT" >&2
  echo "qml-service-conflict-test: FAIL" >&2
  exit 1
fi
if grep -Eiq 'CONFLICT_TEST_FAIL|TypeError|ReferenceError|is not a type|Cannot assign|Unable to assign|binding loop' "$OUTPUT"; then
  cat "$OUTPUT" >&2
  echo "qml-service-conflict-test: FAIL: QML runtime warning/error" >&2
  exit 1
fi

python - "$TMP/controller.log" "$DAY_LONGITUDE" <<'PY'
import json, pathlib, sys
rows = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
day_longitude = float(sys.argv[2])
assert not [row for row in rows if row["operation"] == "setDesired"], rows
state_ops = [row for row in rows if row["operation"] in ("readLocationState", "writeLocationState")]
# Case one: startup read(5), A@5 conflicts after an external winner reaches 6,
# authoritative read(6), then queued manual B is rebased and succeeds at 6.
assert [row["operation"] for row in state_ops[:4]] == [
    "readLocationState", "writeLocationState", "readLocationState", "writeLocationState"
], state_ops
assert state_ops[1]["expectedRevision"] == 5 and state_ops[1]["state"]["mode"] == "weather", state_ops[1]
assert state_ops[3]["expectedRevision"] == 6 and state_ops[3]["state"]["revision"] == 6, state_ops[3]
assert state_ops[3]["state"]["mode"] == "manual", state_ops[3]
assert state_ops[3]["state"]["manual"]["latitude"] == 10, state_ops[3]
assert abs(state_ops[3]["state"]["manual"]["longitude"] - day_longitude) < 1e-9, state_ops[3]
assert state_ops[3]["state"]["autoConsentVersion"] == 1, state_ops[3]
assert state_ops[3]["state"]["weatherCache"]["latitude"] == 20, state_ops[3]
# Case two has exactly one read/retry after A's conflict. The retry conflict is
# terminal and retained: no third read/write appears during the settling delay.
second = state_ops[4:8]
assert [row["operation"] for row in second] == [
    "readLocationState", "writeLocationState", "readLocationState", "writeLocationState"
], second
assert [row.get("expectedRevision") for row in second if row["operation"] == "writeLocationState"] == [5, 6], second
assert all(row["state"]["mode"] == "weather" for row in second if row["operation"] == "writeLocationState"), second
# Combined case: A@5 loses, B is rebased at 6, C queues while B is in flight,
# B loses at 7, and C gets a fresh bounded read/rebase and commits at revision 8.
third = state_ops[8:]
assert [row["operation"] for row in third] == [
    "readLocationState", "writeLocationState", "readLocationState", "writeLocationState",
    "readLocationState", "writeLocationState"
], third
writes = [row for row in third if row["operation"] == "writeLocationState"]
assert [row["expectedRevision"] for row in writes] == [5, 6, 7], writes
assert writes[0]["state"]["mode"] == "weather", writes[0]
assert writes[1]["state"]["manual"]["latitude"] == 10, writes[1]
assert abs(writes[1]["state"]["manual"]["longitude"] - day_longitude) < 1e-9, writes[1]
assert writes[2]["state"]["manual"]["latitude"] == 30, writes[2]
assert abs(writes[2]["state"]["manual"]["longitude"] - day_longitude) < 1e-9, writes[2]
assert writes[2]["state"]["revision"] == 7, writes[2]
assert writes[2]["state"]["autoConsentVersion"] == 0, writes[2]
PY

printf 'qml-service-conflict-test: PASS\n'
