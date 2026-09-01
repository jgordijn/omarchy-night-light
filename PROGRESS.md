# Night Light — live progress

_Last updated: 2026-09-01 13:14 CEST_

## Status

**Wave 2: independent component builds** — in progress; v1 architecture frozen in [SPEC.md](SPEC.md)

| Piece | Builder | Independent critic | Status |
|---|---:|---:|---|
| World Clock quality bar & native plugin contract | research | fresh-context integrator | Integrated into v1 package, panel, and blind-quality contracts |
| Solar schedule & transition math | research | fresh-context integrator | Frozen as pure epoch-based model with polar/DST gates |
| Automatic/private location handling | research | fresh-context integrator | Frozen as local-first, consented, atomic private state |
| hyprsunset control & lifecycle | research | fresh-context integrator | Frozen as one scoped writer with external-override semantics |
| Panel interaction & visual language | research | fresh-context integrator | Frozen as native fixed-geometry mouse/keyboard contract |
| Validation, accessibility & failure states | research | fresh-context integrator | Frozen as objective unit, live, visual, and blind gates |

## Wave 2 build fan-out

| Piece | Status |
|---|---|
| Package contract | Built; final validation waits on QML entry points |
| Solar astronomy | 4 builder/critic loops; hardened seasonal and epoch edges |
| Transition schedule | 4 builder/critic loops; continuous polar transitions |
| Location policy | 4 builder/critic loops; hardened privacy and stale guards |
| Backend controller | 4 builder/critic loops; hardened live lifecycle and reloads |
| QML service | Building against stable contracts |
| Bar widget and panel | Building against real Clock/Weather components |

## Quality gate

No piece ships until a fresh-context critic examines the installed files, live shell logs, commands, and rendered output—not a builder summary—and identifies no material gap against `omarchy.clock`.
