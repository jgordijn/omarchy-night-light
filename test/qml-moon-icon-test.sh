#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
ICON="$ROOT/MoonPhaseIcon.qml"
REFERENCE_DIR="$ROOT/test/reference/moon-icon"
TMP=""
QS_PID=""

fail() {
  printf 'qml-moon-icon-test: FAIL: %s\n' "$*" >&2
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

[[ -f $ICON ]] || fail "MoonPhaseIcon.qml is missing"
command -v quickshell >/dev/null 2>&1 || fail "quickshell is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v magick >/dev/null 2>&1 || fail "ImageMagick is required"
[[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] || fail "a running Hyprland compositor is required"
hyprctl monitors >/dev/null 2>&1 || fail "the Hyprland compositor is not reachable"

# Keep the renderer primitive and independent of fonts, assets, and effects.
[[ $(grep -Ec '^[[:space:]]*Rectangle[[:space:]]*\{' "$ICON") -eq 2 ]] || fail "renderer must contain exactly two circular Rectangles"
[[ $(grep -Ec '^[[:space:]]*ShapePath[[:space:]]*\{' "$ICON") -eq 1 ]] || fail "renderer must contain exactly one illuminated ShapePath"
grep -q 'preferredRendererType:[[:space:]]*Shape.CurveRenderer' "$ICON" || fail "CurveRenderer is required"
if grep -Eq '\b(Text|OpticalGlyph|Canvas|ShaderEffect|MultiEffect|OpacityMask|Image|AnimatedImage|PathSvg)[[:space:]]*\{' "$ICON"; then
  fail "renderer contains a forbidden glyph, image, mask, shader, canvas, or SVG primitive"
fi
if grep -Eq '(^|[[:space:]])(source|font\.family|text)[[:space:]]*:' "$ICON"; then
  fail "renderer contains a font or asset source dependency"
fi
mapfile -t API < <(grep -E '^[[:space:]]{2}property (real|string|color) ' "$ICON" | sed -E 's/^[[:space:]]+property (real|string|color) ([A-Za-z0-9_]+).*/\2/')
[[ ${API[*]} == "illumination trend orientation foreground" ]] || fail "public properties differ from the frozen API: ${API[*]}"

TMP=$(mktemp -d)
CONFIG="$TMP/moon-qml"
RESULT="$TMP/result.json"
LOG="$TMP/quickshell.log"
CAPTURES="$TMP/captures"
mkdir -p "$CONFIG" "$TMP/home" "$CAPTURES"
ln -s /usr/share/omarchy/shell/Commons "$CONFIG/Commons"

cat >"$CONFIG/shell.qml" <<'QML'
import QtQuick
import Quickshell
import qs.Commons

ShellRoot {
  id: root

  readonly property string resultPath: Quickshell.env("MOON_TEST_RESULT")
  readonly property string captureDir: Quickshell.env("MOON_TEST_CAPTURE_DIR")
  readonly property string iconUrl: Quickshell.env("MOON_TEST_ICON_URL")
  readonly property var illuminations: [0, 0.15, 0.5, 0.85, 1, 0.85, 0.5, 0.15]
  readonly property var trends: ["waxing", "waxing", "waxing", "waxing",
                                 "waning", "waning", "waning", "waning"]
  property var failures: []

  function check(condition, message) {
    if (!condition) failures.push(String(message))
  }

  function writeResult() {
    var payload = JSON.stringify({ ok: failures.length === 0, failures: failures })
    Quickshell.execDetached(["/usr/bin/python", "-c",
      "import sys; open(sys.argv[1], 'w').write(sys.argv[2])", resultPath, payload])
  }

  function validateMatrix() {
    var component = Qt.createComponent(iconUrl, Component.PreferSynchronous)
    check(component.status === Component.Ready, "component loads: " + component.errorString())
    if (component.status !== Component.Ready) return

    var sizes = [16, 24, 58]
    var scales = [1, 1.5, 2]
    var orientations = ["northern", "southern"]
    var foregrounds = ["#e8eaed", "#202326"]
    for (var phase = 0; phase < illuminations.length; phase++) {
      for (var orientation = 0; orientation < orientations.length; orientation++) {
        for (var size = 0; size < sizes.length; size++) {
          for (var scale = 0; scale < scales.length; scale++) {
            for (var theme = 0; theme < foregrounds.length; theme++) {
              var logicalSize = sizes[size] * scales[scale]
              var icon = component.createObject(validationHost, {
                width: logicalSize,
                height: logicalSize,
                illumination: illuminations[phase],
                trend: trends[phase],
                orientation: orientations[orientation],
                foreground: foregrounds[theme]
              })
              check(icon !== null, "matrix icon instantiates")
              if (icon) {
                check(isFinite(icon.width) && isFinite(icon.height), "matrix geometry is finite")
                check(icon.width === logicalSize && icon.height === logicalSize,
                      "matrix geometry keeps its requested bounds")
                icon.destroy()
              }
            }
          }
        }
      }
    }

    // Hostile values remain bounded and deterministic instead of producing
    // non-finite path geometry. Unknown strings use the documented northern/
    // waxing convention; valid southern/waning values still mirror normally.
    var hostile = component.createObject(validationHost, {
      width: 58, height: 58, illumination: NaN,
      trend: "unknown", orientation: "unknown", foreground: "#ffffff"
    })
    check(hostile !== null && isFinite(hostile.width) && isFinite(hostile.height),
          "non-finite illumination is safely renderable")
    if (hostile) hostile.destroy()
  }

  function captureFixtures() {
    Color.accent = "#b8c0ff"
    darkFixture.grabToImage(function(darkResult) {
      check(darkResult && darkResult.saveToFile(captureDir + "/moon-icon-dark.png"),
            "dark reference capture saves")
      Color.accent = "#304080"
      lightFixture.grabToImage(function(lightResult) {
        check(lightResult && lightResult.saveToFile(captureDir + "/moon-icon-light.png"),
              "light reference capture saves")
        Color.accent = "#ffffff"
        fidelityFixture.grabToImage(function(fidelityResult) {
          check(fidelityResult && fidelityResult.saveToFile(captureDir + "/moon-icon-fidelity.png"),
                "area fixture capture saves")
          writeResult()
        }, Qt.size(fidelityFixture.width, fidelityFixture.height))
      }, Qt.size(lightFixture.width, lightFixture.height))
    }, Qt.size(darkFixture.width, darkFixture.height))
  }

  component PhaseGrid: Rectangle {
    id: fixture
    width: 408
    height: 108
    property color iconForeground: "white"

    Grid {
      x: 16
      y: 10
      columns: 8
      spacing: 8

      Repeater {
        model: 16
        Loader {
          id: phaseLoader
          width: 40
          height: 40
          source: root.iconUrl
          onLoaded: {
            var phase = index % 8
            item.illumination = root.illuminations[phase]
            item.trend = root.trends[phase]
            item.orientation = index < 8 ? "northern" : "southern"
            item.foreground = fixture.iconForeground
          }
        }
      }
    }
  }

  FloatingWindow {
    id: window
    visible: true
    color: "#000000"
    implicitWidth: 1152
    implicitHeight: 236
    minimumSize: Qt.size(1152, 236)
    maximumSize: Qt.size(1152, 236)

    Item {
      id: validationHost
      width: 1
      height: 1
      visible: false
    }

    PhaseGrid {
      id: darkFixture
      x: 0
      y: 0
      color: "#101315"
      iconForeground: "#e8eaed"
    }

    PhaseGrid {
      id: lightFixture
      x: 420
      y: 0
      color: "#f4f4f4"
      iconForeground: "#202326"
    }

    Rectangle {
      id: fidelityFixture
      x: 0
      y: 108
      width: 1152
      height: 128
      color: "#000000"

      Row {
        Repeater {
          model: 9
          Rectangle {
            required property int index
            width: 128
            height: 128
            color: "#000000"
            Loader {
              anchors.fill: parent
              source: root.iconUrl
              onLoaded: {
                item.illumination = [0, 0.05, 0.15, 0.25, 0.5, 0.75, 0.85, 0.95, 1][index]
                item.trend = "waxing"
                item.orientation = "northern"
                item.foreground = "#ffffff"
              }
            }
          }
        }
      }
    }
  }

  Timer {
    interval: 180
    running: true
    repeat: false
    onTriggered: {
      validateMatrix()
      captureFixtures()
    }
  }
}
QML

MOON_TEST_RESULT="$RESULT" \
MOON_TEST_CAPTURE_DIR="$CAPTURES" \
MOON_TEST_ICON_URL="file://$ICON" \
HOME="$TMP/home" \
XDG_CONFIG_HOME="$TMP/home/.config" \
XDG_CACHE_HOME="$TMP/home/.cache" \
XDG_STATE_HOME="$TMP/home/.local/state" \
QML2_IMPORT_PATH="$CONFIG${QML2_IMPORT_PATH:+:$QML2_IMPORT_PATH}" \
QML_IMPORT_PATH="$CONFIG${QML_IMPORT_PATH:+:$QML_IMPORT_PATH}" \
  quickshell -p "$CONFIG" --no-color >"$LOG" 2>&1 &
QS_PID=$!

for _ in {1..150}; do
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

if grep -E '(MoonPhaseIcon\.qml|shell\.qml).*(Error|is not a type|Cannot assign|ReferenceError|TypeError|Unable to assign|Binding loop|NaN|not finite)' "$LOG" >&2; then
  fail "moon renderer emitted QML diagnostics"
fi
for capture in moon-icon-dark.png moon-icon-light.png moon-icon-fidelity.png; do
  [[ -s $CAPTURES/$capture ]] || fail "$capture was not produced"
done
# grabToImage preserves the output's device-pixel ratio. Accept each required
# scale, then normalize references to logical pixels so snapshots are portable.
DARK_GEOMETRY=$(magick identify -format '%wx%h' "$CAPTURES/moon-icon-dark.png")
LIGHT_GEOMETRY=$(magick identify -format '%wx%h' "$CAPTURES/moon-icon-light.png")
FIDELITY_GEOMETRY=$(magick identify -format '%wx%h' "$CAPTURES/moon-icon-fidelity.png")
case "$DARK_GEOMETRY" in 408x108|612x162|816x216) ;; *) fail "dark capture dimensions changed: $DARK_GEOMETRY" ;; esac
case "$LIGHT_GEOMETRY" in 408x108|612x162|816x216) ;; *) fail "light capture dimensions changed: $LIGHT_GEOMETRY" ;; esac
case "$FIDELITY_GEOMETRY" in 1152x128|1728x192|2304x256) ;; *) fail "fidelity capture dimensions changed: $FIDELITY_GEOMETRY" ;; esac
magick "$CAPTURES/moon-icon-dark.png" -filter Lanczos -resize '408x108!' "$CAPTURES/moon-icon-dark.png"
magick "$CAPTURES/moon-icon-light.png" -filter Lanczos -resize '408x108!' "$CAPTURES/moon-icon-light.png"
magick "$CAPTURES/moon-icon-fidelity.png" -filter Lanczos -resize '1152x128!' "$CAPTURES/moon-icon-fidelity.png"

# The white-on-black fixture makes the lit region separable from the 12%
# shadow and outline. Count the full analytic disk: rejecting outline-colored
# pixels from the lit numerator preserves thin crescents in the area measure.
python - "$CAPTURES/moon-icon-fidelity.png" <<'PY' || fail "rendered area/orientation checks failed"
import math
import subprocess
import sys

path = sys.argv[1]
raw = subprocess.check_output(["magick", path, "rgba:-"])
width, height = 1152, 128
if len(raw) != width * height * 4:
    raise SystemExit("unexpected raw capture size")
expected = [0, 0.05, 0.15, 0.25, 0.5, 0.75, 0.85, 0.95, 1]
for cell, requested in enumerate(expected):
    lit = total = 0
    for y in range(128):
        for x in range(128):
            if (x + 0.5 - 64) ** 2 + (y + 0.5 - 64) ** 2 > 64 ** 2:
                continue
            offset = (y * width + cell * 128 + x) * 4
            r, g, b, _ = raw[offset:offset + 4]
            total += 1
            if (r + g + b) / 3 > 160:
                lit += 1
    measured = lit / total
    if abs(measured - requested) > 0.02:
        raise SystemExit(f"illumination {requested:.2f} measured {measured:.4f}")
print("area fidelity: " + ", ".join(
    f"{value:.0%}" for value in expected))
PY

# Northern first quarter is right-lit; its southern counterpart is mirrored.
python - "$CAPTURES/moon-icon-dark.png" <<'PY' || fail "hemisphere/trend orientation checks failed"
import subprocess
import sys

raw = subprocess.check_output(["magick", sys.argv[1], "rgba:-"])
width = 408
def luminance(x, y):
    offset = (y * width + x) * 4
    return sum(raw[offset:offset + 3]) / 3
# Cell origins are x=16+48*column, y=10+48*row; sample away from AA edges.
def pair(column, row):
    cx, cy = 16 + 48 * column + 20, 10 + 48 * row + 20
    return luminance(cx - 10, cy), luminance(cx + 10, cy)
north_first = pair(2, 0)
south_first = pair(2, 1)
north_last = pair(6, 0)
south_last = pair(6, 1)
if not (north_first[1] > north_first[0] + 100 and south_first[0] > south_first[1] + 100):
    raise SystemExit("first-quarter hemisphere mirror is wrong")
if not (north_last[0] > north_last[1] + 100 and south_last[1] > south_last[0] + 100):
    raise SystemExit("last-quarter hemisphere mirror is wrong")
PY

if [[ ${UPDATE_MOON_REFERENCES:-0} == 1 ]]; then
  mkdir -p "$REFERENCE_DIR"
  cp "$CAPTURES/moon-icon-dark.png" "$REFERENCE_DIR/moon-icon-dark.png"
  cp "$CAPTURES/moon-icon-light.png" "$REFERENCE_DIR/moon-icon-light.png"
fi
for reference in moon-icon-dark.png moon-icon-light.png; do
  [[ -s $REFERENCE_DIR/$reference ]] || fail "missing frozen reference $REFERENCE_DIR/$reference (run with UPDATE_MOON_REFERENCES=1)"
  # Curve rasterization can vary by a few edge pixels across Qt/GPU versions;
  # normalized RMSE catches geometry/theme regressions without byte brittleness.
  metric=$(magick compare -metric RMSE "$REFERENCE_DIR/$reference" "$CAPTURES/$reference" null: 2>&1 || true)
  normalized=$(printf '%s\n' "$metric" | sed -nE 's/.*\(([0-9.]+)\).*/\1/p')
  [[ -n $normalized ]] || fail "could not compare frozen reference $reference"
  awk -v value="$normalized" 'BEGIN { exit !(value <= 0.03) }' || fail "$reference differs from its frozen reference (RMSE=$normalized)"
done

CAPTURE_OUT=${NIGHT_LIGHT_MOON_CAPTURE_DIR:-$ROOT/.work/captures/moon-icon}
mkdir -p "$CAPTURE_OUT"
cp "$CAPTURES/moon-icon-dark.png" "$CAPTURE_OUT/moon-icon-dark.png"
cp "$CAPTURES/moon-icon-light.png" "$CAPTURE_OUT/moon-icon-light.png"
printf 'qml-moon-icon-test: reference captures %s\n' "$CAPTURE_OUT"
printf 'qml-moon-icon-test: PASS\n'
