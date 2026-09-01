#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
MANIFEST="$ROOT/manifest.json"
README="$ROOT/README.md"

fail() {
  printf 'manifest-test: FAIL: %s\n' "$*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v omarchy >/dev/null 2>&1 || fail "omarchy is required"
[[ -f $MANIFEST ]] || fail "manifest.json is missing"
[[ -f $README ]] || fail "README.md is missing"
for artifact in TimelineModel.js MoonModel.js DaylightTimeline.qml MoonPhaseIcon.qml; do
  [[ -f $ROOT/$artifact ]] || fail "packaged Wave 3 runtime artifact is missing: $artifact"
  grep -Fq -- "$artifact" "$README" || fail "README package copy omits $artifact"
done

EXPECTED=$(cat <<'JSON'
{
  "schemaVersion": 1,
  "id": "jgordijn.night-light",
  "name": "Night Light",
  "version": "1.0.0",
  "author": "Jeroen Gordijn",
  "description": "Offline solar night light with a native Omarchy panel",
  "kinds": ["bar-widget", "service"],
  "entryPoints": {
    "barWidget": "BarWidget.qml",
    "service": "Service.qml"
  },
  "barWidget": {
    "displayName": "Night Light",
    "description": "Warm the display from sunset to sunrise",
    "category": "Time",
    "allowMultiple": false,
    "defaultSection": "right"
  }
}
JSON
)

jq -e . "$MANIFEST" >/dev/null || fail "manifest.json is not valid JSON"
if ! jq -e --argjson expected "$EXPECTED" '. == $expected' "$MANIFEST" >/dev/null; then
  diff -u \
    <(jq --sort-keys . <<<"$EXPECTED") \
    <(jq --sort-keys . "$MANIFEST") >&2 || true
  fail "manifest.json does not exactly match the v1 manifest contract"
fi

(
  cd -- "$ROOT"
  omarchy plugin validate .
) || fail "Omarchy rejected the plugin manifest or its entry points"

# User-facing IPC examples must address the service directly. `shell call` only
# dispatches shell-managed panels and returns "unknown" for this service.
for method in status refresh warm daylight resume; do
  invocation="omarchy-shell jgordijn.night-light $method"
  [[ $(grep -Fxc -- "$invocation" "$README") -eq 1 ]] ||
    fail "README must document exactly one direct-target $method invocation"
done

grep -Fq -- 'The read-only status call is:' "$README" ||
  fail "README must identify status as the read-only IPC command"
grep -Fq -- 'The remaining calls can change the display setting:' "$README" ||
  fail "README must distinguish mutating IPC controls from status"
grep -Fq -- '24-hour local-civil-day timeline' "$README" ||
  fail "README must describe the civil-day timeline"
grep -Fq -- 'not a claim that the Moon is visible or above the horizon' "$README" ||
  fail "README must not imply lunar visibility"
grep -Fq -- 'Timeline → Automatic → Warmth → Transition → primary action → Location → Forget' "$README" ||
  fail "README must document the normal roving order"
grep -Fq -- 'Each step is saved automatically and applies live when automatic warmth is active' "$README" ||
  fail "README must explain persisted-first Warmth behavior"

for doc in "$ROOT"/*.md; do
  if grep -Eq -- 'omarchy-shell[[:space:]]+shell[[:space:]]+call([[:space:]]|$)' "$doc"; then
    fail "$(basename -- "$doc") contains the nonfunctional shell call IPC route"
  fi
done

printf 'manifest-test: PASS\n'
