# Night Light — live progress

_Last updated: 2026-09-01 16:56 CEST_

## Status

**Wave 3 specification frozen; production implementation has not started.**

The Git-managed source checkout and installed clone were independently inspected alongside the installed `/usr/share/omarchy/shell/plugins/panels/clock`. The live service reported a scheduled daytime target with an available backend, no error, and Weather as the active source. Runtime inspection showed one session daemon, one QML attachment, one shared `hyprsunset`, private `0600` state/socket files in `0700` directories, and no plugin-attributable QML warning or coredump.

## Final fix

Actual keyboard exercise exposed a contract conflict: stock `PanelKeyCatcher` consumes `l` as Right before Night Light can use its documented Location shortcut. This also caused an unnecessary inline settings write. Normal mode now uses a direct, conflict-free focus owner: `l` opens Location and Left/Right alone adjust values. The accidental no-op settings key from each live reproduction was removed again; saved location, stock-indicator metadata, and display target were retained.

The QML harness now invokes the real normal-key handler and asserts that `l` is consumed by the Location editor. Source-contract coverage prevents reintroducing `PanelKeyCatcher` or `l` as normal-mode Right. README and SPEC keyboard copy now agree with runtime behavior. SPEC was also reconciled with the fitted editor geometry, bounded apply retry sequence, and actual tracked test inventory.

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

After `omarchy plugin update jgordijn.night-light --yes`, the shell was restarted so the keyboard proof used a newly instantiated installed panel rather than the already-running pre-update QML object. The installed `l` shortcut then opened Location (`.work/screens/final-installed-restarted/screenshot-2026-09-01_15-41-02.png`); Escape returned to the dashboard. Shell settings and private state hashes were identical before and after that proof, and Kelvin/identity remained `6500 K`/`true`.

## Wave 3 fan-out

`WAVE3-SPEC.md` integrates all four Wave 3 research reports, the three World Clock references, fresh installed Night Light/Clock output, installed shell primitives, current production code, controller protocol, and test harnesses. Contradictions are resolved into one normative build order while `SPEC.md` remains authoritative for every guarantee not explicitly superseded.

| Piece | Status |
|---|---|
| Timeline/product/lunar/preview research | Complete |
| Wave 3 integration contract | **Frozen — `WAVE3-SPEC.md`** |
| `TimelineModel.js` | Ready to build; not started |
| `MoonModel.js` | Ready to build; not started |
| Civil timezone projection and atomic Service timeline | Ready to build; not started |
| Moon primitive and timeline QML components | Ready to build; not started |
| Panel timeline/focus integration | Ready to build; not started |
| Persisted-first Warmth and external-change CAS | Ready to build; not started |
| Installed-output and five-reviewer blind loop | Blocked on implementation |

No production or test file was changed during specification work.

## Previous independent blind gate

A separate fresh-context critic inspected and used the real Git-managed installed plugin—not a builder summary—and randomized Night Light/Clock ordering across normal, editor, focus, and handoff captures. It explicitly judged **Night Light better overall**, scoring **4.89 vs Clock’s 4.77**, and returned **UTTERLY WOWED/PASS**. Evidence and detailed scoring are in `.work/reports/final-independent-critic.md` and `.work/screens/final-independent-critic/`.

Every independently reviewed piece now has a WOW/PASS result: pure models, controller lifecycle, QML service/state races, native UI, packaging/update path, and final installed integration. The broader SPEC five-human-reviewer study remains a future release exercise rather than a claim made here.

The live exercise did not forget location or change Kelvin (`6500 K` before and after). It did not alter the existing hidden-stock restoration transaction or disable `omarchy.nightlight`.
