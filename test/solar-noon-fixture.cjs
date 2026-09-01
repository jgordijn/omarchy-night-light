#!/usr/bin/env node
"use strict"

// Test-only deterministic daytime fixture generator. For a supplied epoch it
// finds one longitude where every latitude used by the legacy QML Service race
// harnesses is safely daytime for a six-hour window centered on that epoch.
const path = require("node:path")
const root = path.resolve(__dirname, "..")
const Solar = require(path.join(root, "SolarModel.js"))
const Schedule = require(path.join(root, "ScheduleModel.js"))

const LATITUDES = [0, 10, 20, 30]
const MARGIN_MS = 3 * 60 * 60 * 1000
const SETTINGS = {
  automationEnabled: true,
  nightTemperature: 4000,
  transitionMinutes: 45,
}

function wrapLongitude(value) {
  return ((value + 180) % 360 + 360) % 360 - 180
}

function nominalNoonLongitude(epochMs) {
  const date = new Date(epochMs)
  const hours = date.getUTCHours() + date.getUTCMinutes() / 60 +
    date.getUTCSeconds() / 3600 + date.getUTCMilliseconds() / 3600000
  return wrapLongitude(15 * (12 - hours))
}

function isSafeDay(epochMs, longitude) {
  for (const latitude of LATITUDES) {
    for (const offset of [-MARGIN_MS, 0, MARGIN_MS]) {
      const at = epochMs + offset
      const events = Solar.surroundingEvents(at, latitude, longitude)
      const result = Schedule.evaluate(at, events, SETTINGS)
      if (!result.ok || result.phase !== "day" || !result.target ||
          result.target.kind !== "identity") return false
    }
  }
  return true
}

function longitudeFor(epochMs) {
  if (!Number.isFinite(epochMs)) throw new Error("fixture epoch must be finite")
  const nominal = nominalNoonLongitude(epochMs)
  // Equation-of-time displacement is small. Search symmetrically in quarter-
  // degree increments while retaining ample headroom for unusual test dates.
  for (let step = 0; step <= 80; step++) {
    const delta = step * 0.25
    const candidates = step === 0 ? [nominal] : [
      wrapLongitude(nominal - delta), wrapLongitude(nominal + delta),
    ]
    for (const longitude of candidates)
      if (isSafeDay(epochMs, longitude)) return longitude
  }
  throw new Error("could not construct a safe solar-noon fixture")
}

// Keep the generator itself honest across seasons and representative UTC wall
// times. These checks do not fake QML's clock; the final emitted longitude is
// always generated from the live epoch used by the harness.
for (const date of ["2026-01-15", "2026-03-20", "2026-06-21", "2026-09-22", "2026-12-21"])
  for (const hour of [0, 6, 12, 18]) {
    const epoch = Date.parse(`${date}T${String(hour).padStart(2, "0")}:00:00Z`)
    const longitude = longitudeFor(epoch)
    if (!isSafeDay(epoch, longitude)) throw new Error(`unsafe representative fixture ${date} ${hour}`)
  }

const rawEpoch = process.env.NIGHT_LIGHT_FIXTURE_EPOCH_MS
const epochMs = rawEpoch === undefined ? Date.now() : Number(rawEpoch)
const longitude = longitudeFor(epochMs)
process.stdout.write(JSON.stringify({epochMs, longitude}) + "\n")
