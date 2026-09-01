# jgordijn.night-light — v1 specification

Status: architecture frozen for v1. This document is normative; the research reports in `.work/reports/` are supporting material, not additional requirements.

## 1. Product promise

`jgordijn.night-light` is one polished Omarchy bar widget that warms the display smoothly from calculated sunset to sunrise. Once it has coordinates, scheduling is entirely local and works offline indefinitely.

The v1 quality target is not feature count. It is to be at least as deterministic, native-looking, keyboard-complete, and truthful as the installed `omarchy.clock`, while doing one harder job well: coordinating location, solar time, and an external display controller without lying or fighting another controller.

### v1 defaults on this machine

The implementation target is the installed environment inspected on 2026-09-01:

- Omarchy `4.0.1-2`; Quickshell `0.3.1`; Qt `6.11.2`
- Hyprland `0.56.1`; hyprsunset `0.4.0`
- Python `3.14`, Node, `hyprctl`, `uwsm-app`, and the timezone database are present
- Omarchy Weather currently stores `Hilversumse Meent`, `52.27115, 5.13729`
- `hyprsunset` is already running at `6500 K`, identity `false`, gamma `100`
- first-party `omarchy.nightlight` is enabled and its `NightLight` indicator is in the default indicator set

A fresh enabled plugin MUST adopt the valid Weather coordinates without making any Night Light network request. It MUST coexist with the running first-party service and daemon.

## 2. Deliberate v1 scope

### Included

- One singleton solar scheduler and one bar widget/popup
- Read-only reuse of exact Omarchy Weather coordinates
- Offline direct-coordinate entry
- Open-Meteo locality search when the user opens Manual Location
- Explicit-consent wttr.in IP approximation
- Smooth configurable sunset/dawn transitions
- Manual warm/daylight override until the next solar boundary
- Detection and adoption of first-party, CLI, native-profile, or direct `hyprctl` changes
- Atomic private location state, complete keyboard operation, IPC diagnostics, and deterministic tests

### Not included

- GeoClue, portals, GPS, SSID/BSSID collection, or a new package dependency
- A sunrise/sunset web API
- Per-monitor temperatures (hyprsunset applies one global matrix)
- Fixed clock schedules, elevation/terrain correction, custom day temperature, gamma control, or arbitrary transition curves
- VPN-interface guessing. Tailscale is split-tunnel on this machine; `tun` presence is not evidence of public egress.
- Automatic disabling of first-party `omarchy.nightlight`
- Automatic writing or deletion of Weather state

The absence of a fixed-time fallback is intentional. With no coordinates and no network, v1 offers direct coordinates and manual warmth; it never invents a timezone-centroid location.

## 3. Package and file boundary

The Git-managed plugin checkout contains these production entry-point artifacts:

```text
manifest.json
BarWidget.qml
Panel.qml
Service.qml
SolarModel.js
ScheduleModel.js
LocationModel.js
Controller.py
LICENSE
```

It also carries `README.md`, this specification, `PROGRESS.md`, and the deterministic tests that validate the installed sources:

```text
test/solar-test.cjs
test/schedule-test.cjs
test/location-test.cjs
test/controller-test.py
test/manifest-test.sh
test/source-contract-test.sh
test/qml-entrypoints-test.sh
test/qml-service-test.sh
test/qml-service-conflict-test.sh
```

Omarchy clones the complete Git checkout; only manifest entry points are loaded at runtime. No symlinks, vendored packages, generated assets, icons, shell fragments, or install-time migrations are allowed in v1.

### Manifest contract

`manifest.json` MUST contain:

```json
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
```

Do not declare kind `panel`: the popup is nested under the bar widget, exactly like Clock. The service is loaded once; the widget may exist per monitor. No timer, network request, state write, solar authority, or `hyprctl` process may live in `BarWidget.qml` or `Panel.qml`.

## 4. Smallest separately buildable pieces

Build in this order. A piece is complete only when its stated gate passes without later pieces.

| # | Piece | Files | Stable contract | Independent gate |
|---:|---|---|---|---|
| 1 | Package | `manifest.json`, README, license | Exact manifest above | JSON parse and `omarchy plugin validate .` |
| 2 | Astronomy | `SolarModel.js` | Coordinates + epoch → explicit normal/polar events | Reference fixtures, timezone matrix, polar/property sweep |
| 3 | Schedule | `ScheduleModel.js` | Events + preferences + epoch → phase/warmth/target/next wake | Boundary, monotonicity, clock-jump, and quantization tests |
| 4 | Location policy | `LocationModel.js` | Raw Weather/state/provider data → validated immutable snapshots | Parsing, schema, stale, candidate-jump, and privacy tests |
| 5 | State/network/backend | `Controller.py` | Private state + bounded provider calls + one serialized hyprsunset writer | Fake HTTP/process/socket/filesystem tests |
| 6 | Scheduler service | `Service.qml` | One authoritative reactive state object and IPC API | Bare QML harness; no write before valid initialization |
| 7 | Bar shell | `BarWidget.qml` | Native button and exact nested-panel ownership forwarding | Bare/delayed injection; four bar edges; finite geometry |
| 8 | Experience | `Panel.qml` | Fixed-geometry state renderer and keyboard editor | State matrix, focus, copy, scale, theme, and handoff tests |
| 9 | Integration | all | Install/enable/reload/disable/remove and first-party coexistence | Live smoke, screenshot/OCR, telemetry, soak, cleanup |

`SolarModel.js`, `ScheduleModel.js`, and `LocationModel.js` use the installed Clock house style: `var`, ordinary functions, plain objects, no QML objects, and guarded `module.exports`. They MUST run unchanged under QML and Node.

## 5. Persistent contracts

### 5.1 Inline Omarchy settings

Only user schedule/presentation preferences belong on the `jgordijn.night-light` bar layout entry in `~/.config/omarchy/shell.json`:

```json
{
  "id": "jgordijn.night-light",
  "automationEnabled": true,
  "nightTemperature": 4000,
  "transitionMinutes": 45,
  "stockIndicator": {
    "choice": "pending",
    "before": null,
    "after": null
  }
}
```

Defaults apply when keys are absent; enabling the plugin need not immediately expand the entry. Valid values are:

- `automationEnabled`: boolean, default `true`
- `nightTemperature`: integer `1000..6500`, default `4000`
- `transitionMinutes`: integer `0..180`, default `45`
- `stockIndicator.choice`: `pending`, `keep`, or `hidden`
- `before`/`after`: arrays used only for compare-and-swap restoration of the stock indicator

Invalid runtime edits do not partially apply. The service retains the last fully valid settings transaction, reports `settings-invalid`, and defaults only on first initialization when no valid transaction exists.

Every settings change MUST:

1. merge all existing keys into `{id: "jgordijn.night-light", ...}`;
2. assign the merged object to the widget, panel, and visible controls immediately;
3. call `bar.shell.updateEntryInline(moduleName, merged)`;
4. reconcile against the resulting `shell.shellConfig` in the service.

Never persist current temperature, event epochs, phase, busy/error state, countdowns, or manual overrides to `shell.json`.

### 5.2 Private location state

Location policy must commit atomically with location data, so it lives outside `shell.json` at:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/settings/jgordijn.night-light.json
```

Schema v1 is exact:

```json
{
  "schemaVersion": 1,
  "revision": 4,
  "mode": "weather",
  "autoConsentVersion": 0,
  "manual": null,
  "weatherCache": {
    "label": "Hilversumse Meent",
    "admin1": "",
    "country": "",
    "latitude": 52.27115,
    "longitude": 5.13729,
    "timezone": "",
    "source": "weather",
    "precision": "selected-locality",
    "observedAt": "2026-09-01T10:00:00Z"
  },
  "autoIpCache": null
}
```

`mode` is exactly one of `none`, `weather`, `manual`, or `auto-ip`. A non-null location record has all keys shown above. Valid source/precision pairs are:

- `weather` / `selected-locality`
- `manual-search` / `selected-locality`
- `manual-coordinates` / `coordinates`
- `auto-ip` / `approximate-city`

`revision` is a non-negative integer incremented by one on each successful state transaction and used to deduplicate watcher echoes. Latitude and longitude are finite JSON numbers in `[-90,90]` and `[-180,180]`. Labels are trimmed and capped at 120 Unicode code points; admin/country/timezone at 80. Timestamps are UTC ISO-8601 strings. Unknown keys are ignored when reading and omitted when rewriting.

State writes MUST use a same-directory `0600` temporary file, complete write, `fsync`, `os.replace`, final `chmod 0600`, and directory `fsync`; the parent is mode `0700`. The prior file survives every failed write. No normal state file or runtime socket may be group/world accessible.

Read outcomes remain distinct: `absent`, `valid`, `temporarily-unavailable`, `malformed`, and `unsupported-schema`. Malformed/unsupported files are never silently replaced. An absent file bootstraps to Weather only when Weather currently contains valid coordinates; otherwise setup remains `none` and no file is written until the user acts.

“Forget location” deletes this file only after confirmation, changes the active mode to `none`, cancels network work, stops future schedule writes, and leaves the current display matrix untouched. It never changes `weather.json`.

### 5.3 Runtime state

Runtime files are session-scoped:

```text
$XDG_RUNTIME_DIR/jgordijn-night-light/$HYPRLAND_INSTANCE_SIGNATURE/
  controller.lock
  control.sock
```

The directory is `0700`, files/socket are `0600`. No coordinates, query text, provider body, SSID, BSSID, public IP, or route details are logged or stored there.

## 6. Location semantics

Location and active schedule are separate immutable snapshots:

- `draftLocation`: editor/query/candidate only
- `committedLocation`: persisted source selected by `mode`
- `activeScheduleLocation`: last committed location that produced a valid schedule

The old schedule remains active until a candidate validates, persists, and computes successfully. A failed candidate can never relabel or alter it.

### Source priority and startup

1. A valid selected source is used from private state.
2. In `weather` mode, current valid Weather coordinates replace and refresh `weatherCache` without network access.
3. If Weather is absent, partial, malformed, or temporarily being rewritten, retain `weatherCache` and display `Last known`.
4. Missing/corrupt Weather never changes mode and never triggers IP detection.
5. `manual` uses only `manual`; `auto-ip` uses only `autoIpCache` plus its consented refresh policy.

Weather is read-only from `${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/settings/weather.json` (with the installed `~/.local/state/...` path as fallback when `XDG_STATE_HOME` is unset). Debounce watcher events for 200 ms and retry parse five times at 100 ms because Weather writes non-atomically.

### Manual mode

The field accepts either:

- direct strict decimal coordinates such as `52.27115, 5.13729`; or
- a locality query of at least three non-space characters.

Strict coordinates support an optional leading sign and decimal point, but reject exponent/hex notation, booleans, blanks, partial pairs, and out-of-range values. `0,0` is valid. Coordinate entry works offline and is labeled `Coordinates`.

Locality search uses `https://geocoding-api.open-meteo.com/v1/search`, count 5, `format=json`, and the UI locale language where supported. Search starts only after Manual Location is opened and the user changes the field, debounced 350 ms. Free text is never committable. A result row is `name · admin1 · country`; committing stores the provider coordinates, timezone, and canonical labels at full returned precision.

All search requests carry a monotonic `searchEpoch` and normalized query. Results publish only when both still match. Canceling is immediate; process cancellation is only an optimization.

### Automatic/IP mode

No IP request is legal before consent version 1. The exact disclosure is:

> **Use approximate location?**  
> Night Light will contact wttr.in. The provider sees your public IP and returns an approximate city. No IP address or response history is saved.

Buttons: `Cancel` and `Continue`.

The provider is exactly `https://wttr.in/?format=j1`. Validate `nearest_area[0]`; label every result `Approximate`. A first result is a candidate requiring `Use this location`. Warn: `This may be wrong when using a VPN or proxy.`

An accepted cache remains usable indefinitely offline. It becomes visibly stale after 24 hours. With consent, make at most one stale refresh per shell session plus a user-requested retry; never poll. A candidate more than 250 km from the accepted cache is not installed automatically: show `Approximate location changed` with `Keep current` and `Review new location`. This explicit review replaces unreliable VPN-interface and timezone-centroid heuristics.

### Network envelope

`Controller.py` owns provider I/O so queries never enter shell strings or process argv. It uses Python HTTPS with an allowlist of the two hostnames above, certificate verification, 3-second connect/socket timeout, 6-second total deadline, a 256 KiB hard body limit, and `jgordijn.night-light/1.0.0` User-Agent. It recognizes HTTP 429 separately and retries only at `250 ms`, `1 s`, then stops. User cancellation and stale generations suppress publication regardless of transport cancellation.

No provider call is needed for solar calculation or normal daily operation.

## 7. Solar and transition contracts

All model inputs and outputs are Unix epoch milliseconds. Local “minutes since midnight” are forbidden.

### `SolarModel.js`

Public API:

```text
validateCoordinates(latitude, longitude)
cycleAt(epochMs, latitude, longitude)
surroundingEvents(epochMs, latitude, longitude)
```

Use the dependency-free NOAA/SunCalc approximation with longitude positive east, conventional horizon altitude `-0.833°`, `DAY_MS=86400000`, `J1970=2440587.5`, `J2000=2451545.0`, and `J0=0.0009`. Calculate solar anomaly, equation of center, ecliptic longitude, declination, transit, and hour angle in double precision; use positive modulo and round only final display temperature.

Classify hour-angle ratio `x` with epsilon `1e-12`:

- `x >= 1-epsilon`: `polar-night`
- `x <= -1+epsilon`: `polar-day`
- otherwise finite `sunrise < transit < sunset`

At/near the poles classify from daily altitude extrema instead of dividing by near-zero. Never return fabricated events, `Invalid Date`, NaN, or Infinity. Search adjacent solar cycles up to 370 days only to find previous/next displayable events around polar seasons.

### `ScheduleModel.js`

Public API:

```text
validateSettings(raw)
evaluate(epochMs, location, settings)
```

`evaluate` returns:

```json
{
  "ok": true,
  "phase": "day",
  "warmth": 0,
  "target": {"kind": "identity", "temperature": 6500},
  "sunsetMs": 0,
  "sunriseMs": 0,
  "nextBoundaryMs": 0,
  "nextEvaluationMs": 0
}
```

Phases are `day`, `evening-transition`, `night`, `morning-transition`, `polar-day`, `polar-night`, or `error`.

For preceding sunset `S`, following sunrise `R`, configured edge duration `D`, use `d=min(D,(R-S)/2)` and `smooth(p)=p²(3-2p)`:

- before `S` or at/after `R`: warmth `0`
- `S..S+d`: increasing smoothstep
- `S+d..R-d`: warmth `1`
- `R-d..R`: decreasing smoothstep
- for `D=0`, warmth is `1` exactly on `[S,R)`

Temperature is `round(6500 + warmth*(nightTemperature-6500))`, clamped to `[nightTemperature,6500]`. Warmth zero produces target kind `identity`, not numeric `6500`; identity is a real hyprsunset state. Polar day holds identity; polar night holds full configured warmth. A calculation error retains the prior actual state and emits no target.

During transitions, target temperature is quantized to the nearest 10 K and evaluated at least every 5 seconds. In steady phases, evaluate/probe every 30 seconds. `nextEvaluationMs` is always finite, greater than now, and no later than the next meaningful target or boundary.

Every timer callback recomputes from fresh `Date.now()`. Suspend, wall-clock jumps, day rollover, DST, timezone changes, and location changes never replay missed samples. Timezone affects formatted labels only.

## 8. Backend ownership and first-party coexistence

### Controller topology

`Service.qml` opens one newline-JSON attachment process:

```text
/usr/bin/python <plugin>/Controller.py attach
```

Quickshell `Process.stdinEnabled` is used; no `bash -c`/`bash -lc`. `attach` connects to or starts a session daemon in the runtime directory. The daemon holds `flock(controller.lock)`. Multiple QML attachments may overlap during hot reload, but there is one daemon and one writer.

With no attachment, the daemon waits 8 seconds before release. A replacement service cancels release, preventing hot-reload flashes. After grace it performs compare-and-swap restoration, removes its socket/runtime files, and exits. The Python controller must never survive without a lease beyond this grace.

### Line protocol

Every request is one JSON object with protocol `1`, `requestId`, and `generation`. Operations are:

- `probe`
- `setDesired` with `{kind:"identity"}` or `{kind:"temperature",temperature:int}`, plus intent `schedule|override` and optional `overrideUntil`
- `readLocationState`, `writeLocationState`, `forgetLocationState`
- `geocode` with query/language/searchEpoch
- `autoLocate` with locationEpoch
- `cancel` with requestId

Responses are `ready`, `backendStatus`, `locationState`, `networkResult`, or `error`, echoing request/generation fields. Unknown protocol/operation is rejected. Lines over 64 KiB terminate that attachment. Obsolete generations cannot mutate state; only a valid `writeLocationState` can persist a location.

### hyprsunset semantics

Actual state is one of `unavailable`, `identity`, or `temperature(K)`. Probe only with separate argv commands:

```text
/usr/bin/hyprctl hyprsunset identity get
/usr/bin/hyprctl hyprsunset temperature
/usr/bin/hyprctl hyprsunset gamma
```

Bare `identity` and bare `reset` are forbidden because both write. Apply identity with `identity true`; apply Kelvin with `temperature <integer>`.

The controller has one command in flight and one latest pending desired state. It coalesces intermediate requests, enforces a 5-second minimum temperature-write interval, applies identity immediately at a boundary, verifies every write by probing, and reports errors rather than optimistic success. Command timeout is 2 seconds. Each desired state receives at most three apply attempts: immediate, after `250 ms`, and after `1 s`. After those fail it stops writing until a successful 30-second health probe, retaining only the latest target.

Discovery is scoped to `HYPRLAND_INSTANCE_SIGNATURE`: inspect the compositor socket and `/proc/<pid>/{exe,environ,stat}`, never global `pgrep`. If IPC works, adopt the existing daemon as shared. If a matching process exists but IPC is starting, wait up to 5 seconds. Only if neither exists may the controller launch:

```text
/usr/bin/uwsm-app -- /usr/bin/hyprsunset --config /dev/null --identity
```

Record exact executable, compositor signature, PID, process start time, and ownership. Never manage `hyprsunset.service`, kill an unowned process, call `omarchy toggle nightlight`, or start a second daemon.

On first attachment, record the actual baseline. On final release, restore it only if actual state still equals the controller’s last acknowledged write. If the controller started hyprsunset, apply/verify identity and stop only the recorded matching process. If shared, never stop it. If an external actor changed state, leave it untouched.

### External changes and overrides

Poll actual state every 5 seconds during transitions and every 30 seconds otherwise. A verified state change not matching a pending/acknowledged plugin write is external. Do not reassert.

- An external or panel manual change during astronomical night `[sunset,sunrise)` is held until sunrise.
- One during astronomical day is held until sunset.
- The exact observed identity or Kelvin is held; arbitrary Kelvin is not rounded to a preset.
- `Resume automatic` clears the override immediately and applies the current computed target.
- Override intent and expiry remain in the controller’s runtime status, so a brief shell/plugin reload preserves them; they are never persisted to disk.

A native hyprsunset profile, the stock indicator, `omarchy toggle nightlight`, and direct `hyprctl` therefore become visible manual overrides rather than competing writers. The first-party service remains enabled.

On resume or a material wall/monotonic-clock divergence, invalidate pending generations, probe at approximately 0, 1, and 3 seconds, then apply only the fresh current-time target.

## 9. Service state and IPC

`Service.qml` is the sole application state owner. It reads its inline entry reactively from `shell.shellConfig`, receives controller events, watches Weather state, evaluates pure models, and exposes read-only properties to every widget instance.

Initialization order is strict:

1. validate settings;
2. read private state and Weather state;
3. establish controller attachment and probe actual backend;
4. choose and validate committed location;
5. compute a valid target;
6. only then send a desired state.

No target may be written merely because QML completed loading.

The IPC target is exactly `jgordijn.night-light` (never `nightlight` or `omarchy.nightlight`). It provides:

- `status()` → JSON below
- `refresh()` → recompute and probe, no location network request
- `warm()` / `daylight()` → manual override
- `resume()` → clear override
- `open()`, `show()`, `close()`, `hide()`, `toggle()` → route through injected shell summon/hide/toggle for the focused monitor
- `forgetLocation()` → same confirmed action as the panel; direct IPC requires argument `confirm`
- `restoreStockIndicator()` → compare-and-swap restoration

`status()` schema is stable for v1 and excludes coordinates:

```json
{
  "schemaVersion": 1,
  "mode": "scheduled",
  "available": true,
  "phase": "day",
  "busy": false,
  "actual": {"kind": "identity", "temperature": 6500, "gamma": 100},
  "target": {"kind": "identity", "temperature": 6500},
  "location": {
    "mode": "weather",
    "source": "weather",
    "label": "Hilversumse Meent",
    "precision": "selected-locality",
    "stale": false,
    "observedAt": "2026-09-01T10:00:00Z"
  },
  "sunset": 0,
  "sunrise": 0,
  "nextBoundary": 0,
  "overrideUntil": 0,
  "nextUpdate": 0,
  "error": null
}
```

Top-level `mode` is `setup`, `scheduled`, `override`, or `paused`. `error` is null or `{code,message}` using stable codes such as `settings-invalid`, `state-malformed`, `location-unavailable`, `calculation-failed`, `backend-unavailable`, `apply-failed`, `offline`, and `rate-limited`.

## 10. Native bar and popup contract

### `BarWidget.qml`

Extend `qs.Ui.BarWidget`, set `moduleName`, and obtain the service with `bar?.shell?.serviceFor("jgordijn.night-light")`.

The root MUST expose `opened`, `open()`, `close()`, `closeForPopoutSwitch()`, and `popoutSwitchClosing`. Inject `bar`, `settings`, actual `WidgetButton` as `anchorItem`, and root as `hostWidget` into the nested panel. The panel uses `hostWidget || panel` as `KeyboardPanel.owner` and in `bar.switchPanelFrom()`.

Horizontal content is one stable-width native pill:

- day/polar day: sun glyph + `DAY`
- evening/morning transition: moon glyph + rounded actual `4.8k`, etc.
- night/polar night: moon glyph + configured `4.0k`
- override: same state plus a small non-color-only dot/mark
- setup/unavailable: location/warning glyph + `SET`/`ERR`

Vertical bars use one icon slot and no squeezed label. The tooltip is two lines: current plain-language state, then next transition/location source. The widget never disappears while loading or in error.

Inputs:

- left click: toggle panel
- right click: toggle manual warm/daylight
- middle click: Resume automatic (no-op with explanatory tooltip when already automatic)

The open-panel accent mark follows Clock’s desktop-facing edge, dimensions, and 120 ms behavior.

### `Panel.qml` composition

Use `qs.Ui.Panel`, `KeyboardPanel`, `PanelKeyCatcher`, `PanelActionButton`, `TextField`, `Color`, `Border`, and `Style`. `centerOnBar: true`. Nominal content width is `Style.space(520)` and dashboard content height is `Style.space(440)`; both use screen-aware fitted bounds and a Flickable. Runtime dashboard states keep one stable composition. Editors keep the same width but fit the active editor’s laid-out content up to the dashboard cap.

Visual hierarchy:

1. Hero icon and state title
2. One next-event sentence and source badge
3. Sunset-to-sunrise progress rail with fixed labels
4. Three fixed rows: `AUTOMATIC`, `WARMTH`, `TRANSITION`
5. Location/action footer

No hardcoded palette, private font, unscaled physical pixels, or color-only state. Use 140 ms OutCubic content transitions and editor contraction, and 160 ms rail/value transitions. Returning to the taller dashboard is immediate so controls are never exposed through a partially clipped expansion.

Exact primary runtime copy:

| State | Title | Detail |
|---|---|---|
| day | `Daylight` | `Sunset at {time}` |
| evening | `Warming` | `{nightK} K by {time}` |
| night | `Night light` | `Sunrise at {time}` |
| morning | `Cooling` | `Daylight by {time}` |
| override | `Manual override` | `Automatic resumes at {sunrise|sunset} · {time}` |
| polar day | `Midnight sun` | `Daylight until the next calculated sunset` |
| polar night | `Polar night` | `Night light until the next calculated sunrise` |
| setup | `Choose a location` | `Needed only to calculate sunrise and sunset.` |
| backend error | `Night Light is unavailable` | `hyprsunset did not respond. Your schedule is still saved.` |
| calculation error | `Schedule unavailable` | `The last display setting was left unchanged.` |

Source badges are `Weather`, `Manual`, `Coordinates`, `Approximate`, or `Last known · {age}`. Calculated event copy must not claim observed horizon accuracy.

Normal actions are `Warm now` or `Use daylight`, `Resume automatic` when overridden, `Change location`, and `Retry` only when actionable. Warmth changes in 250 K steps; transition choices are `Instant`, `30 min`, `45 min`, `60 min`, and `90 min` (hand-edited valid values still render numerically).

### Keyboard and focus

Normal mode uses a visible roving focus:

- Up/Down or `k/j`: previous/next control row
- Left/Right: change the focused row’s value
- Enter/Space: activate the focused action
- `n`: toggle warm/daylight now
- `a`: Resume automatic
- `l`: open location editor
- Tab/Shift+Tab: hand off to next/previous visible panel in the bar section
- Escape: close

In an editor, Tab/Shift+Tab cycles editor controls instead of handing off; arrows navigate search results; Enter selects/commits only a valid coordinate pair or current result; Escape cancels and restores focus to the originating row. Closing cancels all draft/search state.

Every pointer action has a keyboard equivalent. Every icon-only control has `Accessible.name` and a tooltip. Enter/Space both activate. Hit targets are at least 24×24 logical pixels and primary controls at least 32×32. Focus remains visible at scales 1, 1.5, and 2.

### Location copy

Setup options:

- `Use Weather location` — `{Weather label}` (only if current or cached Weather is valid)
- `Automatic (approximate)` — `Uses your public IP after you confirm`
- `Manual location` — `Search a locality or enter coordinates`

Manual helper: `Search uses Open-Meteo only while this editor is open.` Placeholder: `City or 52.27115, 5.13729`.

Search empty: `No matching localities.` Network error: `Couldn’t search. Check your connection and try again.` Rate limit: `Search is temporarily rate limited. Try again later.` These are distinct states and have no infinite spinner.

Forget confirmation:

> **Forget Night Light location?**  
> Removes Night Light’s saved location and consent. Omarchy Weather is unchanged.

Buttons: `Cancel`, `Forget`.

## 11. Stock indicator integration and installation

### Standard install

The supported install path is:

```text
omarchy plugin add <trusted-git-url> --enable
```

Omarchy validates, clones to `~/.config/omarchy/plugins/jgordijn.night-light`, rescans, adds the widget to the right section, and thereby loads its singleton service. Install performs no privileged operation, package install, Weather write, IP lookup, first-party disable, or systemd-unit change.

On first open, if the effective `omarchy.indicators` list contains `NightLight`, show a quiet setup card:

- title: `One Night Light shortcut`
- body: `Omarchy’s stock shortcut can stay, but it may show an older state. Hide it and use this panel as the source of truth?`
- buttons: `Keep both`, `Hide stock shortcut`

`Hide` is explicit. It copies the effective indicator array, removes only entries whose id is exactly `NightLight`, stores `before` and `after` in this plugin’s inline `stockIndicator`, then writes the merged `omarchy.indicators` entry. It does not disable `omarchy.nightlight`.

`Restore stock shortcut` is offered in settings. Restoration occurs only if the current effective array deep-equals `after`; then write `before`. If the user changed Indicators meanwhile, do not overwrite and show `Indicators changed since setup. Restore NightLight from Bar settings.`

### Disable/remove

Disable starts the controller’s 8-second grace; after it expires, compare-and-swap backend restoration occurs and no further writes happen. State remains so re-enable is lossless.

Before removal, README instructs users who hid the stock shortcut to choose `Restore stock shortcut`, then run:

```text
omarchy plugin remove jgordijn.night-light
```

Generic Omarchy removal cannot run a plugin-specific post-remove hook. Therefore location state is deliberately retained on ordinary remove and documented at its exact path. A user can press `Forget` before removal for a zero-location-data uninstall. No automatic cleanup may risk deleting Weather state or overwriting later Indicator edits.

## 12. Objective acceptance gates

All gates are release blockers.

### Deterministic model gates

- Solar fixtures for Greenwich, New York, Sydney, Quito, Tromsø, both hemispheres/solstices/equinoxes, leap day, UTC-midnight crossing, and `±180°` are within 5 minutes of provenance-labeled references.
- Solar outputs are byte-identical under `TZ=UTC, Europe/Amsterdam, America/New_York, Asia/Tokyo, Pacific/Auckland`.
- Latitude/longitude/polar/property sweep emits no NaN, Infinity, invalid chronology, or fabricated event.
- Schedule is continuous and monotonic at every positive-duration boundary, bounded `1000..6500`, and direct after clock/suspend jumps.
- Every invalid-input class preserves the prior valid transaction.

### Privacy/location gates

- On this actual machine, cold start in Weather mode uses `52.27115,5.13729` and records zero Night Light HTTP requests.
- Manual coordinates and valid Weather mode perform zero location requests.
- IP lookup cannot occur before the exact consent action; IP results are always labeled Approximate and first use requires review.
- Missing/corrupt Weather never invokes IP lookup or discards its cache.
- Delayed A→B search, auto, save, and Weather events cannot publish A after B commits.
- Offline restart from each valid source computes the same schedule and offers manual controls.
- State writes are atomic `0600`; malformed/unsupported state is retained; logs/status omit coordinates and provider/query bodies.

### Backend/lifecycle gates

- Fake-process tests prove signature-scoped discovery, separate argv, bounded startup/retry, one apply in flight, latest-wins coalescing, identity distinction, and compare-and-swap release.
- Live telemetry shows one controller and exactly one session hyprsunset, with plugin status converging to probes.
- Stock indicator, `omarchy toggle nightlight`, direct `hyprctl`, and native profile changes each create one visible override with no ping-pong.
- Disable, hot reload, shell restart, plugin update, remove, suspend/resume, and backend replacement create no duplicate writer, neutral flash during grace, orphan controller, or unowned-process kill.
- Apply/network/state failure never discards the active schedule, blocks manual controls, spins indefinitely, or reports optimistic success.

### QML/native gates

- `omarchy plugin validate .` passes; every manifest entry point loads in a minimal Quickshell harness with delayed fake injection and no exception, warning attributable to the plugin, NaN, or invalid geometry.
- Left/right/top/bottom bars, focused-monitor summon, one-click panel handoff, outside-click close, open accent, and Tab wrapping match Clock.
- Every defined setup/loading/offline/stale/rate-limit/save/polar/backend/override state renders useful bounded geometry; dashboard states are stable and editors settle to their tested fitted heights.
- Full keyboard contract, focus restoration, accessible names/tooltips, 24/32 px targets, and non-color-only state pass at 1×, 1.5×, and 2× in light/dark themes and narrow bounds.
- Enabling/opening/closing/disabling/re-enabling/removing does not restart Quickshell, add a crash directory, leak FDs, or show sustained RSS growth after warm-up.
- The first-open stock-shortcut card is tested in both choices; explicit Hide removes only `NightLight`, leaves `omarchy.nightlight` enabled, and compare-and-swap Restore neither loses nor overwrites unrelated Indicator edits.

### Blind quality gate

Use the installed Clock and this panel side by side under the same theme, scale, bar edge, and randomized left/right order. Capture normal, editor, error, keyboard-focus, and handoff sequences. Five reviewers who are not told which is third-party score each from 1–5 on:

- one-glance hierarchy (25%)
- native visual fit (20%)
- interaction completeness (20%)
- transition/microstate quality (15%)
- truth/persistence (10%)
- responsive robustness (10%)

Release requires:

1. no Night Light category mean below Clock’s category mean by more than `0.2`;
2. Night Light’s weighted mean at least Clock’s weighted mean;
3. at least 3 of 5 reviewers prefer Night Light overall;
4. zero hard-gate defect observed in the session.

Screenshots establish rendering only. Physical color behavior is accepted from `hyprctl hyprsunset temperature`, `identity get`, and plugin status telemetry, because compositor screenshots may omit the color transform.

## 13. Non-negotiable release blockers

Do not ship if any one is true:

1. Any startup IP request lacks prior consent.
2. Weather/manual-coordinate operation needs the network after coordinates are known.
3. Weather state is written/deleted or corruption silently becomes auto-IP.
4. Unvalidated coordinates reach astronomy or a shell/process command.
5. Free text or stale async output can commit a location.
6. Persistence is non-atomic, non-private, or failure loses the prior state.
7. A location/network failure changes the current matrix or disables manual control.
8. Identity is inferred from Kelvin or a mutating probe command is used.
9. More than one writer/apply process can exist or stale writes can win.
10. First-party/external changes cause oscillation instead of an override.
11. Shared hyprsunset is killed, its systemd unit is managed, or global `pgrep` decides ownership.
12. Offline restart loses a valid schedule.
13. A popup state clips, traps focus, lacks copy/action, changes geometry outside the documented fitted-editor transition, or is materially less polished than Clock.
14. Generic install changes Indicators or disables first-party Night Light without explicit consent.
15. The actual-machine zero-request Weather startup, lifecycle smoke test, and blind gate have not passed.
