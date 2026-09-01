# Night Light — live progress

_Last updated: 2026-09-01 20:53 CEST_

## Status

**Wave 3 is implemented. Final coherence edit is complete and awaiting the final commit/update/restart proof.**

The real Git-managed installation at `~/.config/omarchy/plugins/jgordijn.night-light` was the source under review. It is enabled beside installed Clock and, before this edit, was at `2b7a66a` with a clean tree. Current production includes the civil timeline, lunar model/renderer, projected event labels, and persisted-first live Warmth transaction.

## Proven coherence fix

Fresh installed exercise exposed one cross-piece copy defect while an override was active during `evening-transition`: the projected resume time was the next sunrise, but `Panel.qml` inferred the event name from the transition phase and rendered `Automatic resumes at sunset · 6:53 AM`.

`Panel.qml` now derives the boundary name from the same atomic projected event epochs used for the displayed time. `test/qml-entrypoints-test.sh` reproduces an evening-transition override whose projected boundary is sunrise and requires the coherent sunrise label. No timeline, schedule, backend, location, indicator, or settings behavior changed.

The complete controller suite also exposed a pre-existing nondeterministic test-harness race: the gated writer made the successor row observable immediately before `broadcast_status()` resumed from `drain()` and consumed its matching private ack allowance. The assertion still requires consumption, but now waits for that lifecycle boundary. The focused race passed 20 consecutive runs; no controller production code changed.

## Installed UI evidence

Fresh installed captures are under `.work/screens/final-coherence/` in the canonical checkout:

- `01-installed-rest.png`: fixed 520 × 440 dashboard, arrows hidden at rest, current nighttime waning-gibbous marker rendered on the rail.
- `02-installed-rail-hover.png` and `03-installed-sunrise-hover.png`: real installed pointer placement evidence. The current Hyprland 0.56 Lua cursor warp moved the visible pointer but did not synthesize a client hover event; therefore these two fresh images are not claimed as successful hover activation. The already-installed same-source proof at `.work/screens/w3-installed/sunrise-hover.png` remains the actual successful native-delay hover evidence.
- `04-installed-keyboard-timeline.png` through `07-installed-keyboard-unpin.png`: actual Up-to-Timeline focus, Left/Right selection, Sunrise pin, Sunset transfer, and unpin.
- `08-installed-escape-close.png`: immediate close.
- `09-installed-tab-handoff.png` and `10-installed-shifttab-return.png`: neighboring Tailscale handoff and return.
- `13-clock-night-light-side-by-side.png`: fresh same-theme, same-scale installed Clock/Night Light comparison.

The actual pinned labels were `Sunrise 6:51 AM` and `Sunset 8:30 PM`, matching current-day projected civil events. The hero’s `6:53 AM` is tomorrow’s projected sunrise and is intentionally a different event.

All three supplied references were used. Fresh timeline, dark-moon, and light-moon harness captures each compare at RMSE `0 (0)` to their frozen reference image. The moon harness also passed its area-fidelity matrix.

## Warmth and safety evidence

Live Warmth semantics were exercised only through isolated fake shell/controller/backend suites: full night, both transitions, day, paused, override, unavailable/unprobed, rapid steps, failure/recovery, external CAS, and hot reload all passed. No real Warmth row control was activated. Shell settings, private Night Light state, and Weather hashes stayed byte-identical through installed timeline interaction:

- shell: `610a5386cfa879abeb38bc64d72d05d3ad861d49d3643ded8d1ff47637d4c86c`
- Night Light state: `de79831674d32575f75ec991529b9dd564e382800707eceb2ddf526ba519a537`
- Weather state: `afe41450766855e1877c5538a8d4a7c66077e76297b28d047559acca643582ba`

One early backend inspection used the obsolete `hyprctl hyprsunset identity get` form under Hyprland 0.56; it briefly selected identity rather than reading it. Automatic scheduling was restored immediately through the public `resume` API. The saved `2250 K` preference, location, and indicators never changed, and final status returned to scheduled `evening-transition`. This is recorded explicitly rather than claimed as a no-display-write proof.

## Automated verification

Final complete run from the installed tree:

- Solar: 16/16
- Schedule: 26/26
- Location: 68/68
- Timeline model: 19/19
- Moon model: 10/10
- Controller: 42/42
- Manifest: PASS
- Source contract: PASS
- QML entry points: PASS (`dashboard=440`, `location=375`, `manual=223`)
- QML service: PASS
- QML service conflict/CAS: PASS
- QML timeline service: PASS
- QML timeline UI: PASS
- QML moon icon: PASS
- QML live Warmth: PASS
- Omarchy plugin validation: PASS
- `git diff --check`: PASS

The complete output is `.work/final-coherence/all-suites-final.log`. Shell logs contain expected local-plugin reloads and unrelated isolated-harness XKB warnings; no Night Light timeline/moon QML warning, plugin error, or new coredump was observed.

## Remaining finalization

1. Commit this coherence edit in the installed Git checkout.
2. Run `omarchy plugin update jgordijn.night-light --yes`.
3. Restart the shell, verify installed HEAD/status/processes/status/hashes, and capture the corrected installed override copy with a fake-only harness (real display remains scheduled).
