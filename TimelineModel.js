// Pure local-civil-day timeline validation and geometry for QML and Node.
//
// Timezone projection belongs to the controller.  This model consumes only
// projected wall-clock fields and therefore never consults the host clock,
// calendar, locale, filesystem, network, or process environment.

var DAY_MS = 86400000
var MAX_EPOCH_MS = 8640000000000000
var MAX_SAFE_INTEGER = 9007199254740991
var DISPLAY_TIME_KEYS = ["sunset", "sunrise", "nextBoundary", "overrideUntil"]
var STATUSES = {
  "normal": true,
  "polar-day": true,
  "polar-night": true,
  "unavailable": true
}
var ZONE_SOURCES = { "location": true, "system": true }
var EVENT_KINDS = { "sunrise": true, "sunset": true }

function isArray(value) {
  try {
    return Array.isArray(value)
  } catch (error) {
    return false
  }
}

function objectValue(value) {
  return value !== null && typeof value === "object" && !isArray(value)
}

// Public inputs never invoke caller accessors or inherit schema fields.
function ownDataDescriptor(object, name) {
  if (!objectValue(object) && !isArray(object)) return null
  try {
    var descriptor = Object.getOwnPropertyDescriptor(object, name)
    if (!descriptor || !Object.prototype.hasOwnProperty.call(descriptor, "value"))
      return null
    return descriptor
  } catch (error) {
    return null
  }
}

function ownValue(object, name) {
  var descriptor = ownDataDescriptor(object, name)
  return descriptor ? descriptor.value : undefined
}

function ownsData(object, names) {
  if (!objectValue(object)) return false
  for (var i = 0; i < names.length; i++) {
    if (!ownDataDescriptor(object, names[i])) return false
  }
  return true
}

function finiteNumber(value) {
  return typeof value === "number" && isFinite(value)
}

function nonNegativeInteger(value) {
  return finiteNumber(value) && Math.floor(value) === value &&
    value >= 0 && value <= MAX_SAFE_INTEGER
}

function validEpoch(value) {
  return finiteNumber(value) && value >= -MAX_EPOCH_MS && value <= MAX_EPOCH_MS
}

function validWallMs(value, allowEnd) {
  return finiteNumber(value) && value >= 0 &&
    (allowEnd ? value <= DAY_MS : value < DAY_MS)
}

function validOffset(value) {
  return finiteNumber(value) && Math.floor(value) === value &&
    value >= -1440 && value <= 1440
}

function validFold(value) {
  return value === 0 || value === 1
}

function enumValue(values, value) {
  return typeof value === "string" &&
    Object.prototype.hasOwnProperty.call(values, value) && values[value] === true
}

function leapYear(year) {
  return year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0)
}

function validDateKey(value) {
  if (typeof value !== "string") return false
  var match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value)
  if (!match) return false
  var year = Number(match[1])
  var month = Number(match[2])
  var day = Number(match[3])
  if (year < 1 || month < 1 || month > 12 || day < 1) return false
  var monthLengths = [31, leapYear(year) ? 29 : 28, 31, 30, 31, 30,
    31, 31, 30, 31, 30, 31]
  return day <= monthLengths[month - 1]
}

function projectedTime(value) {
  var fields = ["epochMs", "dateKey", "wallMs", "offsetMinutes", "fold", "ambiguous"]
  if (!ownsData(value, fields)) return null

  var epochMs = ownValue(value, "epochMs")
  var dateKey = ownValue(value, "dateKey")
  var wallMs = ownValue(value, "wallMs")
  var offsetMinutes = ownValue(value, "offsetMinutes")
  var fold = ownValue(value, "fold")
  var ambiguous = ownValue(value, "ambiguous")
  if (!validEpoch(epochMs) || !validDateKey(dateKey) || !validWallMs(wallMs, false) ||
      !validOffset(offsetMinutes) || !validFold(fold) || typeof ambiguous !== "boolean")
    return null

  return {
    epochMs: epochMs,
    dateKey: dateKey,
    wallMs: wallMs,
    offsetMinutes: offsetMinutes,
    fold: fold,
    ambiguous: ambiguous
  }
}

function canonicalEvent(value, snapshotDateKey) {
  if (!ownsData(value, ["kind", "epochMs", "dateKey", "wallMs",
    "offsetMinutes", "fold", "ambiguous"])) return null
  var kind = ownValue(value, "kind")
  if (!enumValue(EVENT_KINDS, kind)) return null
  var projected = projectedTime(value)
  if (!projected || projected.dateKey !== snapshotDateKey) return null

  return {
    key: kind + ":" + String(projected.epochMs) + ":" +
      String(projected.offsetMinutes) + ":" + String(projected.fold),
    kind: kind,
    epochMs: projected.epochMs,
    dateKey: projected.dateKey,
    wallMs: projected.wallMs,
    offsetMinutes: projected.offsetMinutes,
    fold: projected.fold,
    ambiguous: projected.ambiguous
  }
}

function canonicalEvents(value, dateKey, stateAtMidnight) {
  if (!isArray(value)) return null
  var lengthDescriptor = ownDataDescriptor(value, "length")
  var length = lengthDescriptor ? lengthDescriptor.value : -1
  if (!finiteNumber(length) || Math.floor(length) !== length || length < 0 || length > 2)
    return null

  var events = []
  var state = stateAtMidnight
  var previousEpoch = null
  for (var i = 0; i < length; i++) {
    var itemDescriptor = ownDataDescriptor(value, String(i))
    var item = itemDescriptor ? itemDescriptor.value : null
    var event = canonicalEvent(item, dateKey)
    if (!event || (previousEpoch !== null && event.epochMs <= previousEpoch)) return null
    if ((event.kind === "sunrise" && state !== "night") ||
        (event.kind === "sunset" && state !== "day")) return null
    state = event.kind === "sunrise" ? "day" : "night"
    previousEpoch = event.epochMs
    if (!appendOwnData(events, event)) return null
  }
  return { events: events, finalState: state }
}

function defineOwnData(object, name, value) {
  // Ordinary assignment can invoke an inherited setter or be suppressed by
  // an inherited non-writable property.  Define each canonical schema field
  // directly so hostile Object.prototype entries cannot intercept output.
  try {
    Object.defineProperty(object, name, {
      value: value,
      writable: true,
      enumerable: true,
      configurable: true
    })
    return true
  } catch (error) {
    return false
  }
}

function appendOwnData(array, value) {
  // Array push performs an ordinary indexed write.  Defining the next own
  // index directly prevents Object.prototype numeric setters/non-writable
  // properties from executing or suppressing canonical output elements.
  return defineOwnData(array, String(array.length), value)
}

function canonicalDisplayTimes(value) {
  if (!objectValue(value)) return null
  // Missing allowed names must remain genuinely absent.  A null prototype
  // prevents an ordinary read of an omitted field from reaching a hostile
  // Object.prototype getter while Object.keys still reports only supplied
  // canonical fields.
  var result = Object.create(null)
  for (var i = 0; i < DISPLAY_TIME_KEYS.length; i++) {
    var name = DISPLAY_TIME_KEYS[i]
    var descriptor
    try {
      descriptor = Object.getOwnPropertyDescriptor(value, name)
    } catch (error) {
      return null
    }
    if (!descriptor) continue
    // Absence is allowed, but a supplied known accessor is malformed.  Never
    // invoke it or silently canonicalize it as an omitted projected time.
    if (!Object.prototype.hasOwnProperty.call(descriptor, "value")) return null
    var item = descriptor.value
    if (item === null) {
      if (!defineOwnData(result, name, null)) return null
      continue
    }
    var projected = projectedTime(item)
    if (!projected || !defineOwnData(result, name, projected)) return null
  }
  return result
}

function addProjectedInterval(segments, startWallMs, endWallMs) {
  if (startWallMs < endWallMs) {
    return appendOwnData(segments,
      { startWallMs: startWallMs, endWallMs: endWallMs })
  }
  if (startWallMs > endWallMs) {
    return appendOwnData(segments,
      { startWallMs: startWallMs, endWallMs: DAY_MS }) &&
      appendOwnData(segments,
        { startWallMs: 0, endWallMs: endWallMs })
  }
  return true
}

function mergedSegments(events, stateAtMidnight) {
  var segments = []
  var state = stateAtMidnight
  var daylightStart = state === "day" ? 0 : null
  for (var i = 0; i < events.length; i++) {
    var event = events[i]
    if (event.kind === "sunrise") {
      daylightStart = event.wallMs
      state = "day"
    } else {
      if (!addProjectedInterval(segments, daylightStart, event.wallMs)) return null
      daylightStart = null
      state = "night"
    }
  }
  if (state === "day" &&
      !addProjectedInterval(segments, daylightStart, DAY_MS)) return null

  segments.sort(function(left, right) {
    if (left.startWallMs !== right.startWallMs)
      return left.startWallMs - right.startWallMs
    return left.endWallMs - right.endWallMs
  })

  var merged = []
  for (var j = 0; j < segments.length; j++) {
    var segment = segments[j]
    if (segment.startWallMs === segment.endWallMs) continue
    var previous = merged.length ? merged[merged.length - 1] : null
    if (previous && segment.startWallMs <= previous.endWallMs) {
      if (segment.endWallMs > previous.endWallMs)
        previous.endWallMs = segment.endWallMs
    } else {
      if (!appendOwnData(merged, {
        startWallMs: segment.startWallMs,
        endWallMs: segment.endWallMs
      })) return null
    }
  }
  return merged
}

function frozen(value) {
  if (value && typeof value === "object" && typeof Object.freeze === "function") {
    var keys = Object.keys(value)
    for (var i = 0; i < keys.length; i++) frozen(value[keys[i]])
    Object.freeze(value)
  }
  return value
}

function failure() {
  return frozen({ ok: false, error: "invalid-timeline" })
}

function positionForWallMs(wallMs) {
  return validWallMs(wallMs, true) ? wallMs / DAY_MS : null
}

function buildSnapshot(input) {
  try {
    var fields = ["revision", "dateKey", "zoneId", "zoneSource", "nowMs",
      "markerWallMs", "markerOffsetMinutes", "markerFold", "markerAmbiguous",
      "status", "stateAtMidnight", "events", "displayTimes"]
    if (!ownsData(input, fields)) return failure()

    var revision = ownValue(input, "revision")
    var dateKey = ownValue(input, "dateKey")
    var zoneId = ownValue(input, "zoneId")
    var zoneSource = ownValue(input, "zoneSource")
    var nowMs = ownValue(input, "nowMs")
    var markerWallMs = ownValue(input, "markerWallMs")
    var markerOffsetMinutes = ownValue(input, "markerOffsetMinutes")
    var markerFold = ownValue(input, "markerFold")
    var markerAmbiguous = ownValue(input, "markerAmbiguous")
    var status = ownValue(input, "status")
    var stateAtMidnight = ownValue(input, "stateAtMidnight")
    var rawEvents = ownValue(input, "events")
    var rawDisplayTimes = ownValue(input, "displayTimes")

    if (!nonNegativeInteger(revision) || !validDateKey(dateKey) ||
        typeof zoneId !== "string" || zoneId.length === 0 || zoneId.length > 80 ||
        !enumValue(ZONE_SOURCES, zoneSource) || !validEpoch(nowMs) ||
        !validWallMs(markerWallMs, false) || !validOffset(markerOffsetMinutes) ||
        !validFold(markerFold) || typeof markerAmbiguous !== "boolean" ||
        !enumValue(STATUSES, status)) return failure()

    var available = status !== "unavailable"
    if (available && stateAtMidnight !== "day" && stateAtMidnight !== "night")
      return failure()
    if (!available && stateAtMidnight !== null &&
        stateAtMidnight !== "day" && stateAtMidnight !== "night") return failure()
    if (status === "polar-day" && stateAtMidnight !== "day") return failure()
    if (status === "polar-night" && stateAtMidnight !== "night") return failure()

    // Unavailable snapshots carry no state-changing claims.  Use a temporary
    // night state only to validate the necessarily empty event collection.
    var eventState = available ? stateAtMidnight : "night"
    var canonical = canonicalEvents(rawEvents, dateKey, eventState)
    if (!canonical || (!available && canonical.events.length !== 0)) return failure()
    var displayTimes = canonicalDisplayTimes(rawDisplayTimes)
    if (!displayTimes) return failure()

    var isDayNow = false
    var daylightSegments = []
    if (available) {
      var runningState = stateAtMidnight
      for (var i = 0; i < canonical.events.length; i++) {
        if (canonical.events[i].epochMs <= nowMs)
          runningState = canonical.events[i].kind === "sunrise" ? "day" : "night"
      }
      isDayNow = runningState === "day"
      daylightSegments = mergedSegments(canonical.events, stateAtMidnight)
      if (!daylightSegments) return failure()
    }

    var snapshot = {
      revision: revision,
      dateKey: dateKey,
      zoneId: zoneId,
      zoneSource: zoneSource,
      nowMs: nowMs,
      markerWallMs: markerWallMs,
      markerOffsetMinutes: markerOffsetMinutes,
      markerFold: markerFold,
      markerAmbiguous: markerAmbiguous,
      status: status,
      stateAtMidnight: stateAtMidnight,
      isDayNow: isDayNow,
      events: canonical.events,
      daylightSegments: daylightSegments,
      displayTimes: displayTimes
    }
    return frozen({ ok: true, snapshot: snapshot })
  } catch (error) {
    return failure()
  }
}

function shouldAnimateMarker(previous, next) {
  var previousResult = buildSnapshot(previous)
  if (!previousResult.ok) return false
  var nextResult = buildSnapshot(next)
  if (!nextResult.ok) return false

  var left = previousResult.snapshot
  var right = nextResult.snapshot
  if (left.revision !== right.revision || left.dateKey !== right.dateKey ||
      left.zoneId !== right.zoneId ||
      left.markerOffsetMinutes !== right.markerOffsetMinutes) return false

  var epochDelta = right.nowMs - left.nowMs
  var wallDelta = right.markerWallMs - left.markerWallMs
  return epochDelta >= 0 && epochDelta <= 120000 &&
    wallDelta >= 0 && wallDelta <= 120000
}

if (typeof module !== "undefined" && module && module.exports) {
  module.exports = {
    buildSnapshot: buildSnapshot,
    positionForWallMs: positionForWallMs,
    shouldAnimateMarker: shouldAnimateMarker
  }
}
