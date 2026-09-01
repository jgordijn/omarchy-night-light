# Night Light — live progress

_Last updated: 2026-09-01 15:31 CEST_

## Status

**Final fresh-context coherence pass complete; one proven keyboard conflict fixed.**

The Git-managed source checkout and installed clone were independently inspected alongside the installed `/usr/share/omarchy/shell/plugins/panels/clock`. The live service reported a scheduled daytime target with an available backend, no error, and Weather as the active source. Runtime inspection showed one session daemon, one QML attachment, one shared `hyprsunset`, private `0600` state/socket files in `0700` directories, and no plugin-attributable QML warning or coredump.

## Final fix

Actual keyboard exercise exposed a contract conflict: stock `PanelKeyCatcher` consumes `l` as Right before Night Light can use its documented Location shortcut. This also caused an unnecessary inline settings write. Normal mode now owns a conflict-free key map: `l` opens Location and Left/Right alone adjust values. The accidental no-op settings key from the live reproduction was removed again; saved location, stock-indicator metadata, and display target were retained.

The QML harness now invokes the real normal-key handler and asserts that `l` is consumed by the Location editor. Source-contract coverage prevents reintroducing `l` as normal-mode Right. README and SPEC keyboard copy now agree with runtime behavior. SPEC was also reconciled with the fitted editor geometry, bounded apply retry sequence, and actual tracked test inventory.

## Verification

All repository suites pass on the final working tree:

- Solar: 16/16
- Schedule: 26/26
- Location: 68/68
- Controller: 27/27
- Manifest/Omarchy validation: PASS
- Source contract: PASS
- QML entry points: PASS (`dashboard=440`, `location=375`, `manual=223`)
- QML service: PASS
- QML service conflict/CAS: PASS

Live screenshots exercised the installed dashboard, Clock, Escape close, and Tab handoff to the adjacent Tailscale panel. A real pointer hover over the Night Light bar item showed native hand-cursor affordance. Same-scale Clock and Night Light captures were also placed in a randomized A/B composite at `.work/screens/final/blind-ab.png`.

## Gate accounting

The rendered normal panel is coherent with Clock in the inspected theme and scale, and the randomized A/B comparison exposed no clipping or obvious native-style mismatch. This is **not** a claim that SPEC’s five-reviewer blind gate passed: no five independent reviewers scored the required state matrix. Error, override, alternate theme/scale, and all bar-edge live screenshot variants were not re-created in this final pass; their deterministic QML states remain covered by the harness.

The live exercise did not forget location or change Kelvin (`6500 K` before and after). It did not alter the existing hidden-stock restoration transaction or disable `omarchy.nightlight`.
