// Pure schedule and temperature math for Night Light.  The QML service owns
// clocks and state; every result here is derived from the supplied epoch.

var DAY_TEMPERATURE = 6500
var DEFAULT_NIGHT_TEMPERATURE = 4000
var DEFAULT_TRANSITION_MINUTES = 45
var MIN_NIGHT_TEMPERATURE = 1000
var MAX_TRANSITION_MINUTES = 180
var STEADY_INTERVAL_MS = 30000
var TRANSITION_INTERVAL_MS = 5000
var DAY_MS = 86400000
var MAX_EPOCH_MS = 8640000000000000
var MAX_EVENT_SEARCH_CYCLES = 370
// Match SolarModel's closed input interval without expanding the frozen API
// merely to export implementation limits.  Solar events may extend beyond
// this interval (while remaining valid Date epochs), but every scheduled wake
// must remain a valid input to both models.
var MAX_EVALUATION_EPOCH_MS = MAX_EPOCH_MS - (MAX_EVENT_SEARCH_CYCLES + 2) * DAY_MS
var MIN_EVALUATION_EPOCH_MS = -MAX_EVALUATION_EPOCH_MS

// Node tests can resolve the sibling directly.  Under QML, callers may pass
// the result of SolarModel.surroundingEvents as `location`; a SolarModel
// namespace exposed by a host is also accepted.  Keeping the lookup guarded
// leaves this file valid as both CommonJS and a QML JavaScript resource.
var nodeSolarModel = null
if (typeof require === "function") {
  try {
    nodeSolarModel = require("./SolarModel.js")
  } catch (error) {
    nodeSolarModel = null
  }
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

function finiteNumber(value) {
  return typeof value === "number" && isFinite(value)
}

function validEpoch(value) {
  return finiteNumber(value) && Math.abs(value) < MAX_EPOCH_MS
}

function validEvaluationEpoch(value) {
  return finiteNumber(value) && value >= MIN_EVALUATION_EPOCH_MS &&
    value <= MAX_EVALUATION_EPOCH_MS
}

function boundedNextEvaluation(epochMs, candidateMs) {
  var next = candidateMs
  if (!finiteNumber(next) || next <= epochMs) next = epochMs + 1
  return Math.min(next, MAX_EVALUATION_EPOCH_MS)
}

function retryEvaluation(epochMs) {
  if (!validEvaluationEpoch(epochMs) || epochMs >= MAX_EVALUATION_EPOCH_MS) return 0
  return boundedNextEvaluation(epochMs, epochMs + STEADY_INTERVAL_MS)
}

function validateSettings(raw) {
  if (raw === undefined) raw = {}
  if (!isPlainObject(raw)) return settingsError("settings must be an object")

  var automationEnabled = raw.automationEnabled === undefined ? true : raw.automationEnabled
  var nightTemperature = raw.nightTemperature === undefined ? DEFAULT_NIGHT_TEMPERATURE : raw.nightTemperature
  var transitionMinutes = raw.transitionMinutes === undefined ? DEFAULT_TRANSITION_MINUTES : raw.transitionMinutes

  if (typeof automationEnabled !== "boolean")
    return settingsError("automationEnabled must be a boolean")
  if (!finiteNumber(nightTemperature) || Math.floor(nightTemperature) !== nightTemperature ||
      nightTemperature < MIN_NIGHT_TEMPERATURE || nightTemperature > DAY_TEMPERATURE)
    return settingsError("nightTemperature must be an integer from 1000 to 6500")
  if (!finiteNumber(transitionMinutes) || Math.floor(transitionMinutes) !== transitionMinutes ||
      transitionMinutes < 0 || transitionMinutes > MAX_TRANSITION_MINUTES)
    return settingsError("transitionMinutes must be an integer from 0 to 180")

  var value = {
    automationEnabled: automationEnabled,
    nightTemperature: nightTemperature,
    transitionMinutes: transitionMinutes
  }
  return { ok: true, value: value, settings: value }
}

function settingsError(message) {
  return { ok: false, error: { code: "settings-invalid", message: message } }
}

function normalizedSettings(settings) {
  // Accept validateSettings(raw) as a convenience without weakening strict
  // validation of the actual transaction.
  if (isPlainObject(settings) && settings.ok === true) {
    if (isPlainObject(settings.value)) settings = settings.value
    else if (isPlainObject(settings.settings)) settings = settings.settings
  }
  return validateSettings(settings)
}

function propertyNumber(object, names) {
  if (!isPlainObject(object)) return null
  for (var i = 0; i < names.length; i++) {
    var value = object[names[i]]
    if (validEpoch(value)) return value
  }
  return null
}

function eventStatus(events) {
  if (!isPlainObject(events)) return ""
  var value = events.status
  if (value === undefined) value = events.phase
  if (value === undefined) value = events.kind
  value = String(value === undefined || value === null ? "" : value).toLowerCase()
  if (value === "polar_day") value = "polar-day"
  if (value === "polar_night") value = "polar-night"
  return value
}

function looksLikeEvents(value) {
  if (!isPlainObject(value)) return false
  var status = eventStatus(value)
  if (status === "normal" || status === "polar-day" || status === "polar-night" || status === "error")
    return true
  return propertyNumber(value, ["sunsetMs", "precedingSunsetMs", "previousSunsetMs"]) !== null &&
    propertyNumber(value, ["sunriseMs", "followingSunriseMs", "nextSunriseMs"]) !== null
}

function solarNamespace() {
  if (nodeSolarModel) return nodeSolarModel
  if (typeof SolarModel !== "undefined") return SolarModel
  return null
}

function coordinatesFrom(location) {
  if (!isPlainObject(location)) return null
  var latitude = location.latitude
  var longitude = location.longitude
  if (!finiteNumber(latitude) || !finiteNumber(longitude)) return null
  if (latitude < -90 || latitude > 90 || longitude < -180 || longitude > 180) return null
  return { latitude: latitude, longitude: longitude }
}

function resolveEvents(epochMs, location) {
  if (looksLikeEvents(location)) return location
  if (isPlainObject(location) && looksLikeEvents(location.events)) return location.events
  if (isPlainObject(location) && looksLikeEvents(location.solarEvents)) return location.solarEvents

  var coordinates = coordinatesFrom(location)
  if (!coordinates) return null
  var solar = solarNamespace()
  if (!solar || typeof solar.surroundingEvents !== "function") return null

  if (typeof solar.validateCoordinates === "function") {
    var validation = solar.validateCoordinates(coordinates.latitude, coordinates.longitude)
    if (validation === false || (isPlainObject(validation) && validation.ok === false)) return null
  }

  try {
    return solar.surroundingEvents(epochMs, coordinates.latitude, coordinates.longitude)
  } catch (error) {
    return null
  }
}

function collectNumbers(object, names, output) {
  for (var i = 0; i < names.length; i++) {
    var value = propertyNumber(object, [names[i]])
    if (value !== null && output.indexOf(value) === -1) output.push(value)
  }
}

function collectNestedCycles(events, sunsets, sunrises) {
  var collections = [events.cycles, events.events]
  for (var c = 0; c < collections.length; c++) {
    if (!Array.isArray(collections[c])) continue
    for (var i = 0; i < collections[c].length; i++) {
      var item = collections[c][i]
      if (!isPlainObject(item)) continue
      collectNumbers(item, ["sunsetMs", "sunset", "setMs"], sunsets)
      collectNumbers(item, ["sunriseMs", "sunrise", "riseMs"], sunrises)
    }
  }
}

function normalNight(events, epochMs) {
  var directSunset = propertyNumber(events,
    ["sunsetMs", "precedingSunsetMs", "previousSunsetMs", "sunset", "setMs"])
  var directSunrise = propertyNumber(events,
    ["sunriseMs", "followingSunriseMs", "nextSunriseMs", "sunrise", "riseMs"])
  if (directSunset !== null && directSunrise !== null && directSunset < directSunrise)
    return { sunsetMs: directSunset, sunriseMs: directSunrise }

  var sunsets = []
  var sunrises = []
  collectNumbers(events, ["sunsetMs", "precedingSunsetMs", "previousSunsetMs", "nextSunsetMs", "sunset", "setMs"], sunsets)
  collectNumbers(events, ["sunriseMs", "followingSunriseMs", "previousSunriseMs", "nextSunriseMs", "sunrise", "riseMs"], sunrises)
  collectNestedCycles(events, sunsets, sunrises)
  sunsets.sort(function(a, b) { return a - b })
  sunrises.sort(function(a, b) { return a - b })

  // Prefer the night containing now.  In daytime, use the next sunset and
  // the first sunrise after it.
  for (var i = sunsets.length - 1; i >= 0; i--) {
    if (sunsets[i] > epochMs) continue
    for (var j = 0; j < sunrises.length; j++)
      if (sunrises[j] > epochMs && sunrises[j] > sunsets[i])
        return { sunsetMs: sunsets[i], sunriseMs: sunrises[j] }
  }
  for (var s = 0; s < sunsets.length; s++) {
    if (sunsets[s] <= epochMs) continue
    for (var r = 0; r < sunrises.length; r++)
      if (sunrises[r] > sunsets[s]) return { sunsetMs: sunsets[s], sunriseMs: sunrises[r] }
  }
  return null
}

function clamp(value, minimum, maximum) {
  return Math.max(minimum, Math.min(maximum, value))
}

function smoothstep(progress) {
  var p = clamp(progress, 0, 1)
  return p * p * (3 - 2 * p)
}

function stateAt(epochMs, sunsetMs, sunriseMs, durationMs) {
  if (epochMs < sunsetMs || epochMs >= sunriseMs)
    return { phase: "day", warmth: 0, transitionEndMs: 0 }
  if (durationMs === 0)
    return { phase: "night", warmth: 1, transitionEndMs: 0 }

  var edgeDuration = Math.min(durationMs, (sunriseMs - sunsetMs) / 2)
  var eveningEnd = sunsetMs + edgeDuration
  var morningStart = sunriseMs - edgeDuration
  if (epochMs < eveningEnd) {
    return {
      phase: "evening-transition",
      warmth: smoothstep((epochMs - sunsetMs) / edgeDuration),
      transitionEndMs: eveningEnd
    }
  }
  if (epochMs <= morningStart)
    return { phase: "night", warmth: 1, transitionEndMs: 0 }
  return {
    phase: "morning-transition",
    warmth: smoothstep((sunriseMs - epochMs) / edgeDuration),
    transitionEndMs: sunriseMs
  }
}

function targetFor(warmth, nightTemperature, quantized) {
  if (warmth === 0) return { kind: "identity", temperature: DAY_TEMPERATURE }
  var temperature = DAY_TEMPERATURE + warmth * (nightTemperature - DAY_TEMPERATURE)
  temperature = quantized ? Math.round(temperature / 10) * 10 : Math.round(temperature)
  temperature = clamp(temperature, nightTemperature, DAY_TEMPERATURE)
  return { kind: "temperature", temperature: temperature }
}

function sameTarget(left, right) {
  return left.kind === right.kind && left.temperature === right.temperature
}

function firstChangedTargetMs(epochMs, endMs, sunsetMs, sunriseMs, durationMs, nightTemperature, currentTarget) {
  var low = Math.floor(epochMs) + 1
  var high = Math.ceil(endMs)
  if (low > high) return 0
  var highState = stateAt(high, sunsetMs, sunriseMs, durationMs)
  var highTarget = targetFor(highState.warmth, nightTemperature,
    highState.phase === "evening-transition" || highState.phase === "morning-transition")
  if (sameTarget(currentTarget, highTarget)) return 0

  while (low < high) {
    // Do not average the absolute epochs: low + high can exceed the exact
    // integer range even though both endpoints are valid Date milliseconds.
    // Taking half of the non-negative span is overflow-safe.  The defensive
    // fallback to low also makes either branch shrink this integer interval,
    // so floating-point rounding can never livelock the shell thread.
    var middle = low + Math.floor((high - low) / 2)
    if (!(middle >= low && middle < high)) middle = low
    var sample = stateAt(middle, sunsetMs, sunriseMs, durationMs)
    var sampleTarget = targetFor(sample.warmth, nightTemperature,
      sample.phase === "evening-transition" || sample.phase === "morning-transition")
    if (sameTarget(currentTarget, sampleTarget)) low = middle + 1
    else high = middle
  }
  return low
}

function nextEvaluation(epochMs, state, sunsetMs, sunriseMs, durationMs, nightTemperature, nextBoundaryMs) {
  var transitioning = state.phase === "evening-transition" || state.phase === "morning-transition"
  var next = epochMs + (transitioning ? TRANSITION_INTERVAL_MS : STEADY_INTERVAL_MS)
  if (nextBoundaryMs > epochMs) next = Math.min(next, nextBoundaryMs)
  if (transitioning) {
    if (state.transitionEndMs > epochMs) next = Math.min(next, state.transitionEndMs)
    var currentTarget = targetFor(state.warmth, nightTemperature, true)
    var changed = firstChangedTargetMs(epochMs, state.transitionEndMs, sunsetMs, sunriseMs,
      durationMs, nightTemperature, currentTarget)
    if (changed > epochMs) next = Math.min(next, changed)
  }
  return boundedNextEvaluation(epochMs, next)
}

function errorResult(epochMs, code, message) {
  return {
    ok: false,
    phase: "error",
    warmth: 0,
    target: null,
    sunsetMs: 0,
    sunriseMs: 0,
    nextBoundaryMs: 0,
    nextEvaluationMs: retryEvaluation(epochMs),
    error: { code: code, message: message }
  }
}

function polarResult(epochMs, status, events, settings) {
  var isDay = status === "polar-day"
  var sunsetMs = propertyNumber(events,
    [isDay ? "nextSunsetMs" : "precedingSunsetMs", "sunsetMs", "previousSunsetMs"])
  var sunriseMs = propertyNumber(events,
    [isDay ? "previousSunriseMs" : "nextSunriseMs", "sunriseMs", "followingSunriseMs"])
  var nextEvent = isPlainObject(events.nextEvent) ? events.nextEvent : null
  var previousEvent = isPlainObject(events.previousEvent) ? events.previousEvent : null
  if (nextEvent && validEpoch(nextEvent.epochMs)) {
    if (nextEvent.kind === "sunset" && sunsetMs === null) sunsetMs = nextEvent.epochMs
    if (nextEvent.kind === "sunrise" && sunriseMs === null) sunriseMs = nextEvent.epochMs
  }
  if (previousEvent && validEpoch(previousEvent.epochMs)) {
    if (previousEvent.kind === "sunset" && sunsetMs === null) sunsetMs = previousEvent.epochMs
    if (previousEvent.kind === "sunrise" && sunriseMs === null) sunriseMs = previousEvent.epochMs
  }

  var nextBoundaryMs = isDay ? sunsetMs : sunriseMs
  if (!(nextBoundaryMs > epochMs) && nextEvent && validEpoch(nextEvent.epochMs))
    nextBoundaryMs = nextEvent.epochMs
  if (!(nextBoundaryMs > epochMs)) nextBoundaryMs = 0

  // Polar night has no synthetic cycle endpoints, but SolarModel retains the
  // last real sunset and first real sunrise as adjacent events.  Compose the
  // ordinary edge formula with those events so positive-duration warming is
  // continuous at both seasonal seams; keep the long interior polar-night.
  var durationMs = settings.transitionMinutes * 60000
  if (!isDay && durationMs > 0 && sunsetMs !== null && sunriseMs !== null &&
      sunsetMs <= epochMs && epochMs < sunriseMs) {
    var transitionState = stateAt(epochMs, sunsetMs, sunriseMs, durationMs)
    if (transitionState.phase === "evening-transition" ||
        transitionState.phase === "morning-transition") {
      return {
        ok: true,
        phase: transitionState.phase,
        warmth: transitionState.warmth,
        target: targetFor(transitionState.warmth, settings.nightTemperature, true),
        sunsetMs: sunsetMs,
        sunriseMs: sunriseMs,
        nextBoundaryMs: nextBoundaryMs,
        nextEvaluationMs: nextEvaluation(epochMs, transitionState, sunsetMs, sunriseMs,
          durationMs, settings.nightTemperature, nextBoundaryMs)
      }
    }
  }

  if (sunsetMs === null) sunsetMs = 0
  if (sunriseMs === null) sunriseMs = 0
  var warmth = isDay ? 0 : 1
  var nextEvaluationMs = epochMs + STEADY_INTERVAL_MS
  if (nextBoundaryMs > epochMs) nextEvaluationMs = Math.min(nextEvaluationMs, nextBoundaryMs)
  nextEvaluationMs = boundedNextEvaluation(epochMs, nextEvaluationMs)
  return {
    ok: true,
    phase: status,
    warmth: warmth,
    target: targetFor(warmth, settings.nightTemperature, false),
    sunsetMs: sunsetMs,
    sunriseMs: sunriseMs,
    nextBoundaryMs: nextBoundaryMs,
    nextEvaluationMs: nextEvaluationMs
  }
}

function evaluate(epochMs, location, settings) {
  if (!validEvaluationEpoch(epochMs))
    return errorResult(epochMs, "calculation-failed", "invalid epoch")
  // At the closed upper SolarModel endpoint no strictly-future valid wake can
  // be represented.  Fail before resolving events or emitting a target rather
  // than promise a timer that is guaranteed to fail on its next callback.
  if (epochMs >= MAX_EVALUATION_EPOCH_MS)
    return errorResult(epochMs, "calculation-failed", "epoch cannot be scheduled")
  var validation = normalizedSettings(settings)
  if (!validation.ok)
    return errorResult(epochMs, "settings-invalid", validation.error.message)
  var normalized = validation.value
  var events = resolveEvents(epochMs, location)
  if (!isPlainObject(events) || events.ok === false)
    return errorResult(epochMs, "calculation-failed", "solar events are unavailable")

  var status = eventStatus(events)
  if (status === "polar-day" || status === "polar-night")
    return polarResult(epochMs, status, events, normalized)
  if (status !== "" && status !== "normal")
    return errorResult(epochMs, "calculation-failed", "invalid solar event status")

  var night = normalNight(events, epochMs)
  if (!night || !validEpoch(night.sunsetMs) || !validEpoch(night.sunriseMs) || night.sunriseMs <= night.sunsetMs)
    return errorResult(epochMs, "calculation-failed", "invalid solar event chronology")

  var durationMs = normalized.transitionMinutes * 60000
  var state = stateAt(epochMs, night.sunsetMs, night.sunriseMs, durationMs)
  var transitioning = state.phase === "evening-transition" || state.phase === "morning-transition"
  var target = targetFor(state.warmth, normalized.nightTemperature, transitioning)
  var nextBoundaryMs = epochMs < night.sunsetMs ? night.sunsetMs :
    (epochMs < night.sunriseMs ? night.sunriseMs : 0)
  var nextEvaluationMs = nextEvaluation(epochMs, state, night.sunsetMs, night.sunriseMs,
    durationMs, normalized.nightTemperature, nextBoundaryMs)

  return {
    ok: true,
    phase: state.phase,
    warmth: state.warmth,
    target: target,
    sunsetMs: night.sunsetMs,
    sunriseMs: night.sunriseMs,
    nextBoundaryMs: nextBoundaryMs,
    nextEvaluationMs: nextEvaluationMs
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    validateSettings: validateSettings,
    evaluate: evaluate
  }
}
