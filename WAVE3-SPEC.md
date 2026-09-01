# Night Light — Wave 3 frozen specification

Status: **frozen for implementation**. This document is normative for Wave 3. `SPEC.md` remains normative everywhere this document does not explicitly supersede it. The four `w3-*-research.md` reports are evidence, not additional contracts.

No production code was changed while preparing this specification.

## 1. Scope and non-regression rule

Wave 3 adds only:

1. a truthful local-civil-day solar timeline;
2. current lunar phase rendering for the nighttime marker;
3. persisted-first live application of Warmth changes when automatic warmth is currently active.

It does not add a schedule editor, moonrise/moonset, a draggable rail, a new network provider, a new package, a persistent timeline state, or a new stable IPC field.

All v1 guarantees remain release blockers, including:

- offline solar operation after coordinates are known;
- no IP lookup without consent and no Weather writes;
- one serialized controller and one shared `hyprsunset`;
- identity distinct from numeric Kelvin;
- external changes become overrides rather than being fought;
- private atomic location state and bounded network/apply retries;
- hot-reload generation authority and eight-second release grace;
- fixed `520 × 440` nominal dashboard geometry and fitted editors;
- the existing direct normal-mode key owner, `l` Location shortcut, Tab handoff, editor behavior, stock-indicator CAS, manifest, and stable `status()` schema.

The following v1 text is superseded:

- the package/file list gains `TimelineModel.js`, `MoonModel.js`, `DaylightTimeline.qml`, and `MoonPhaseIcon.qml`;
- the dashboard’s “sunset-to-sunrise progress rail with fixed labels” becomes the timeline in this document;
- Timeline is inserted before Automatic in roving order, while Automatic remains the initial focus;
- Panel no longer writes Warmth settings directly.

## 2. Contradictions resolved

These decisions are final:

| Research disagreement | Frozen decision |
|---|---|
| 12 px timeline marker vs 14–16 px legible moon | The painted celestial marker is `Style.space(16)` in a `Style.space(32)` non-layout-changing target. Rail endpoints are inset by 8 logical pixels. |
| Hidden arrows vs discoverable idle arrows | Arrow glyphs are hidden at rest, matching the reference. A faint 1-hairline event tick remains visible. Hover/focus/pin reveals the full arrow. |
| `Sunrise · 6:53 AM` vs `Sunrise 6:53 AM` | Event hover and pinned copy is exactly `Sunrise {short time}` / `Sunset {short time}`. The middle dot is reserved for lunar detail and UTC-offset disambiguation. |
| Escape first dismisses a pin vs existing Escape closes | Existing behavior wins: Escape closes the panel and close clears the pin. It is never a two-step close. |
| Ephemeral preview session vs immediate preference | Warmth is persisted-first and never rolled back. There is no preview session, Save, Cancel, start, or cancel protocol. |
| Location timezone vs QML’s system-local `Date` | A read-only controller projection operation uses Python `zoneinfo`; pure JS receives already projected civil fields. Panel never performs timezone authority or process I/O. |
| Moon marker as visibility claim | It means “current phase during calculated nighttime,” never “the Moon is above the horizon.” No moonrise/moonset is calculated or displayed. |

## 3. Independently buildable pieces

Build and review in this order. A piece may land only with its gate and every pre-existing suite passing.

| # | Piece | Production files | Independent gate |
|---:|---|---|---|
| W3.1 | Civil timeline model | `TimelineModel.js` | `test/timeline-test.cjs` |
| W3.2 | Lunar model | `MoonModel.js` | `test/moon-test.cjs` |
| W3.3 | Civil timezone projection | `Controller.py` | focused projection cases in `test/controller-test.py` |
| W3.4 | Atomic timeline service snapshot | `Service.qml` | `test/qml-timeline-service-test.sh` with a fake controller |
| W3.5 | Primitive moon renderer | `MoonPhaseIcon.qml` | `test/qml-moon-icon-test.sh` |
| W3.6 | Reusable timeline UI | `DaylightTimeline.qml` | `test/qml-timeline-test.sh` |
| W3.7 | Panel integration and focus | `Panel.qml` | extended entrypoint/source contracts and installed pointer/keyboard capture |
| W3.8 | Lunar service integration | `Service.qml` | startup/freshness/isolation tests plus icon reference capture |
| W3.9 | Persisted-first warmth | `Service.qml`, `Panel.qml` | `test/qml-live-preview-test.sh` |
| W3.10 | External-change CAS guard | `Controller.py`, `Service.qml` | focused controller race, rapid-input, failure, and reload tests |
| W3.11 | Installed integration | all | full suites, live telemetry, randomized blind gate, cleanup proof |

A visual component must accept a frozen fake snapshot; it must not wait for the real service piece to be buildable.

---

## 4. `TimelineModel.js`

### 4.1 Runtime boundary

Use the existing pure-model house style: `var`, ordinary functions, plain objects, no QML object, package, network, filesystem, process, locale API, or unguarded CommonJS reference. The same source loads unchanged in QML and Node.

CommonJS exports are exactly:

```js
[
  "buildSnapshot",
  "positionForWallMs",
  "shouldAnimateMarker"
]
```

`DAY_MS` is exactly `86400000`. Timeline geometry is nominal wall-clock geometry, including on 23- and 25-hour civil days.

### 4.2 `positionForWallMs(wallMs)`

- Accept a finite number in `[0, 86400000]`.
- Return `wallMs / 86400000`.
- Return `null` for every other input, including booleans.
- Never round.

### 4.3 `buildSnapshot(input)`

The input is already projected by the timezone authority:

```json
{
  "revision": 7,
  "dateKey": "2026-09-01",
  "zoneId": "Europe/Amsterdam",
  "zoneSource": "location",
  "nowMs": 1788273420000,
  "markerWallMs": 59820000,
  "markerOffsetMinutes": 120,
  "markerFold": 0,
  "markerAmbiguous": false,
  "status": "normal",
  "stateAtMidnight": "night",
  "events": [
    {
      "kind": "sunrise",
      "epochMs": 1788238305216,
      "dateKey": "2026-09-01",
      "wallMs": 24705216,
      "offsetMinutes": 120,
      "fold": 0,
      "ambiguous": false
    },
    {
      "kind": "sunset",
      "epochMs": 1788287423925,
      "dateKey": "2026-09-01",
      "wallMs": 73823925,
      "offsetMinutes": 120,
      "fold": 0,
      "ambiguous": false
    }
  ],
  "displayTimes": {
    "sunset": null,
    "sunrise": null,
    "nextBoundary": null,
    "overrideUntil": null
  }
}
```

Success is:

```json
{
  "ok": true,
  "snapshot": {
    "revision": 7,
    "dateKey": "2026-09-01",
    "zoneId": "Europe/Amsterdam",
    "zoneSource": "location",
    "nowMs": 1788273420000,
    "markerWallMs": 59820000,
    "markerOffsetMinutes": 120,
    "markerFold": 0,
    "markerAmbiguous": false,
    "status": "normal",
    "stateAtMidnight": "night",
    "isDayNow": true,
    "events": [
      {
        "key": "sunrise:1788238305216:120:0",
        "kind": "sunrise",
        "epochMs": 1788238305216,
        "dateKey": "2026-09-01",
        "wallMs": 24705216,
        "offsetMinutes": 120,
        "fold": 0,
        "ambiguous": false
      },
      {
        "key": "sunset:1788287423925:120:0",
        "kind": "sunset",
        "epochMs": 1788287423925,
        "dateKey": "2026-09-01",
        "wallMs": 73823925,
        "offsetMinutes": 120,
        "fold": 0,
        "ambiguous": false
      }
    ],
    "daylightSegments": [{"startWallMs":24705216,"endWallMs":73823925}],
    "displayTimes": {
      "sunset": null,
      "sunrise": null,
      "nextBoundary": null,
      "overrideUntil": null
    }
  }
}
```

Failure is exactly:

```json
{"ok":false,"error":"invalid-timeline"}
```

Validation and derivation:

- `revision` is a non-negative integer.
- `dateKey` is strict `YYYY-MM-DD`; `zoneId` is non-empty and at most 80 code units.
- `zoneSource` is `location` or `system`.
- All epochs are finite ECMAScript Date-range milliseconds.
- `status` is `normal`, `polar-day`, `polar-night`, or `unavailable`.
- Available snapshots require `stateAtMidnight` to be `day` or `night`; unavailable requires no events and produces no daylight segments.
- There are zero to two real current-date events, strictly ordered by epoch. Kinds are `sunrise`/`sunset`, events must change the running state, and all event `dateKey` values equal the snapshot date.
- Marker and event `wallMs ∈ [0,86400000)`, `offsetMinutes` is an integer in `[-1440,1440]`, `fold` is `0|1`, and `ambiguous` is boolean.
- Sunrise changes state to day at its exact epoch. Sunset changes state to night at its exact epoch.
- `isDayNow` applies every event with `epochMs <= nowMs`.
- Daylight segments are non-overlapping, sorted, half-open wall intervals. A wrapped daylight projection is split into `[start,DAY_MS)` and `[0,end)` and the result is sorted/merged.
- No events plus polar day yields one full segment. No events plus polar night yields none. A single sunrise yields daylight after it; a single sunset yields daylight before it. Missing events are never fabricated.
- Every accepted event gains a stable private/UI key formed from kind, full epoch, offset, and fold; equal displayed wall times remain distinct.
- `displayTimes` accepts only the four named keys. A value is null or the same projected-time shape (`epochMs`, `dateKey`, `wallMs`, `offsetMinutes`, `fold`, `ambiguous`). Unknown keys are omitted.
- The returned snapshot is newly allocated; input is never mutated.

### 4.4 `shouldAnimateMarker(previous, next)`

Return true only when both snapshots are valid and all are true:

- same `revision`, `dateKey`, `zoneId`, and UTC offset;
- `next.nowMs >= previous.nowMs`;
- epoch and wall-time deltas are each in `[0,120000]`;
- marker wall time did not move backward.

Return false for first render, midnight, location/date/zone/offset replacement, backward time, suspend, or a jump over two minutes. The component uses the result to enable a 160 ms OutCubic x animation. DST spring and fall therefore snap; the repeated fall hour traverses the same x-range again.

### 4.5 Timeline model gates

1. Exports are exact and QML/Node load the same source.
2. Invalid, NaN, infinite, malformed, misordered, repeated-state, or wrong-date inputs return only `invalid-timeline` and never expose invalid geometry.
3. Reference wall positions are exact for 02:02, 09:02, 12:02, 19:02, 20:02, 04:43, 11:43, and 18:43.
4. The installed fixture yields sunrise about `28.59%`, marker about `69.24%`, and sunset about `85.44%`.
5. Exact sunrise/sunset state, polar full/empty, one-event seams, wrapped intervals, edge events, and same-wall/different-fold events pass.
6. `shouldAnimateMarker` passes normal minute, midnight, spring/fall DST, backward jump, >2-minute jump, and context replacement cases.
7. Random valid sweeps return finite positions and sorted bounded segments without mutating inputs.

---

## 5. Civil timezone projection and Service timeline ownership

### 5.1 Timezone authority

For one snapshot, use exactly one zone in this order:

1. the active schedule location’s valid IANA zone;
2. the current shell/system IANA zone when location timezone is empty or invalid.

The chosen zone governs date key, marker, current-day event selection, hero event formatting, UTC offset, folds, DST, and midnight. Coordinates still govern astronomy. Timezone never changes `SolarModel` or `ScheduleModel` epoch calculations.

### 5.2 Internal controller operation

Add one protocol-1 operation; it is not shell IPC and does not change the stable status schema.

Request:

```json
{
  "protocol": 1,
  "requestId": "qml-40",
  "generation": 40,
  "operation": "projectCivilDay",
  "nowMs": 1788273420000,
  "zoneId": "Europe/Amsterdam",
  "events": [{"kind":"sunrise","epochMs":1788238305216}],
  "displayTimes": {"sunset":1788287423925}
}
```

Response type is `civilDay` and echoes request/generation:

```json
{
  "protocol": 1,
  "type": "civilDay",
  "requestId": "qml-40",
  "generation": 40,
  "projection": {
    "dateKey": "2026-09-01",
    "zoneId": "Europe/Amsterdam",
    "zoneSource": "location",
    "dayStartMs": 1788213600000,
    "dayEndMs": 1788300000000,
    "markerWallMs": 59820000,
    "markerOffsetMinutes": 120,
    "markerFold": 0,
    "markerAmbiguous": false,
    "events": [],
    "displayTimes": {}
  }
}
```

Controller contract:

- Use only standard-library `zoneinfo` and timezone data already installed.
- Validate the requested zone with `ZoneInfo`; otherwise resolve the live system zone and mark source `system`.
- `dayStartMs` and `dayEndMs` are real epoch boundaries for that civil date and may differ from 86400000 ms.
- Wall milliseconds always come from projected hour/minute/second/millisecond.
- Report real UTC offset, PEP-495 fold, and whether the same wall time has another valid fold with a different offset.
- Accept at most 8 events and only the four named display times. Reject invalid epochs/kinds/keys with `invalid-request`.
- The operation performs no network request, persistence, backend probe/write, override change, logging of coordinates, or daemon lifecycle change.
- Add a `timeline` generation family. Latest request/attachment wins; stale projection cannot publish after a location/timezone replacement or hot reload.

Service may make an initial projection request without events to obtain the real civil-day epoch bounds. It then:

1. evaluates `SolarModel.surroundingEvents(dayStartMs, latitude, longitude)` to obtain midnight state and the first real state-changing event;
2. walks `nextEvent` with fresh `surroundingEvents(eventMs + 1, ...)` until `dayEndMs`, with a hard maximum of two current-day events;
3. sends those events and the four public schedule-label epochs for final projection;
4. calls `TimelineModel.buildSnapshot()` and publishes only the complete result.

A failed walk/projection/model validation publishes a neutral `unavailable` timeline; it does not invalidate the working solar schedule or touch the display.

### 5.3 Read-only Service API

Add:

```qml
readonly property var timeline: _timeline
readonly property var moonPhase: _moonPhase
```

`timeline` is null before its first transaction, then always one complete immutable snapshot. It is QML-only: do not add it, moon data, date keys, offsets, or zone IDs to `status()`.

The Service owns all timeline clocks. Recompute:

- immediately after a valid schedule location is installed;
- on aligned local minute boundaries;
- after schedule/location changes;
- after timezone or offset changes;
- at civil midnight;
- after resume or a wall/monotonic discontinuity.

`revision` changes only when date, zone, location identity, status, or event identity changes. Marker-only minute updates retain it. A transaction replaces date, marker, events, segments, and display times together.

Panel remains free of `Timer`, `SystemClock`, `ElapsedTimer`, `Process`, `FileView`, astronomy, filesystem, network, and timezone authority.

---

## 6. `MoonModel.js` and lunar Service snapshot

### 6.1 Pure API

CommonJS exports are exactly:

```js
[
  "orientationForLatitude",
  "phaseAt"
]
```

Use the dependency-free low-order Meeus/SunCalc geocentric approximation frozen in `w3-lunar-research.md`: Julian days from J2000, corrected solar longitude, corrected lunar longitude/latitude/distance, positive elongation phase, and Sun–Moon incidence illumination. No Date calendar fields, locale API, QML object, package, network, or rounding.

`phaseAt(epochMs)` accepts only finite numeric ECMAScript Date-range Unix milliseconds.

Failure:

```json
{"ok":false,"error":"invalid-epoch"}
```

Success fields are exactly:

```json
{
  "ok": true,
  "phase": 0.6495230623756667,
  "ageDays": 19.180798505557288,
  "illumination": 0.7948970595391965,
  "trend": "waning",
  "phaseId": "waning-gibbous",
  "phaseName": "Waning Gibbous"
}
```

Bounds and naming:

- `phase ∈ [0,1)`, `ageDays = phase × 29.530588853`, `illumination ∈ [0,1]`.
- `phase < 0.5` is waxing; exactly 0.5 is waning.
- Names use unrounded phase and equal octants centered on principal phases:

| Interval | ID | Name |
|---|---|---|
| `[15/16,1) ∪ [0,1/16)` | `new-moon` | `New Moon` |
| `[1/16,3/16)` | `waxing-crescent` | `Waxing Crescent` |
| `[3/16,5/16)` | `first-quarter` | `First Quarter` |
| `[5/16,7/16)` | `waxing-gibbous` | `Waxing Gibbous` |
| `[7/16,9/16)` | `full-moon` | `Full Moon` |
| `[9/16,11/16)` | `waning-gibbous` | `Waning Gibbous` |
| `[11/16,13/16)` | `last-quarter` | `Last Quarter` |
| `[13/16,15/16)` | `waning-crescent` | `Waning Crescent` |

`orientationForLatitude(latitude)` returns:

- null/undefined → `{ok:true,orientation:"northern",source:"default"}`;
- finite `0..90` → northern/location;
- finite `-90..<0` → southern/location;
- otherwise → `{ok:false,error:"invalid-latitude"}`.

Northern waxing is right-lit and waning left-lit; southern is mirrored. Equator uses northern convention. Orientation is iconographic only and never changes astronomical values.

### 6.2 Service snapshot

On success, `moonPhase` is exactly:

```json
{
  "ok": true,
  "calculatedAtMs": 1788270540000,
  "phase": 0.6495230623756667,
  "ageDays": 19.180798505557288,
  "illumination": 0.7948970595391965,
  "trend": "waning",
  "phaseId": "waning-gibbous",
  "phaseName": "Waning Gibbous",
  "orientation": "northern",
  "orientationSource": "location"
}
```

On failure it is exactly `{ok:false,error:"invalid-epoch",calculatedAtMs:<finite attempted time>}` or `{ok:false,error:"invalid-latitude",calculatedAtMs:<finite attempted time>}`. No fabricated phase fields are retained.

Calculate at Service startup independently of controller/location initialization. Refresh on the first aligned 15-minute boundary thereafter and on wall-clock discontinuity. A location change recalculates orientation; phase remains epoch-only. The snapshot must never be more than 15 minutes old during normal runtime.

A lunar refresh performs zero controller requests, state/settings writes, network calls, or schedule changes. Lunar failure is isolated from all solar/manual behavior. Setup state remains calculable using default northern orientation.

### 6.3 Lunar model gates

Use the five UTC fixtures and tolerances from `w3-lunar-research.md`, including the captured 2026-09-01 Hilversum fixture (`phase≈0.649523`, `illumination≈79.49%`, northern waning-gibbous, lit left). Also require:

- exact export/invalid/boundary tests;
- byte-identical results under UTC, Amsterdam, New York, Tokyo, Auckland, Kathmandu, Kiritimati, and Honolulu;
- deterministic six-hour sweep from 1900 through 2100 with no invalid value or backward phase except the legal wrap;
- equator/pole/no-location orientation cases.

---

## 7. `MoonPhaseIcon.qml`

Public properties are exactly:

```qml
property real illumination: 0
property string trend: "waxing"
property string orientation: "northern"
property color foreground: Color.foreground
```

Everything else is derived/private. The parent controls size, visibility, tooltip, and accessibility.

Rendering is only:

1. circular `Rectangle` shadow disk;
2. filled `ShapePath` illuminated region;
3. transparent circular `Rectangle` hairline outline.

Forbidden: `Text`, `OpticalGlyph`, emoji, icon font, `Canvas`, shader, mask, image, SVG, URL, and asset dependency.

For center `(cx,cy)` and radius `r`:

```text
hemisphere = southern ? -1 : +1
trendSide  = waxing ? +1 : -1
side       = hemisphere * trendSide
terminator = side * (1 - 2 * illumination)
kappa      = 0.5522847498307936
```

Draw the outer semicircle on `side` and return bottom-to-top along the elliptical terminator using four cubic Bézier quadrants. Use `Shape.CurveRenderer`.

Theme contract:

- lit: `foreground`;
- shadow: foreground at 0.12 alpha;
- outline: `Style.normalBorderFor(foreground, Color.accent)`;
- outline width: `Style.spacing.hairline`.

New moon stays dark but outlined; no fake minimum crescent. At 128×128, lit area must be within 0.02 of requested illumination after excluding outline pixels. All eight phases, both orientations, sizes 16/24/58, scales 1/1.5/2, and light/dark themes must be finite, bounded, unclipped, and warning-free.

---

## 8. `DaylightTimeline.qml`

### 8.1 Public API

```qml
required property var snapshot
required property var moonPhase
property bool current: false
property color foreground: Color.foreground
property string fontFamily: Style.font.family
signal focusRequested()
function moveSelection(direction): bool
function activateSelection(): bool
function clearPin()
```

The component owns only ephemeral `selectedEventKey` and `pinnedEventKey`. It owns no clock, astronomy, process, file, network, settings, or controller call.

### 8.2 Geometry and styling

- Component/rail slot height: `Style.space(58)`; no implicit-height change in any state.
- Whole hover/focus interaction band: full slot, at least 48 logical pixels high.
- Track: `Style.space(6)` high.
- Painted sun/moon: `Style.space(16)` centered on the current wall-time x.
- Logical `railStart` and `railSpan` are inset by marker radius; marker, event ticks/arrows, and daylight segments share them exactly.
- Marker tooltip target: at least `Style.space(32)²`.
- Each event target: at least `Style.space(32)²`; sunrise and sunset targets are vertically displaced so two nearly equal x positions remain separately clickable. The target itself is non-painting: selection MUST NOT draw a little rectangular target box.
- Base/night track: foreground at existing 0.12 alpha.
- Daylight: `Style.selectedStateColor(foreground, Color.accent)`.
- Sun: filled selected-state center plus four short cardinal rays, so it remains distinguishable from a full moon without color.
- Moon: `MoonPhaseIcon`; show only when a valid timeline says night and the lunar snapshot is valid.
- Invalid lunar data uses a neutral outlined marker, not a fake moon. Unavailable timeline uses a neutral outlined marker and no daylight claim.
- Native border/focus/hover helpers only; no reference-image yellow/cream, private font, physical-pixel constant, nested card, glow, bounce, orbit, or scrub affordance.

Normal minute marker movement uses 160 ms OutCubic only when `TimelineModel.shouldAnimateMarker` allowed it. The first render/open never animates from zero. Event/segment changes may animate for 160 ms only when date/zone/location revision is unchanged and every endpoint moves by at most two wall minutes; otherwise snap. Arrow reveal is 120 ms OutCubic.

### 8.3 Events, hover, and pin

At rest, each real event has one faint hairline tick. Full glyphs are:

- sunrise `↑`, from above;
- sunset `↓`, below.

Full arrows reveal while any of these is true: whole-rail hover, `current`, event hover, or a pin exists. Pinned arrow remains visible and uses selected styling. Keyboard selection uses selected arrow color and weight plus the retained whole-row focus cue; it never paints the 32-unit hit-target rectangle. Arrow alignment stays exact; only hit target and tooltip placement clamp.

Ordinary tooltip/pinned copy is exact:

```text
Sunrise {Locale.ShortFormat}
Sunset {Locale.ShortFormat}
```

If the projected time is ambiguous, append:

```text
 · UTC−04:00
 · UTC−05:00
```

Use U+2212 for negative offsets. Build locale short-time text from projected wall components, not by formatting the event epoch in the shell timezone.

- Hover uses native `PanelToolTip` with its 400 ms delay.
- Left click pins immediately; clicking it again unpins; clicking another transfers the pin.
- A hovered event temporarily wins display; its end restores the pin.
- At most one label exists; it overlays/clamps and never changes layout.
- Clear pin on close, date/zone/location revision replacement, or disappearance of its exact event key.
- No right/middle click, wheel behavior, dragging, scrubbing, schedule mutation, or warmth mutation.

Marker tooltip copy:

- day: `Current time · {short time}`;
- valid night moon, line 1: `{Phase Name} · {rounded percent}% illuminated`;
- valid night moon, line 2: `Current time · {short time}`.

Do not permanently print phase text. The moon tooltip never says visible/risen. Optional age text is not part of Wave 3.

### 8.4 Selection and accessibility

Event selection order is real epoch order, not x order. On first focus choose the first event at/after `nowMs`; if all have passed, choose the last. With one event Left/Right is a no-op; with none selection and activation are no-ops.

- `moveSelection(-1|+1)` moves with clamping, does not wrap, and returns whether selection changed.
- Any other direction returns false.
- `activateSelection()` toggles the selected pin and returns true only when an event exists.
- Pointer entry emits `focusRequested()` so Panel can show native whole-row focus chrome; that larger cue remains present while the small event targets stay non-painting.

Expose:

- timeline role/group name: `24-hour daylight timeline`;
- normal description: `Daylight from {sunrise} to {sunset}. Current time {time}.`;
- polar day: `Daylight all day. Current time {time}.`;
- polar night: `Night all day. Current time {time}.`;
- unavailable: `Solar events unavailable. Current time {time}.`;
- event children as `Accessible.Button`, named `Sunrise, {time}` / `Sunset, {time}`, with Press identical to click;
- marker accessible name including current time and UTC offset when ambiguous; at night append phase and rounded illumination.

Hidden arrows remain in the accessibility tree. Focus chrome is non-color-only.

---

## 9. Panel integration

Replace only the contents of the existing 58-unit rail slot. Remove permanent `SUNSET`/`SUNRISE` labels. Preserve the hero, source row, three setting rows, actions, `520 × 440` nominal dimensions, editor heights, spacing, and all native shell ownership/handoff behavior.

Normal roving order is exactly:

```text
Timeline → Automatic → Warmth → Transition → Primary action → Location → Forget
```

`open()` sets focus to **Automatic**, not Timeline. Therefore arrows do not reveal on keyboard-open. Up/`k` from Automatic reaches Timeline; Down/`j` from Timeline returns to Automatic.

When Timeline is current:

- Left/Right call `moveSelection(-1/+1)`;
- Enter/Space call `activateSelection()`;
- Up/Down and `k/j` leave in normal roving order;
- Tab/Shift+Tab retain existing Clock-style neighboring-panel handoff;
- Escape closes immediately and close calls `clearPin()`.

On every other row, existing Left/Right, activation, shortcuts `n/a/l`, Delete/`x`, and editor contracts remain unchanged. Every pointer action has its keyboard/accessibility equivalent.

Hero and override event times must use `timeline.displayTimes`, so location timezone and timeline cannot disagree. Missing projection displays `—`; it must not fall back to formatting an epoch in the wrong zone.

Warmth row copy changes to exactly:

```text
WARMTH
Saved automatically · Live during automatic warmth
```

The value remains `{kelvin} K`.

---

## 10. Persisted-first live Warmth

### 10.1 Panel → Service API

Service is the sole Warmth writer.

```text
stepNightTemperature(direction) -> bool
setNightTemperature(value) -> bool
```

`stepNightTemperature` accepts only integer `-1` or `+1`. It reads the current canonical Service `_settings`, changes by 250 K, clamps to `1000..6500`, and returns false without a write at a bound or for invalid direction. `setNightTemperature` retains the existing strict absolute-settings validation for non-Panel callers.

On a successful step:

1. Service synchronously updates `_inlineEntry` and canonical `_settings` through the existing complete-transaction merge.
2. Service invokes `shell.updateEntryInline(moduleName, merged)`, which initiates Omarchy’s write.
3. Service recalculates from fresh `Date.now()`.
4. Only then may it submit the recalculated target.

Omarchy has no disk acknowledgement; “persisted-first” means local canonical publication and write initiation precede backend submission, not fsync acknowledgement.

Panel calls `stepNightTemperature(direction)` exactly once per pointer/key step. If true, it immediately copies `service.inlineSettings` to Panel and host settings. Panel must not call `persistSettings`, `updateEntryInline`, or merge a Warmth entry itself. If Service is absent/fails, Panel does not fake a local change.

There is no rollback on close, Escape, editor cancellation, apply failure, or hot reload.

### 10.2 Live predicate and behavior

Define:

```text
live = initialized
    && scheduleValid
    && automationEnabled
    && no controller override
    && backendReady
    && recalculated target.kind == "temperature"
```

| State/event | Frozen result |
|---|---|
| Full night or polar night | Save, then request exactly the new Kelvin. |
| Evening/morning transition | Save, then request the fresh smoothstep target quantized to 10 K. Never jump directly to endpoint Kelvin. |
| Day, polar day, or exact zero-warmth boundary | Save only; issue no `setDesired`. |
| Automatic paused | Save only. Resume later uses the saved value. |
| Panel/external override | Save only; preserve exact target/source/expiry. |
| Backend unavailable/unprobed | Save only; do not create optimistic actual state. |
| Apply failure | Keep preference; retain verified actual; expose existing `apply-failed`; retry only latest target after health recovery. |
| Rapid steps | Commit every preference; latest backend generation wins and 5-second temperature-write limit remains. |
| Close/Escape | No cancel; a queued committed apply may finish. |
| Hot reload | New Service reads committed setting; old authority cannot publish/write; no neutral flash. |

No intent named `preview` is added. Live applies remain `intent:"schedule"` and do not create an override.

### 10.3 Service → Controller CAS guard

Extend `setDesired` with optional:

```json
"ifActual": {"kind":"temperature","temperature":3500}
```

Service includes the latest published actual (identity or temperature, excluding gamma) on every schedule request that could mutate. Override requests retain existing semantics and need not carry it.

Under `Backend.command_lock`, immediately before mutation, Controller performs its existing fresh probe and reconciles an uncertain controller attempt. Continue only if the observation matches at least one of:

1. `desired` (no write is needed);
2. `ifActual`;
3. a controller-owned state proven by this same preflight: either `_reconcile_attempt(actual)` consumed a non-null `last_attempt`, or the observation matches the immediately preceding superseded apply token’s verified ack in the same attachment epoch with no intervening published observation.

An arbitrary older `last_ack` is not sufficient. Controller must retain the ack’s attachment epoch/generation (or equivalent chain token) so an external change that merely equals stale plugin history still fails the guard.

Otherwise:

- perform zero mutation and zero retry;
- publish the exact observation as `actual`;
- create `runtime_override = {target:<exact observed identity/K>, until:<current boundary>, source:"external"}`;
- clear pending/deferred scheduled work and cancel the current apply token;
- return correlated `backendStatus`, not optimistic success.

`ifActual` uses the same validation as desired. Invalid values reject the request. Its absence preserves existing callers. This guard does not weaken generation checks, one-command serialization, retries `(0,250 ms,1 s)`, verification, deferred health recovery, override retention, shutdown CAS, or hot-reload barriers.

### 10.4 Live-preview gates

1. Full night sends committed Kelvin; day/zero boundary sends none.
2. Both transitions send exact smoothstep/10 K targets.
3. Paused, override, unavailable, and unprobed cases save only.
4. Fake shell proves canonical inline publication/write call occurs before `setDesired`; unrelated inline keys survive.
5. Panel harness proves one Service call per step, immediate sync, exact copy, and no direct Warmth persistence.
6. Rapid blocked/rate-limited steps produce only the latest physical write/publication.
7. External state changed after last Service status but before apply causes no plugin write and one exact external override.
8. Failed apply keeps setting/actual truthful and recovers only latest target after health.
9. Close/cancel causes no rollback/cancel operation.
10. Reload before apply, during rate wait, and after write-before-ack permits only fresh authority, with no flash/false override.

---

## 11. Complete acceptance gate

### 11.1 Automated

Every existing suite remains green at its current count before Wave 3 assertions are added:

- Solar 16/16; Schedule 26/26; Location 68/68; Controller 27/27 baseline;
- manifest/Omarchy validation;
- source contract;
- QML entrypoints (`dashboard=440`, `location=375`, `manual=223` baseline);
- QML service and location conflict/CAS.

Add the focused tests named in section 3. Required adversarial timeline cases are: reference reconstruction, actual-machine fixture, exact boundaries, midnight, spring/fall DST, ambiguous folds, runtime timezone replacement, polar day/night, one-event seam, short daylight overlap, edge events, marker/event overlap, malformed snapshot, suspend/clock jump, no side effects, all bar edges/scales/themes, and accessibility Press actions.

No test may relax a v1 assertion to make Wave 3 pass.

### 11.2 Installed-output loop

For each UI-bearing piece:

1. Record Git HEAD/status, shell/private/Weather hashes and modes, controller/attachment/`hyprsunset` PIDs, IPC status, native identity/temperature/gamma, network sockets, QML warnings, and coredump count.
2. Run every repository suite and `omarchy plugin validate .` before installation.
3. Commit the candidate, run `omarchy plugin update jgordijn.night-light --yes`, and verify installed production/test files are byte-identical to that commit. Restart the shell only when required to instantiate newly added QML, then prove one controller daemon, one attachment, and one shared `hyprsunset`.
4. Exercise real rest, whole-rail hover, sunrise hover, sunset hover, pin/transfer/unpin, marker tooltip, keyboard Up from Automatic, Left/Right, Enter/Space, Escape, Tab and Shift+Tab. Exercise all four bar edges in the harness and the real configured edge installed.
5. Capture the real panel beside installed Clock at identical theme/scale. Also capture deterministic new/quarter/full/crescent/gibbous icon fixtures and DST/polar/narrow harness states.
6. Verify timeline/lunar interactions caused zero settings/location/network/controller-display writes. For Warmth, use the fake backend for race/failure cases; any live ±250 K smoke must record the original preference/actual state, return to it through the same public API, and prove final content hashes/native probes match.
7. Inspect logs, warnings, coredumps, FDs/RSS, processes, permissions, status, and hashes again. Any regression returns the piece to build status.
8. Give captures and the installed interactive plugin—not a builder summary—to a fresh-context critic. Iterate until its piece verdict is WOW/PASS.

### 11.3 Final randomized blind gate

Five reviewers, unaware of ordering/ownership, compare installed Night Light and installed Clock under the same theme, scale, bar edge, and randomized left/right order.

| Criterion | Weight | Pass evidence |
|---|---:|---|
| One-glance truth/hierarchy | 25% | State and next event identified within 3 seconds; marker understood as current civil time. |
| Native visual fit | 20% | Same palette, spacing, typography, density, borders, and restraint as Clock. |
| Event discoverability/access | 20% | Both times found uncoached by pointer and keyboard; pin/unpin understood. |
| Marker/lunar legibility | 15% | Day/night is color-independent; principal moon families distinguishable at 1×/2×. |
| Motion/microstates | 10% | No opening sweep, stale bubble, jitter, clipping, or geometry jump. |
| Responsive robustness | 10% | Labels clamp and targets work on all edges/narrow fitted bounds. |

Pass requires all:

1. Night Light weighted mean at least Clock’s;
2. no Night Light category more than 0.2 below Clock;
3. at least 3/5 prefer Night Light overall;
4. zero accessibility, clipping, stale-state, side-effect, persistence, or backend-truth defect.

Screenshots establish rendering only. Physical color remains accepted through native `hyprctl` probes and Service/controller telemetry.

## 12. Final release blockers

Do not ship Wave 3 if any v1 blocker remains or if any of these is true:

1. Marker position is derived from sunset-to-sunrise progress or elapsed epoch duration of a DST day.
2. Today’s rail uses tomorrow’s sunrise or fabricates a polar event.
3. Panel owns a clock/timezone/astronomy/process or timeline state is persisted/added to stable IPC.
4. Date, zone, marker, and event labels can come from mixed transactions.
5. Opening the panel animates the marker from zero or midnight/DST sweeps across the rail.
6. An event is pointer-only, inaccessible while hidden, unclamped, or changes panel height.
7. Lunar phase depends on timezone/location, a font glyph, an asset, or a visibility claim.
8. Lunar refresh causes any display, storage, network, or schedule side effect.
9. Panel writes Warmth directly, a committed step rolls back, or daytime creates a preview write.
10. A warmth apply can overwrite an unobserved external change.
11. Rapid input/hot reload can let stale authority win or bypass the existing write limiter/retry/CAS lifecycle.
12. Full old and new automated, installed, and blind gates have not passed.
