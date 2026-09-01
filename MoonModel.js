// Pure, timezone-independent lunar phase astronomy for QML and Node.
//
// This is the frozen low-order Meeus/SunCalc geocentric approximation from
// WAVE3-SPEC.md and .work/reports/w3-lunar-research.md.  Inputs and outputs
// are epoch-derived only: location affects the icon orientation separately,
// never the astronomical phase.

var DAY_MS = 86400000
var J1970 = 2440588
var J2000 = 2451545
var RAD = Math.PI / 180
var TWO_PI = Math.PI * 2
var SYNODIC_MONTH_DAYS = 29.530588853
var SUN_DISTANCE_KM = 149598000
var MAX_EPOCH_MS = 8640000000000000

function finiteNumber(value) {
  return typeof value === "number" && isFinite(value)
}

function validEpoch(epochMs) {
  return finiteNumber(epochMs) && epochMs >= -MAX_EPOCH_MS && epochMs <= MAX_EPOCH_MS
}

function modulo(value, divisor) {
  return ((value % divisor) + divisor) % divisor
}

function clamp(value, minimum, maximum) {
  return Math.max(minimum, Math.min(maximum, value))
}

function phaseIdentity(phase) {
  if (phase < 1 / 16 || phase >= 15 / 16)
    return { phaseId: "new-moon", phaseName: "New Moon" }
  if (phase < 3 / 16)
    return { phaseId: "waxing-crescent", phaseName: "Waxing Crescent" }
  if (phase < 5 / 16)
    return { phaseId: "first-quarter", phaseName: "First Quarter" }
  if (phase < 7 / 16)
    return { phaseId: "waxing-gibbous", phaseName: "Waxing Gibbous" }
  if (phase < 9 / 16)
    return { phaseId: "full-moon", phaseName: "Full Moon" }
  if (phase < 11 / 16)
    return { phaseId: "waning-gibbous", phaseName: "Waning Gibbous" }
  if (phase < 13 / 16)
    return { phaseId: "last-quarter", phaseName: "Last Quarter" }
  return { phaseId: "waning-crescent", phaseName: "Waning Crescent" }
}

function phaseDetails(phase, illumination) {
  var identity = phaseIdentity(phase)
  return {
    ok: true,
    phase: phase,
    ageDays: phase * SYNODIC_MONTH_DAYS,
    illumination: illumination,
    trend: phase < 0.5 ? "waxing" : "waning",
    phaseId: identity.phaseId,
    phaseName: identity.phaseName
  }
}

function phaseAt(epochMs) {
  if (!validEpoch(epochMs)) return { ok: false, error: "invalid-epoch" }

  // Julian days from J2000.  The -0.5 converts the Unix epoch's Julian-day
  // noon convention without consulting host calendar fields or timezone.
  var days = epochMs / DAY_MS - 0.5 + J1970 - J2000

  // Corrected geocentric solar ecliptic longitude.
  var solarAnomaly = RAD * (357.5291 + 0.98560028 * days)
  var equationOfCenter = RAD * (
    1.9148 * Math.sin(solarAnomaly) +
    0.0200 * Math.sin(2 * solarAnomaly) +
    0.0003 * Math.sin(3 * solarAnomaly)
  )
  var solarLongitude = solarAnomaly + equationOfCenter + RAD * 102.9372 + Math.PI

  // Corrected geocentric lunar longitude, latitude, and Earth distance.
  var lunarMeanLongitude = RAD * (218.316 + 13.176396 * days)
  var lunarMeanAnomaly = RAD * (134.963 + 13.064993 * days)
  var lunarArgumentOfLatitude = RAD * (93.272 + 13.229350 * days)
  var lunarLongitude = lunarMeanLongitude + RAD * 6.289 * Math.sin(lunarMeanAnomaly)
  var lunarLatitude = RAD * 5.128 * Math.sin(lunarArgumentOfLatitude)
  var lunarDistanceKm = 385001 - 20905 * Math.cos(lunarMeanAnomaly)

  // Positive elongation gives a stable waxing-to-waning cycle independent of
  // observer and timezone.  Reusing the normalized elongation for incidence
  // also avoids carrying large multi-century angles into the spherical term.
  var phase = modulo(lunarLongitude - solarLongitude, TWO_PI) / TWO_PI
  var elongation = phase * TWO_PI
  var angularDistance = Math.acos(clamp(
    Math.cos(lunarLatitude) * Math.cos(elongation), -1, 1))
  var incidence = Math.atan2(
    SUN_DISTANCE_KM * Math.sin(angularDistance),
    lunarDistanceKm - SUN_DISTANCE_KM * Math.cos(angularDistance)
  )
  var illumination = clamp((1 + Math.cos(incidence)) / 2, 0, 1)

  return phaseDetails(phase, illumination)
}

function orientationForLatitude(latitude) {
  if (latitude === null || typeof latitude === "undefined") {
    return { ok: true, orientation: "northern", source: "default" }
  }
  if (!finiteNumber(latitude) || latitude < -90 || latitude > 90)
    return { ok: false, error: "invalid-latitude" }
  return {
    ok: true,
    orientation: latitude < 0 ? "southern" : "northern",
    source: "location"
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    orientationForLatitude: orientationForLatitude,
    phaseAt: phaseAt
  }
}
