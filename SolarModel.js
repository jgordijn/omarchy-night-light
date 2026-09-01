// Pure, timezone-independent solar astronomy for QML and Node.
//
// This is the compact NOAA/SunCalc approximation described in SPEC.md.  All
// public times are Unix epoch milliseconds; no local calendar or Date API is
// used.  The conventional -0.833 degree horizon includes the usual nominal
// allowance for refraction and the apparent radius of the sun.

var DAY_MS = 86400000
var J1970 = 2440587.5
var J2000 = 2451545.0
var J0 = 0.0009
var HORIZON_RADIANS = -0.833 * Math.PI / 180
var OBLIQUITY_RADIANS = 23.4397 * Math.PI / 180
var TWO_PI = Math.PI * 2
var HOUR_ANGLE_EPSILON = 1e-12
var POLE_DENOMINATOR_EPSILON = 1e-12
var MAX_EPOCH_MS = 8640000000000000
var MAX_EVENT_SEARCH_CYCLES = 370
// Keep the complete bounded event search inside the ECMAScript Date range so
// every returned epoch remains displayable by QML, even near that range.  The
// public input interval is deliberately closed; ScheduleModel may clamp its
// final wake to either endpoint without turning that wake into an invalid
// SolarModel input.
var MAX_INPUT_EPOCH_MS = MAX_EPOCH_MS - (MAX_EVENT_SEARCH_CYCLES + 2) * DAY_MS
var MIN_INPUT_EPOCH_MS = -MAX_INPUT_EPOCH_MS
var DECIMAL_PATTERN = /^[+-]?(?:\d+(?:\.\d*)?|\.\d+)$/

function finiteNumber(value) {
  if (typeof value === "number") return isFinite(value) ? value : null
  if (typeof value !== "string") return null

  var text = value.replace(/^\s+|\s+$/g, "")
  if (!DECIMAL_PATTERN.test(text)) return null
  var number = Number(text)
  return isFinite(number) ? number : null
}

function validateCoordinates(latitude, longitude) {
  var lat = finiteNumber(latitude)
  var lon = finiteNumber(longitude)
  if (lat === null || lon === null || lat < -90 || lat > 90 || lon < -180 || lon > 180)
    return { ok: false, error: "invalid-coordinates" }

  return { ok: true, latitude: lat, longitude: lon }
}

function validEpoch(epochMs) {
  return typeof epochMs === "number" && isFinite(epochMs) &&
    epochMs >= MIN_INPUT_EPOCH_MS && epochMs <= MAX_INPUT_EPOCH_MS
}

function mod360(value) {
  return ((value % 360) + 360) % 360
}

function clamp(value, minimum, maximum) {
  return Math.max(minimum, Math.min(maximum, value))
}

function cycleIndexAt(epochMs, longitude) {
  var julianDate = epochMs / DAY_MS + J1970
  return Math.round(julianDate - J2000 - J0 + longitude / 360)
}

function eventMilliseconds(julianDate) {
  return (julianDate - J1970) * DAY_MS
}

// Internal result includes cycleIndex so surroundingEvents can search without
// exposing an implementation detail in the frozen public result.
function cycleForIndex(cycleIndex, latitude, longitude) {
  var julianCycle = J0 - longitude / 360 + cycleIndex
  var anomalyDegrees = mod360(357.5291 + 0.98560028 * julianCycle)
  var anomaly = anomalyDegrees * Math.PI / 180
  var equationOfCenter = 1.9148 * Math.sin(anomaly) +
    0.0200 * Math.sin(2 * anomaly) +
    0.0003 * Math.sin(3 * anomaly)
  var eclipticDegrees = mod360(anomalyDegrees + equationOfCenter + 180 + 102.9372)
  var ecliptic = eclipticDegrees * Math.PI / 180
  var declination = Math.asin(Math.sin(ecliptic) * Math.sin(OBLIQUITY_RADIANS))
  var transitJulian = J2000 + julianCycle +
    0.0053 * Math.sin(anomaly) -
    0.0069 * Math.sin(2 * ecliptic)
  var transitMs = eventMilliseconds(transitJulian)

  if (!isFinite(declination) || !isFinite(transitMs)) return null

  var latitudeRadians = latitude * Math.PI / 180
  var altitudeCenter = Math.sin(latitudeRadians) * Math.sin(declination)
  var altitudeAmplitude = Math.abs(Math.cos(latitudeRadians) * Math.cos(declination))
  var horizon = Math.sin(HORIZON_RADIANS)
  var status

  // Comparing daily extrema first both gives the right polar classification
  // and prevents an unstable division at exact or near-exact poles.
  if (altitudeAmplitude <= POLE_DENOMINATOR_EPSILON) {
    if (altitudeCenter + altitudeAmplitude <= horizon) status = "polar-night"
    else if (altitudeCenter - altitudeAmplitude >= horizon) status = "polar-day"
    else status = altitudeCenter >= horizon ? "polar-day" : "polar-night"
  } else {
    var hourAngleRatio = (horizon - altitudeCenter) / altitudeAmplitude
    if (!isFinite(hourAngleRatio)) return null
    if (hourAngleRatio >= 1 - HOUR_ANGLE_EPSILON) status = "polar-night"
    else if (hourAngleRatio <= -1 + HOUR_ANGLE_EPSILON) status = "polar-day"
    else {
      var hourAngle = Math.acos(clamp(hourAngleRatio, -1, 1))
      var sunriseMs = eventMilliseconds(transitJulian - hourAngle / TWO_PI)
      var sunsetMs = eventMilliseconds(transitJulian + hourAngle / TWO_PI)
      if (!isFinite(sunriseMs) || !isFinite(sunsetMs) ||
          !(sunriseMs < transitMs && transitMs < sunsetMs) ||
          !(sunsetMs - sunriseMs < DAY_MS)) return null
      return {
        status: "normal",
        cycleIndex: cycleIndex,
        sunriseMs: sunriseMs,
        transitMs: transitMs,
        sunsetMs: sunsetMs
      }
    }
  }

  return {
    status: status,
    cycleIndex: cycleIndex,
    sunriseMs: null,
    transitMs: transitMs,
    sunsetMs: null
  }
}

function publicCycle(cycle) {
  return {
    ok: true,
    status: cycle.status,
    sunriseMs: cycle.sunriseMs,
    transitMs: cycle.transitMs,
    sunsetMs: cycle.sunsetMs
  }
}

function cycleAt(epochMs, latitude, longitude) {
  if (!validEpoch(epochMs)) return { ok: false, status: "error", error: "invalid-epoch" }
  var coordinates = validateCoordinates(latitude, longitude)
  if (!coordinates.ok) return { ok: false, status: "error", error: coordinates.error }

  var cycleIndex = cycleIndexAt(epochMs, coordinates.longitude)
  var cycle = cycleForIndex(cycleIndex, coordinates.latitude, coordinates.longitude)
  if (!cycle) return { ok: false, status: "error", error: "calculation-failed" }
  return publicCycle(cycle)
}

function event(kind, epochMs) {
  return { kind: kind, epochMs: epochMs }
}

// The daily approximation changes declination once per solar cycle.  At a
// polar-day seam that can leave one calculated sunset without a following
// sunrise, or one sunrise without a preceding sunset.  Neither is a state
// change: daylight continues through the midnight-sun season.  Omit those two
// seam-side events so the remaining chronology always alternates.
function eventsForIndex(cycleIndex, latitude, longitude) {
  var cycle = cycleForIndex(cycleIndex, latitude, longitude)
  if (!cycle || cycle.status !== "normal") return []

  var previousCycle = cycleForIndex(cycleIndex - 1, latitude, longitude)
  var nextCycle = cycleForIndex(cycleIndex + 1, latitude, longitude)
  var events = []
  if (!previousCycle || previousCycle.status !== "polar-day")
    events.push(event("sunrise", cycle.sunriseMs))
  if (!nextCycle || nextCycle.status !== "polar-day")
    events.push(event("sunset", cycle.sunsetMs))
  return events
}

function eventsAround(epochMs, baseCycleIndex, latitude, longitude) {
  var previous = null
  var next = null

  // Search symmetrically outwards.  Ordinary locations finish on the first
  // iteration; polar seasons expand only as far as the nearest real events.
  for (var distance = 0; distance <= MAX_EVENT_SEARCH_CYCLES; distance++) {
    var offsets = distance === 0 ? [0] : [-distance, distance]
    for (var offsetIndex = 0; offsetIndex < offsets.length; offsetIndex++) {
      var candidates = eventsForIndex(
        baseCycleIndex + offsets[offsetIndex], latitude, longitude)
      for (var i = 0; i < candidates.length; i++) {
        var candidate = candidates[i]
        if (candidate.epochMs <= epochMs && (!previous || candidate.epochMs > previous.epochMs))
          previous = candidate
        if (candidate.epochMs > epochMs && (!next || candidate.epochMs < next.epochMs))
          next = candidate
      }
    }
    if (previous && next) break
  }

  return { previous: previous, next: next }
}

function findEventAfter(epochMs, baseCycleIndex, latitude, longitude) {
  var next = null
  for (var offset = 0; offset <= MAX_EVENT_SEARCH_CYCLES; offset++) {
    var candidates = eventsForIndex(baseCycleIndex + offset, latitude, longitude)
    for (var i = 0; i < candidates.length; i++) {
      if (candidates[i].epochMs > epochMs &&
          (!next || candidates[i].epochMs < next.epochMs)) next = candidates[i]
    }
    if (next) return next
  }
  return null
}

function stateFromEvents(nearby, fallbackStatus) {
  if (nearby.previous && nearby.next) {
    if (nearby.previous.kind === "sunrise" && nearby.next.kind === "sunset") return true
    if (nearby.previous.kind === "sunset" && nearby.next.kind === "sunrise") return false
    return null
  }
  if (nearby.previous) return nearby.previous.kind === "sunrise"
  if (nearby.next) return nearby.next.kind === "sunset"
  if (fallbackStatus === "polar-day") return true
  if (fallbackStatus === "polar-night") return false
  return null
}

// Very near a pole the once-per-cycle declination approximation can skip one
// seasonal normal cycle.  The calculated events on either side may then have
// the same kind: a real sunrise (or sunset) exists, but its opposite seasonal
// event does not.  Infer the state only for that orphan case, using calculated
// cycle extrema and the same polar-day seam rules as eventsForIndex().
function stateFromCycle(epochMs, current, latitude, longitude) {
  if (current.status === "polar-day") return true
  if (current.status === "polar-night") return false
  if (current.status !== "normal") return null

  var previousCycle = cycleForIndex(current.cycleIndex - 1, latitude, longitude)
  var nextCycle = cycleForIndex(current.cycleIndex + 1, latitude, longitude)
  if (previousCycle && previousCycle.status === "polar-day" && epochMs < current.sunsetMs)
    return true
  if (nextCycle && nextCycle.status === "polar-day" && epochMs >= current.sunriseMs)
    return true
  return epochMs >= current.sunriseMs && epochMs < current.sunsetMs
}

// Keep only events compatible with the inferred state.  In particular, never
// expose sunrise/sunrise or sunset/sunset as adjacent events, and do not invent
// the missing opposite event.
function eventsForState(nearby, isDay) {
  var previousKind = isDay ? "sunrise" : "sunset"
  var nextKind = isDay ? "sunset" : "sunrise"
  return {
    previous: nearby.previous && nearby.previous.kind === previousKind ? nearby.previous : null,
    next: nearby.next && nearby.next.kind === nextKind ? nearby.next : null
  }
}

// Extend a polar classification to its actual state-changing events.  Event
// times can spill into a neighboring nominal cycle, so inspect the complete
// interval rather than trusting the cycle selected for the input epoch.
function surroundingStatus(current, nearby, isDay, latitude, longitude) {
  if (current.status !== "normal") return current.status

  var polarStatus = isDay ? "polar-day" : "polar-night"
  if (!nearby.previous || !nearby.next) {
    // An orphan event can put the input in the single nominal normal cycle
    // between two polar classifications.  Extend the adjacent matching polar
    // state to that real event rather than manufacturing the absent event.
    var previousCycle = cycleForIndex(current.cycleIndex - 1, latitude, longitude)
    var nextCycle = cycleForIndex(current.cycleIndex + 1, latitude, longitude)
    if ((previousCycle && previousCycle.status === polarStatus) ||
        (nextCycle && nextCycle.status === polarStatus)) return polarStatus
    return "normal"
  }

  var firstIndex = cycleIndexAt(nearby.previous.epochMs, longitude) - 1
  var lastIndex = cycleIndexAt(nearby.next.epochMs, longitude) + 1
  // Increment a small relative offset rather than an absolute epoch-derived
  // index.  The offset is bounded by the event search above, so it remains an
  // exact integer and the loop always progresses at both epoch extremes.
  var indexSpan = lastIndex - firstIndex
  for (var indexOffset = 0; indexOffset <= indexSpan; indexOffset++) {
    var cycle = cycleForIndex(firstIndex + indexOffset, latitude, longitude)
    if (cycle && cycle.status === polarStatus &&
        cycle.transitMs > nearby.previous.epochMs && cycle.transitMs < nearby.next.epochMs)
      return polarStatus
  }
  return "normal"
}

// For normal status, sunsetMs/sunriseMs are the ordered endpoints of the
// current night or (during daylight) the upcoming night.  For polar status
// they remain null: previousEvent/nextEvent are real normal-cycle state
// changes found within 370 cycles, never synthetic polar boundaries.
function surroundingEvents(epochMs, latitude, longitude) {
  if (!validEpoch(epochMs)) return { ok: false, status: "error", error: "invalid-epoch" }
  var coordinates = validateCoordinates(latitude, longitude)
  if (!coordinates.ok) return { ok: false, status: "error", error: coordinates.error }

  var baseCycleIndex = cycleIndexAt(epochMs, coordinates.longitude)
  var current = cycleForIndex(baseCycleIndex, coordinates.latitude, coordinates.longitude)
  if (!current) return { ok: false, status: "error", error: "calculation-failed" }

  var nearby = eventsAround(
    epochMs,
    baseCycleIndex,
    coordinates.latitude,
    coordinates.longitude
  )

  var isDay = stateFromEvents(nearby, current.status)
  var currentIsDay = current.status === "polar-day"
  var polarConflict = current.status !== "normal" &&
    isDay !== null && isDay !== currentIsDay
  if (isDay === null || polarConflict) {
    isDay = stateFromCycle(
      epochMs, current, coordinates.latitude, coordinates.longitude)
    if (isDay === null)
      return { ok: false, status: "error", error: "calculation-failed" }
    nearby = eventsForState(nearby, isDay)
  }

  var status = surroundingStatus(
    current,
    nearby,
    isDay,
    coordinates.latitude,
    coordinates.longitude
  )
  if ((status === "polar-day" && !isDay) || (status === "polar-night" && isDay))
    return { ok: false, status: "error", error: "calculation-failed" }

  if (status !== "normal") {
    return {
      ok: true,
      status: status,
      isDay: isDay,
      sunsetMs: null,
      sunriseMs: null,
      previousEvent: nearby.previous,
      nextEvent: nearby.next
    }
  }

  var sunset = isDay ? nearby.next : nearby.previous
  var sunrise = isDay
    ? (sunset && findEventAfter(
      sunset.epochMs, baseCycleIndex, coordinates.latitude, coordinates.longitude))
    : nearby.next

  if (!sunset || sunset.kind !== "sunset" || !sunrise || sunrise.kind !== "sunrise" ||
      !(sunset.epochMs < sunrise.epochMs))
    return { ok: false, status: "error", error: "calculation-failed" }

  return {
    ok: true,
    status: "normal",
    isDay: isDay,
    sunsetMs: sunset.epochMs,
    sunriseMs: sunrise.epochMs,
    previousEvent: nearby.previous,
    nextEvent: nearby.next
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    validateCoordinates: validateCoordinates,
    cycleAt: cycleAt,
    surroundingEvents: surroundingEvents
  }
}
