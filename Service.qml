import QtQuick
import Quickshell
import Quickshell.Io
import "SolarModel.js" as SolarModel
import "ScheduleModel.js" as ScheduleModel
import "LocationModel.js" as LocationModel
import "TimelineModel.js" as TimelineModel
import "MoonModel.js" as MoonModel

// The service loader creates exactly one of these.  Widgets are consumers only:
// all clocks, location I/O, controller traffic and IPC live here.
Item {
  id: root
  visible: false

  // Injected by omarchy-shell after createObject().  Startup is deliberately
  // deferred one event-loop turn so delayed injection is safe.
  property var shell: null
  property var manifest: null
  property var pluginRegistry: null
  property var barWidgetRegistry: null
  property string omarchyPath: ""

  readonly property string moduleName: "jgordijn.night-light"
  readonly property var settings: _settings
  readonly property var inlineSettings: _inlineEntry
  readonly property bool initialized: _initializationComplete
  readonly property bool busy: !_initializationComplete || _stateBusy || _networkBusy || _applyBusy
  readonly property bool available: _backendAvailable
  readonly property string mode: _override ? "override"
    : (!_activeScheduleLocation ? "setup" : (!_settings.automationEnabled ? "paused" : "scheduled"))
  readonly property string phase: _scheduleValid ? _schedule.phase
    : (_activeScheduleLocation ? "error" : "setup")
  readonly property real warmth: _scheduleValid ? _schedule.warmth : 0
  readonly property var actual: _actual
  readonly property var scheduleTarget: _scheduleValid ? _schedule.target : null
  readonly property var target: _override && _override.target ? _publicTarget(_override.target) : scheduleTarget
  readonly property var override: _override
  readonly property real overrideUntil: _override && isFinite(Number(_override.until)) ? Number(_override.until) : 0
  readonly property var error: _combinedError()
  readonly property var committedLocation: _committedLocation
  readonly property var activeScheduleLocation: _activeScheduleLocation
  readonly property var draftLocation: _draftLocation
  readonly property var privateLocationState: _privateState
  readonly property var location: _publicLocation()
  readonly property real sunset: _scheduleValid ? _schedule.sunsetMs : 0
  readonly property real sunrise: _scheduleValid ? _schedule.sunriseMs : 0
  readonly property real nextBoundary: _scheduleValid ? _schedule.nextBoundaryMs : 0
  readonly property real nextUpdate: _scheduleValid ? _schedule.nextEvaluationMs : 0
  readonly property var searchResults: _searchResults
  readonly property var automaticCandidate: _autoCandidate
  readonly property bool locationEditorOpen: _editorOpen
  readonly property var timeline: _timeline
  readonly property var moonPhase: _moonPhase

  property var _settings: ({ automationEnabled: true, nightTemperature: 4000, transitionMinutes: 45,
                              stockIndicator: { choice: "pending", before: null, after: null } })
  property var _inlineEntry: ({ id: "jgordijn.night-light" })
  property bool _settingsReady: false
  property var _settingsError: null
  property bool _weatherReady: false
  property var _weatherRead: ({ outcome: "absent", ok: false, location: null, error: null })
  property int _weatherRetries: 0
  property bool _weatherReloading: false
  property bool _controllerReady: false
  property bool _backendProbed: false
  property bool _backendAvailable: false
  property var _actual: ({ kind: "unavailable" })
  property var _override: null
  property var _backendError: null
  property var _stateError: null
  property var _calculationError: null
  property var _actionError: null
  property var _privateRead: null
  property var _privateState: null
  property bool _stateReady: false
  property bool _stateBusy: false
  property var _queuedStateWrite: null
  property var _pendingWeatherPersistence: null
  property bool _networkBusy: false
  property bool _applyBusy: false
  property bool _initializationComplete: false
  property bool _initializationInFlight: false
  property var _committedLocation: null
  property var _activeScheduleLocation: null
  property var _schedule: ({ ok: false, phase: "error", target: null, sunsetMs: 0,
                              sunriseMs: 0, nextBoundaryMs: 0, nextEvaluationMs: 0 })
  property bool _scheduleValid: false
  property int _requestSequence: 0
  property int _generationSequence: 0
  property var _pendingRequests: ({})
  property int _backendGeneration: -1
  property int _probeGeneration: -1
  property int _stateGeneration: -1
  property int _searchGeneration: -1
  property int _autoGeneration: -1
  property int _timelineGeneration: -1
  property var _timeline: null
  property var _moonPhase: null
  property int _timelineRevision: -1
  property string _timelineIdentity: ""
  readonly property int _timelineTimerInterval: timelineTimer.interval
  readonly property int _lunarTimerInterval: lunarTimer.interval
  property var _lastSent: null
  property bool _started: false
  property bool _shuttingDown: false
  property int _restartAttempts: 0
  property real _lastWallMs: 0
  property int _wakeProbeStep: 0
  property bool _editorOpen: false
  property bool _editorUserChanged: false
  property string _manualQuery: ""
  property int _searchEpoch: 0
  property int _locationEpoch: 0
  property var _draftLocation: null
  property var _searchResults: []
  property var _autoCandidate: null
  property var _networkError: null
  property bool _sessionAutoRefreshUsed: false
  // Prevent a synchronous shellConfigChanged echo from evaluating between the
  // inline write initiation and the one fresh persisted-warmth calculation.
  property bool _warmthCommitInFlight: false

  readonly property string _stateHome: {
    var configured = String(Quickshell.env("XDG_STATE_HOME") || "")
    return configured || String(Quickshell.env("HOME") || "") + "/.local/state"
  }
  readonly property string _weatherPath: _stateHome + "/omarchy/settings/weather.json"
  readonly property string _pluginDirectory: {
    if (manifest && manifest.__sourceDir) return String(manifest.__sourceDir).replace(/\/$/, "")
    var url = String(Qt.resolvedUrl("."))
    if (url.indexOf("file://") === 0) url = decodeURIComponent(url.slice(7))
    return url.replace(/\/$/, "")
  }

  function _clone(value) {
    return value === undefined ? undefined : JSON.parse(JSON.stringify(value))
  }

  function _plain(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value)
  }

  function _error(code, message) {
    return { code: String(code), message: String(message) }
  }

  function _combinedError() {
    return _settingsError || _stateError || _calculationError || _backendError || _actionError || _networkError || null
  }

  function _publicTarget(value) {
    if (!value || (value.kind !== "identity" && value.kind !== "temperature")) return null
    if (value.kind === "identity") return { kind: "identity", temperature: 6500 }
    return { kind: "temperature", temperature: Number(value.temperature) }
  }

  function _sameTarget(left, right) {
    if (!left || !right || left.kind !== right.kind) return false
    return left.kind === "identity" || Number(left.temperature) === Number(right.temperature)
  }

  function _finiteEpoch(value) {
    return typeof value === "number" && isFinite(value) &&
      value >= -8640000000000000 && value <= 8640000000000000
  }

  function _locationTimelineIdentity(locationValue) {
    if (!locationValue) return ""
    return JSON.stringify({
      label: String(locationValue.label || ""),
      admin1: String(locationValue.admin1 || ""),
      country: String(locationValue.country || ""),
      latitude: Number(locationValue.latitude),
      longitude: Number(locationValue.longitude),
      timezone: String(locationValue.timezone || ""),
      source: String(locationValue.source || ""),
      precision: String(locationValue.precision || "")
    })
  }

  function _timelineDisplayEpochs() {
    function epoch(value) { return root._finiteEpoch(value) ? value : null }
    return {
      sunset: _scheduleValid ? epoch(_schedule.sunsetMs) : null,
      sunrise: _scheduleValid ? epoch(_schedule.sunriseMs) : null,
      nextBoundary: _scheduleValid ? epoch(_schedule.nextBoundaryMs) : null,
      overrideUntil: _override ? epoch(Number(_override.until)) : null
    }
  }

  function _timelineRevisionFor(identity) {
    return identity === _timelineIdentity && _timelineRevision >= 0
      ? _timelineRevision : _timelineRevision + 1
  }

  function _commitTimelineResult(result, identity, revision) {
    if (!result || result.ok !== true || !result.snapshot) return false
    // TimelineModel returns a newly allocated, recursively frozen value.  One
    // assignment is the only publication point for the complete transaction.
    _timeline = result.snapshot
    _timelineIdentity = identity
    _timelineRevision = revision
    return true
  }

  function _unavailableTimelineInput(projection, context) {
    var candidate = null
    if (projection && _plain(projection)) {
      candidate = {
        revision: 0,
        dateKey: projection.dateKey,
        zoneId: projection.zoneId,
        zoneSource: projection.zoneSource,
        nowMs: context && _finiteEpoch(context.nowMs) ? context.nowMs : Date.now(),
        markerWallMs: projection.markerWallMs,
        markerOffsetMinutes: projection.markerOffsetMinutes,
        markerFold: projection.markerFold,
        markerAmbiguous: projection.markerAmbiguous,
        status: "unavailable",
        stateAtMidnight: null,
        events: [],
        displayTimes: { sunset: null, sunrise: null, nextBoundary: null, overrideUntil: null }
      }
      // Never feed a malformed civil shell back into the fallback publication.
      // Bounds are untrusted controller input just like the final projection.
      if (TimelineModel.buildSnapshot(candidate).ok === true) return candidate
    }
    if (!_timeline) return null
    // A prior complete snapshot is safe civil context for a neutral replacement:
    // its events, daylight, state, and all display labels are deliberately removed.
    return {
      revision: 0,
      dateKey: _timeline.dateKey,
      zoneId: _timeline.zoneId,
      zoneSource: _timeline.zoneSource,
      nowMs: _timeline.nowMs,
      markerWallMs: _timeline.markerWallMs,
      markerOffsetMinutes: _timeline.markerOffsetMinutes,
      markerFold: _timeline.markerFold,
      markerAmbiguous: _timeline.markerAmbiguous,
      status: "unavailable",
      stateAtMidnight: null,
      events: [],
      displayTimes: { sunset: null, sunrise: null, nextBoundary: null, overrideUntil: null }
    }
  }

  function _publishTimelineUnavailable(projection, context) {
    var input = _unavailableTimelineInput(projection, context || null)
    if (!input) return false
    var locationKey = context && context.locationKey !== undefined
      ? String(context.locationKey) : _locationTimelineIdentity(_activeScheduleLocation)
    var identity = JSON.stringify({
      dateKey: input.dateKey, zoneId: input.zoneId, zoneSource: input.zoneSource,
      location: locationKey, status: "unavailable", events: []
    })
    var revision = _timelineRevisionFor(identity)
    input.revision = revision
    return _commitTimelineResult(TimelineModel.buildSnapshot(input), identity, revision)
  }

  function _deterministicNeutralInput(projection, context) {
    // Terminal cold-start fallback: no event, daylight, display-time, or state
    // claim.  UTC/epoch-zero civil fields are deterministic sentinels only when
    // the controller supplied no independently valid authority for that group.
    var input = {
      revision: 0,
      dateKey: "1970-01-01",
      zoneId: "UTC",
      zoneSource: "system",
      nowMs: context && _finiteEpoch(context.nowMs) ? context.nowMs : 0,
      markerWallMs: 0,
      markerOffsetMinutes: 0,
      markerFold: 0,
      markerAmbiguous: false,
      status: "unavailable",
      stateAtMidnight: null,
      events: [],
      displayTimes: { sunset: null, sunrise: null, nextBoundary: null, overrideUntil: null }
    }
    if (!_plain(projection)) return input

    // Preserve the controller's zone authority as one indivisible pair.  If it
    // is malformed, marker/date fields tied to that unknown zone are not mixed
    // into the deterministic UTC sentinel.
    var zoneTrial = _clone(input)
    zoneTrial.zoneId = projection.zoneId
    zoneTrial.zoneSource = projection.zoneSource
    if (!TimelineModel.buildSnapshot(zoneTrial).ok) return input
    input.zoneId = projection.zoneId
    input.zoneSource = projection.zoneSource

    var dateTrial = _clone(input)
    dateTrial.dateKey = projection.dateKey
    if (TimelineModel.buildSnapshot(dateTrial).ok) input.dateKey = projection.dateKey

    // Offset/fold/ambiguity belong to the marker and are accepted only as one
    // complete projected tuple.  A malformed tuple becomes a neutral rail-start
    // marker rather than leaking a partially projected current-time claim.
    var markerTrial = _clone(input)
    markerTrial.markerWallMs = projection.markerWallMs
    markerTrial.markerOffsetMinutes = projection.markerOffsetMinutes
    markerTrial.markerFold = projection.markerFold
    markerTrial.markerAmbiguous = projection.markerAmbiguous
    if (TimelineModel.buildSnapshot(markerTrial).ok) {
      input.markerWallMs = projection.markerWallMs
      input.markerOffsetMinutes = projection.markerOffsetMinutes
      input.markerFold = projection.markerFold
      input.markerAmbiguous = projection.markerAmbiguous
    }
    return input
  }

  function _publishDeterministicTimelineUnavailable(projection, context) {
    var input = _deterministicNeutralInput(projection, context || null)
    var locationKey = context && context.locationKey !== undefined
      ? String(context.locationKey) : _locationTimelineIdentity(_activeScheduleLocation)
    var identity = JSON.stringify({
      dateKey: input.dateKey, zoneId: input.zoneId, zoneSource: input.zoneSource,
      location: locationKey, status: "unavailable", events: []
    })
    var revision = _timelineRevisionFor(identity)
    input.revision = revision
    return _commitTimelineResult(TimelineModel.buildSnapshot(input), identity, revision)
  }

  function _validProjectionBounds(projection, context) {
    if (!_plain(projection) || !_finiteEpoch(projection.dayStartMs) ||
        !_finiteEpoch(projection.dayEndMs) || projection.dayEndMs <= projection.dayStartMs)
      return false
    // Validate this response itself.  _unavailableTimelineInput() is allowed to
    // fall back to an older valid shell, which must not make malformed new
    // bounds look suitable for an astronomy walk.
    return TimelineModel.buildSnapshot({
      revision: 0,
      dateKey: projection.dateKey,
      zoneId: projection.zoneId,
      zoneSource: projection.zoneSource,
      nowMs: context && _finiteEpoch(context.nowMs) ? context.nowMs : Date.now(),
      markerWallMs: projection.markerWallMs,
      markerOffsetMinutes: projection.markerOffsetMinutes,
      markerFold: projection.markerFold,
      markerAmbiguous: projection.markerAmbiguous,
      status: "unavailable",
      stateAtMidnight: null,
      events: [],
      displayTimes: { sunset: null, sunrise: null, nextBoundary: null, overrideUntil: null }
    }).ok === true
  }

  function _requestTimeline() {
    if (!_controllerReady || !_activeScheduleLocation) return false
    var now = Date.now()
    if (!_finiteEpoch(now)) return false
    var locationValue = _clone(_activeScheduleLocation)
    var context = {
      stage: "bounds",
      nowMs: now,
      locationKey: _locationTimelineIdentity(locationValue),
      location: locationValue,
      displayTimes: _timelineDisplayEpochs()
    }
    return _send("projectCivilDay", {
      nowMs: now,
      zoneId: String(locationValue.timezone || ""),
      events: [],
      displayTimes: {}
    }, "timeline", context) !== ""
  }

  function _requestNeutralTimelineProjection(context, failedProjection) {
    if (!_controllerReady || !context || !context.location ||
        context.locationKey !== _locationTimelineIdentity(_activeScheduleLocation)) return false
    // One clean eventless retry gives cold startup a civil shell without making
    // QML a timezone authority.  It is intentionally bounded and generation-
    // revokes the malformed bounds transaction.
    return _send("projectCivilDay", {
      nowMs: context.nowMs,
      zoneId: String(context.location.timezone || ""),
      events: [],
      displayTimes: {}
    }, "timeline", {
      stage: "neutral",
      nowMs: context.nowMs,
      locationKey: context.locationKey,
      location: context.location,
      displayTimes: context.displayTimes,
      failedProjection: _plain(failedProjection) ? _clone(failedProjection) : null
    }) !== ""
  }

  function _walkTimelineEvents(projection, context) {
    var locationValue = context.location
    var latitude = Number(locationValue.latitude)
    var longitude = Number(locationValue.longitude)
    var atMidnight
    try {
      atMidnight = SolarModel.surroundingEvents(
        projection.dayStartMs, latitude, longitude)
    } catch (exception) {
      return null
    }
    if (!atMidnight || atMidnight.ok !== true || typeof atMidnight.isDay !== "boolean")
      return null

    var events = []
    var next = atMidnight.nextEvent
    var previousEpoch = projection.dayStartMs
    while (next && next.epochMs < projection.dayEndMs && events.length < 2) {
      if ((next.kind !== "sunrise" && next.kind !== "sunset") ||
          !_finiteEpoch(next.epochMs) || next.epochMs <= previousEpoch) return null
      events.push({ kind: next.kind, epochMs: next.epochMs })
      previousEpoch = next.epochMs
      var surrounding
      try {
        surrounding = SolarModel.surroundingEvents(next.epochMs + 1, latitude, longitude)
      } catch (exception) {
        return null
      }
      if (!surrounding || surrounding.ok !== true) return null
      next = surrounding.nextEvent
    }
    if (next && next.epochMs < projection.dayEndMs) return null

    return {
      stateAtMidnight: atMidnight.isDay ? "day" : "night",
      status: events.length === 0 &&
        (atMidnight.status === "polar-day" || atMidnight.status === "polar-night")
        ? atMidnight.status : "normal",
      events: events
    }
  }

  function _sameProjectionTransaction(left, right) {
    return left && right && left.dateKey === right.dateKey &&
      left.zoneId === right.zoneId && left.zoneSource === right.zoneSource &&
      Number(left.dayStartMs) === Number(right.dayStartMs) &&
      Number(left.dayEndMs) === Number(right.dayEndMs)
  }

  function _handleCivilDay(message, pending) {
    if (!pending || pending.operation !== "projectCivilDay" || !pending.context) return
    var context = pending.context
    if (context.locationKey !== _locationTimelineIdentity(_activeScheduleLocation)) return
    var projection = message.projection
    if (!_plain(projection)) {
      var malformedFallback = context.stage === "final" ? context.boundsProjection
        : (context.stage === "neutral" ? context.failedProjection : null)
      if (!_publishTimelineUnavailable(malformedFallback, context)) {
        if (context.stage === "bounds") {
          if (!_requestNeutralTimelineProjection(context, null))
            _publishDeterministicTimelineUnavailable(projection, context)
        } else if (context.stage === "neutral") {
          _publishDeterministicTimelineUnavailable(malformedFallback, context)
        }
      }
      return
    }

    if (context.stage === "neutral") {
      if (!_publishTimelineUnavailable(projection, context))
        _publishDeterministicTimelineUnavailable(projection, context)
      return
    }
    if (context.stage === "bounds") {
      if (!_validProjectionBounds(projection, context)) {
        if (!_publishTimelineUnavailable(projection, context) &&
            !_requestNeutralTimelineProjection(context, projection))
          _publishDeterministicTimelineUnavailable(projection, context)
        return
      }
      var walk = _walkTimelineEvents(projection, context)
      if (!walk) {
        _publishTimelineUnavailable(projection, context)
        return
      }
      _send("projectCivilDay", {
        nowMs: context.nowMs,
        zoneId: String(context.location.timezone || ""),
        events: walk.events,
        displayTimes: context.displayTimes
      }, "timeline", {
        stage: "final",
        nowMs: context.nowMs,
        locationKey: context.locationKey,
        location: context.location,
        displayTimes: context.displayTimes,
        boundsProjection: _clone(projection),
        stateAtMidnight: walk.stateAtMidnight,
        status: walk.status,
        rawEvents: walk.events
      })
      return
    }
    if (context.stage !== "final") return
    if (!_sameProjectionTransaction(context.boundsProjection, projection)) {
      // The system zone/date changed between the bounds and final projection.
      // Revoke this transaction and begin again rather than mixing its fields.
      _requestTimeline()
      return
    }
    var projectedEvents = Array.isArray(projection.events) ? projection.events : []
    if (projectedEvents.length !== context.rawEvents.length) {
      _publishTimelineUnavailable(context.boundsProjection, context)
      return
    }
    for (var i = 0; i < projectedEvents.length; ++i) {
      if (projectedEvents[i].kind !== context.rawEvents[i].kind ||
          Number(projectedEvents[i].epochMs) !== Number(context.rawEvents[i].epochMs)) {
        _publishTimelineUnavailable(context.boundsProjection, context)
        return
      }
    }
    var eventIdentity = []
    for (var j = 0; j < context.rawEvents.length; ++j)
      eventIdentity.push(context.rawEvents[j].kind + ":" + String(context.rawEvents[j].epochMs))
    var identity = JSON.stringify({
      dateKey: projection.dateKey, zoneId: projection.zoneId,
      zoneSource: projection.zoneSource, location: context.locationKey,
      status: context.status, events: eventIdentity
    })
    var revision = _timelineRevisionFor(identity)
    var built = TimelineModel.buildSnapshot({
      revision: revision,
      dateKey: projection.dateKey,
      zoneId: projection.zoneId,
      zoneSource: projection.zoneSource,
      nowMs: context.nowMs,
      markerWallMs: projection.markerWallMs,
      markerOffsetMinutes: projection.markerOffsetMinutes,
      markerFold: projection.markerFold,
      markerAmbiguous: projection.markerAmbiguous,
      status: context.status,
      stateAtMidnight: context.stateAtMidnight,
      events: projectedEvents,
      displayTimes: projection.displayTimes
    })
    if (!_commitTimelineResult(built, identity, revision))
      _publishTimelineUnavailable(context.boundsProjection, context)
  }

  function _refreshMoon(attemptedTime) {
    var calculatedAt = Number(attemptedTime)
    if (!_finiteEpoch(calculatedAt)) calculatedAt = Date.now()
    var phaseResult = MoonModel.phaseAt(calculatedAt)
    if (!phaseResult.ok) {
      _moonPhase = { ok: false, error: "invalid-epoch", calculatedAtMs: calculatedAt }
      return false
    }
    var latitude = _activeScheduleLocation ? Number(_activeScheduleLocation.latitude) : null
    var orientation = MoonModel.orientationForLatitude(latitude)
    if (!orientation.ok) {
      _moonPhase = { ok: false, error: "invalid-latitude", calculatedAtMs: calculatedAt }
      return false
    }
    _moonPhase = {
      ok: true,
      calculatedAtMs: calculatedAt,
      phase: phaseResult.phase,
      ageDays: phaseResult.ageDays,
      illumination: phaseResult.illumination,
      trend: phaseResult.trend,
      phaseId: phaseResult.phaseId,
      phaseName: phaseResult.phaseName,
      orientation: orientation.orientation,
      orientationSource: orientation.source
    }
    return true
  }

  function _armTimelineTimer() {
    var now = Date.now()
    var remainder = ((now % 60000) + 60000) % 60000
    timelineTimer.interval = Math.max(1, remainder === 0 ? 60000 : 60000 - remainder)
    timelineTimer.restart()
  }

  function _armLunarTimer() {
    var now = Date.now()
    var period = 15 * 60 * 1000
    var remainder = ((now % period) + period) % period
    lunarTimer.interval = Math.max(1, remainder === 0 ? period : period - remainder)
    lunarTimer.restart()
  }

  function _publicLocation() {
    var item = _activeScheduleLocation
    if (!item) return null
    var fresh = LocationModel.freshness(item, Date.now(), {
      lastKnown: _privateState && _privateState.mode === "weather" &&
        (!_weatherRead || _weatherRead.outcome !== "valid")
    })
    return {
      mode: _privateState ? _privateState.mode : "none",
      source: item.source,
      label: item.label,
      precision: item.precision,
      stale: fresh.ok ? fresh.stale : false,
      sourceLabel: fresh.ok ? fresh.sourceLabel : "",
      observedAt: item.observedAt
    }
  }

  function _settingsEntry(config) {
    if (!_plain(config)) return null
    var sections = ["left", "center", "right"]
    var layout = config.bar && _plain(config.bar.layout) ? config.bar.layout : null
    if (layout) {
      for (var s = 0; s < sections.length; ++s) {
        var entries = layout[sections[s]]
        if (!Array.isArray(entries)) continue
        for (var i = 0; i < entries.length; ++i)
          if (_plain(entries[i]) && String(entries[i].id || "") === moduleName) return entries[i]
      }
    }
    if (Array.isArray(config.plugins)) {
      for (var p = 0; p < config.plugins.length; ++p)
        if (_plain(config.plugins[p]) && String(config.plugins[p].id || "") === moduleName) return config.plugins[p]
    }
    return null
  }

  function _validateFullSettings(raw) {
    raw = raw === null || raw === undefined ? {} : raw
    if (!_plain(raw)) return { ok: false, error: _error("settings-invalid", "Night Light settings must be an object.") }
    var schedule = ScheduleModel.validateSettings(raw)
    if (!schedule.ok) return schedule
    var stock = raw.stockIndicator === undefined
      ? { choice: "pending", before: null, after: null } : raw.stockIndicator
    if (!_plain(stock) || ["pending", "keep", "hidden"].indexOf(stock.choice) < 0 ||
        !(stock.before === null || Array.isArray(stock.before)) ||
        !(stock.after === null || Array.isArray(stock.after)))
      return { ok: false, error: _error("settings-invalid", "Stock indicator settings are invalid.") }
    return { ok: true, value: {
      automationEnabled: schedule.value.automationEnabled,
      nightTemperature: schedule.value.nightTemperature,
      transitionMinutes: schedule.value.transitionMinutes,
      stockIndicator: _clone(stock)
    }}
  }

  function reconcileSettings() {
    var entry = _settingsEntry(shell ? shell.shellConfig : null)
    var raw = entry || {}
    var checked = _validateFullSettings(raw)
    _settingsReady = true
    if (!checked.ok) {
      _settingsError = _error("settings-invalid", checked.error.message || "Night Light settings are invalid.")
      // A bad live transaction never partially replaces the last valid one.
      _maybeInitialize()
      return false
    }
    var previousSettings = _settings
    var changed = JSON.stringify(previousSettings) !== JSON.stringify(checked.value)
    var warmthChanged = Number(previousSettings.nightTemperature) !== Number(checked.value.nightTemperature)
    _settings = checked.value
    _inlineEntry = _clone(entry || { id: moduleName })
    _settingsError = null
    if (_initializationComplete && changed && !_warmthCommitInFlight) {
      if (warmthChanged) _evaluateSchedule(true, false, false, true)
      else _evaluateSchedule(true)
    }
    _maybeInitialize()
    return true
  }

  function _commitSettings(changes, persistedWarmth) {
    if (!_plain(changes)) return false
    if (persistedWarmth === true && (!shell || typeof shell.updateEntryInline !== "function")) return false
    var merged = _clone(_inlineEntry || { id: moduleName })
    merged.id = moduleName
    for (var key in changes) if (key !== "id") merged[key] = _clone(changes[key])
    var checked = _validateFullSettings(merged)
    if (!checked.ok) {
      _settingsError = _error("settings-invalid", checked.error.message)
      return false
    }
    // Canonical publication and Omarchy's write initiation are synchronous and
    // precede any fresh schedule calculation or controller submission.
    _inlineEntry = merged
    _settings = checked.value
    _settingsError = null
    _warmthCommitInFlight = persistedWarmth === true
    if (shell && typeof shell.updateEntryInline === "function")
      shell.updateEntryInline(moduleName, merged)
    _warmthCommitInFlight = false
    if (persistedWarmth === true) _evaluateSchedule(true, false, false, true)
    else _evaluateSchedule(true)
    return true
  }

  function updateSettings(changes) {
    var warmth = _plain(changes) && Object.prototype.hasOwnProperty.call(changes, "nightTemperature")
    return _commitSettings(changes, warmth)
  }

  function setAutomationEnabled(value) { return _commitSettings({ automationEnabled: value }, false) }
  function setNightTemperature(value) {
    if (typeof value !== "number" || !isFinite(value) || Math.floor(value) !== value ||
        value < 1000 || value > 6500) return false
    return _commitSettings({ nightTemperature: value }, true)
  }
  function stepNightTemperature(direction) {
    if (typeof direction !== "number" || !isFinite(direction) || Math.floor(direction) !== direction ||
        (direction !== -1 && direction !== 1)) return false
    var current = Number(_settings.nightTemperature)
    if (!isFinite(current) || Math.floor(current) !== current || current < 1000 || current > 6500) return false
    var next = Math.max(1000, Math.min(6500, current + direction * 250))
    if (next === current) return false
    return _commitSettings({ nightTemperature: next }, true)
  }
  function setTransitionMinutes(value) { return _commitSettings({ transitionMinutes: value }, false) }

  onShellChanged: if (_started) reconcileSettings()

  Connections {
    target: root.shell
    enabled: root.shell !== null
    ignoreUnknownSignals: true
    function onShellConfigChanged() { root.reconcileSettings() }
  }

  FileView {
    id: weatherFile
    path: root._weatherPath
    watchChanges: true
    printErrors: false
    onFileChanged: {
      root._weatherRetries = 0
      root._weatherReloading = true
      weatherDebounce.interval = 200
      weatherDebounce.restart()
    }
    onLoaded: root._weatherLoaded(text())
    onLoadFailed: function(fileError) { root._weatherFailed(fileError) }
  }

  Timer {
    id: weatherDebounce
    repeat: false
    onTriggered: weatherFile.reload()
  }

  function _weatherLoaded(text) {
    var parsed = LocationModel.parseWeather(text, Date.now())
    if (!parsed.ok && _weatherRetries < 5) {
      ++_weatherRetries
      _weatherReloading = true
      weatherDebounce.interval = 100
      weatherDebounce.restart()
      return
    }
    _weatherReloading = false
    _weatherReady = true
    _weatherRead = parsed
    _onWeatherSettled()
  }

  function _weatherFailed(fileError) {
    if (_weatherReloading && _weatherRetries < 5) {
      ++_weatherRetries
      weatherDebounce.interval = 100
      weatherDebounce.restart()
      return
    }
    _weatherReloading = false
    _weatherReady = true
    var absent = fileError === FileViewError.FileNotFound
    _weatherRead = absent
      ? { outcome: "absent", ok: false, location: null, error: null }
      : { outcome: "temporarily-unavailable", ok: false, location: null,
          error: _error("weather-temporarily-unavailable", "Weather location is temporarily unavailable.") }
    _onWeatherSettled()
  }

  function _onWeatherSettled() {
    if (!_initializationComplete) {
      _maybeInitialize()
      return
    }
    if (!_privateState || _privateState.mode !== "weather" || !_weatherRead.ok) return
    var selected = LocationModel.selectedLocation(_privateState, _weatherRead, Date.now())
    if (!selected.ok || !selected.shouldRefreshCache) return
    var candidate = _clone(_privateState)
    candidate.weatherCache = _clone(_weatherRead.location)
    _persistState(candidate, _privateState.revision, "weather-refresh")
  }

  Process {
    id: controllerProcess
    command: ["/usr/bin/python", root._pluginDirectory + "/Controller.py", "attach"]
    stdinEnabled: true
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { root._controllerLine(line) }
    }
    stderr: SplitParser {
      splitMarker: "\n"
      onRead: function(line) {
        // Controller messages intentionally contain no private payload.  Avoid
        // forwarding stderr into the shell log; expose one stable error only.
        if (String(line).trim()) root._actionError = root._error("controller-unavailable", "Night Light controller reported an error.")
      }
    }
    onStarted: {
      root._restartAttempts = 0
      root._actionError = null
    }
    onExited: function(exitCode, exitStatus) { root._controllerExited(exitCode) }
  }

  Timer {
    id: controllerRestart
    interval: 1000
    repeat: false
    onTriggered: if (!root._shuttingDown) controllerProcess.running = true
  }

  function _controllerExited(exitCode) {
    _controllerReady = false
    _backendProbed = false
    _initializationComplete = false
    _initializationInFlight = false
    _backendAvailable = false
    _actual = { kind: "unavailable" }
    _applyBusy = false
    _pendingRequests = ({})
    _lastSent = null
    if (_shuttingDown) return
    _backendError = _error("backend-unavailable", "The Night Light controller is unavailable.")
    ++_restartAttempts
    controllerRestart.interval = Math.min(30000, _restartAttempts < 3 ? 250 * _restartAttempts : 1000 * Math.pow(2, Math.min(5, _restartAttempts - 3)))
    controllerRestart.restart()
  }

  function _nextRequestId() { return "qml-" + (++_requestSequence) }
  function _nextGeneration() { return ++_generationSequence }

  function _familyCurrent(family) {
    if (family === "backend") return _backendGeneration
    if (family === "probe") return _probeGeneration
    if (family === "state") return _stateGeneration
    if (family === "search") return _searchGeneration
    if (family === "auto") return _autoGeneration
    if (family === "timeline") return _timelineGeneration
    return -1
  }

  function _send(operation, fields, family, context) {
    if (!_controllerReady || !controllerProcess.running) return ""
    var requestId = _nextRequestId()
    var generation = _nextGeneration()
    var request = { protocol: 1, requestId: requestId, generation: generation, operation: operation }
    fields = fields || {}
    for (var key in fields) request[key] = fields[key]
    if (family === "backend") _backendGeneration = generation
    else if (family === "probe") _probeGeneration = generation
    else if (family === "state") _stateGeneration = generation
    else if (family === "search") _searchGeneration = generation
    else if (family === "auto") _autoGeneration = generation
    else if (family === "timeline") _timelineGeneration = generation
    _pendingRequests[requestId] = { operation: operation, family: family || "", generation: generation, context: context || null }
    controllerProcess.write(JSON.stringify(request) + "\n")
    return requestId
  }

  function _responseRequest(message) {
    if (message.requestId === undefined || message.requestId === null) return null
    var pending = _pendingRequests[String(message.requestId)]
    if (!pending) return null
    if (Number(message.generation) !== pending.generation ||
        (pending.family && _familyCurrent(pending.family) !== pending.generation)) {
      delete _pendingRequests[String(message.requestId)]
      return null
    }
    return pending
  }

  function _finishResponse(message) {
    if (message.requestId !== undefined && message.requestId !== null)
      delete _pendingRequests[String(message.requestId)]
  }

  function _controllerLine(raw) {
    var line = String(raw || "").trim()
    if (!line) return
    var message
    try { message = JSON.parse(line) } catch (exception) {
      _actionError = _error("controller-protocol", "Night Light controller returned invalid data.")
      return
    }
    if (!_plain(message) || message.protocol !== 1) return
    if (message.type === "ready") {
      // A replacement attachment repeats the complete read/probe handshake;
      // retained schedule data stays visible but cannot be written meanwhile.
      _initializationComplete = false
      _initializationInFlight = false
      _controllerReady = true
      _stateReady = false
      _stateBusy = true
      _send("readLocationState", {}, "state", { startup: true })
      _probeBackend(true)
      if (_activeScheduleLocation) _requestTimeline()
      return
    }

    var pending = _responseRequest(message)
    // Responses carrying a stale/unknown request id cannot publish.  Broadcast
    // backend status has no request id and remains authoritative.
    if (message.requestId !== undefined && message.requestId !== null && !pending) return

    if (message.type === "backendStatus") {
      _handleBackendStatus(message, pending)
      _finishResponse(message)
    } else if (message.type === "locationState") {
      _handleLocationState(message, pending)
      _finishResponse(message)
    } else if (message.type === "networkResult") {
      _handleNetworkResult(message, pending)
      _finishResponse(message)
    } else if (message.type === "civilDay") {
      _handleCivilDay(message, pending)
      _finishResponse(message)
    } else if (message.type === "error") {
      _handleControllerError(message, pending)
      _finishResponse(message)
    }
  }

  function _handleBackendStatus(message, pending) {
    var recovered = _initializationComplete && _backendProbed && !_backendAvailable && message.available === true
    var previousOverride = JSON.stringify(_override)
    _backendAvailable = message.available === true
    _actual = _plain(message.actual) ? _clone(message.actual) : { kind: "unavailable" }
    _override = _plain(message.override) ? _clone(message.override) : null
    if (previousOverride !== JSON.stringify(_override) && _activeScheduleLocation)
      _requestTimeline()
    if (pending && pending.context && pending.context.apply) _applyBusy = false
    if (pending && pending.context && pending.context.startupProbe) _backendProbed = true
    if (message.error) {
      var code = String(message.error)
      _backendError = _error(code, code === "apply-failed"
        ? "Night Light could not apply the requested display setting."
        : "hyprsunset did not respond.")
    } else if (_backendAvailable) {
      _backendError = null
    }
    _maybeInitialize()
    if (_initializationComplete && _backendAvailable && _backendProbed) {
      if (_override && overrideUntil > 0 && Date.now() >= overrideUntil) _evaluateSchedule(true, true)
      else if (!_override && _scheduleValid && _settings.automationEnabled) _sendScheduled(false, false, recovered)
    }
  }

  function _privateReadResult(message) {
    if (message.outcome === "valid") {
      var parsed = LocationModel.parsePrivateState(message.state)
      return parsed.ok ? { outcome: "valid", ok: true, state: parsed.state, error: null }
        : { outcome: "malformed", ok: false, state: null, error: _error("state-malformed", "Location state is malformed.") }
    }
    if (message.outcome === "absent") return { outcome: "absent", ok: false, state: null, error: null }
    if (message.outcome === "unsupported-schema")
      return { outcome: "unsupported-schema", ok: false, state: null, error: _error("state-unsupported-schema", "Location state uses an unsupported schema.") }
    if (message.outcome === "temporarily-unavailable")
      return { outcome: "temporarily-unavailable", ok: false, state: null, error: _error("state-temporarily-unavailable", "Location state is temporarily unavailable.") }
    return { outcome: "malformed", ok: false, state: null, error: _error("state-malformed", "Location state is malformed.") }
  }

  function _handleLocationState(message, pending) {
    _stateBusy = false
    if (pending && pending.operation === "readLocationState") {
      if (pending.context && pending.context.conflictResolution) {
        _handleConflictRead(message, pending)
        return
      }
      _privateRead = _privateReadResult(message)
      _stateReady = true
      _maybeInitialize()
      return
    }
    if (pending && pending.operation === "forgetLocationState" && message.outcome === "absent") {
      _privateState = null
      _privateRead = { outcome: "absent", ok: false, state: null, error: null }
      _committedLocation = null
      _activeScheduleLocation = null
      _scheduleValid = false
      _schedule = { ok: false, phase: "error", target: null, sunsetMs: 0, sunriseMs: 0,
                    nextBoundaryMs: 0, nextEvaluationMs: 0 }
      _stateError = null
      _calculationError = null
      _lastSent = null
      scheduleTimer.stop()
      probeTimer.stop()
      _publishTimelineUnavailable(null, { locationKey: "" })
      _refreshMoon(Date.now())
      _initializationComplete = true
      return
    }
    if (!pending || pending.operation !== "writeLocationState" || message.outcome !== "valid") return
    var parsed = LocationModel.parsePrivateState(message.state)
    if (!parsed.ok) {
      _stateError = _error("state-malformed", "Saved location state was invalid.")
      _finishInitialization()
      return
    }
    _privateState = parsed.state
    _privateRead = { outcome: "valid", ok: true, state: parsed.state, error: null }
    _pendingWeatherPersistence = null
    _stateError = null
    // Serialize private transactions in QML as well as in the daemon. A fast
    // A→B edit cannot make B use A's now-obsolete expected revision. Ordinary
    // completion never installs A while B waits; conflict recovery may retain
    // an already-valid Weather schedule until authoritative state is read.
    if (_drainQueuedStateWrite(parsed.state, parsed.state.mode)) return
    if (pending.context && pending.context.after === "auto-locate") {
      _initializationComplete = true
      _requestAutoLocation(true)
      return
    }
    _installCommittedState(parsed.state, pending.context && pending.context.preview)
  }

  function _handleNetworkResult(message, pending) {
    _networkBusy = false
    if (!pending) return
    if (message.cancelled) return
    _networkError = null
    if (pending.operation === "geocode") {
      if (!_editorOpen || pending.context.searchEpoch !== _searchEpoch ||
          pending.context.query !== LocationModel.normalizeQuery(_manualQuery)) return
      var out = []
      var rows = Array.isArray(message.results) ? message.results : []
      for (var i = 0; i < rows.length; ++i) {
        var checked = LocationModel.canonicalLocation(rows[i], "manual-search")
        if (checked.ok) out.push(checked.location)
      }
      _searchResults = out
    } else if (pending.operation === "autoLocate") {
      if (pending.context.locationEpoch !== _locationEpoch) return
      var candidate = LocationModel.canonicalLocation(message.result, "auto-ip")
      if (!candidate.ok) {
        _networkError = _error("offline", "Approximate location data was invalid.")
        return
      }
      var accepted = _privateState ? _privateState.autoIpCache : null
      var assessment = LocationModel.assessAutoCandidate(accepted, candidate.location)
      _autoCandidate = { location: candidate.location, assessment: assessment }
      _draftLocation = candidate.location
      if (assessment.ok && assessment.mayInstallAutomatically) acceptAutomaticCandidate()
    }
  }

  function _handleControllerError(message, pending) {
    var code = String(message.code || "controller-error")
    if (code === "stale-generation") return
    if (pending && pending.operation === "projectCivilDay") {
      // Projection failure is isolated from schedule/backend truth.  A final
      // transaction still has valid projected bounds for a neutral snapshot.
      var timelineContext = pending.context || null
      var errorFallback = timelineContext &&
        (timelineContext.boundsProjection || timelineContext.failedProjection)
      if (!_publishTimelineUnavailable(errorFallback, timelineContext) && timelineContext) {
        if (timelineContext.stage === "bounds") {
          // A protocol/controller error receives the same one bounded eventless
          // retry as malformed bounds.  Failure to enqueue that retry is itself
          // terminal and must not leave cold startup at null.
          if (!_requestNeutralTimelineProjection(timelineContext, null))
            _publishDeterministicTimelineUnavailable(null, timelineContext)
        } else if (timelineContext.stage === "neutral") {
          _publishDeterministicTimelineUnavailable(errorFallback, timelineContext)
        }
      }
      return
    }
    if (pending && (pending.operation === "geocode" || pending.operation === "autoLocate")) {
      _networkBusy = false
      _networkError = _error(code === "rate-limited" ? "rate-limited" : "offline", String(message.message || "Location provider is unavailable."))
    } else if (pending && (pending.operation === "writeLocationState" || pending.operation === "forgetLocationState" || pending.operation === "readLocationState")) {
      _stateBusy = false
      if (pending.operation === "writeLocationState") {
        if (code === "revision-conflict") {
          _resolveRevisionConflict(pending, message)
          return
        }
        // Failure does not make A current. Give the one-slot latest-wins queue
        // the same immediate drain as success, before A can publish an error
        // or a useful Weather preview.
        var failedContext = pending.context || {}
        var failedBase = _privateState
        if (!failedBase && _privateRead && _privateRead.ok) failedBase = _privateRead.state
        if (!failedBase && Number(failedContext.expectedRevision) === 0) failedBase = {
          schemaVersion: 1, revision: 0, mode: "none", autoConsentVersion: 0,
          manual: null, weatherCache: null, autoIpCache: null
        }
        var failedMode = failedContext.candidate ? failedContext.candidate.mode
          : (failedBase ? failedBase.mode : "none")
        if (_drainQueuedStateWrite(failedBase, failedMode)) return
        if (_installWeatherAfterPersistenceFailure(pending)) return
      }
      if (pending.operation === "readLocationState" && pending.context && pending.context.conflictResolution) {
        _retainConflictedIntent(pending.context.intent,
          String(message.message || "Location state could not be read."))
        return
      }
      _stateError = _error(code, String(message.message || "Location state could not be updated."))
      _finishInitialization(pending.operation !== "readLocationState")
    } else {
      _applyBusy = false
      _backendError = _error(code === "apply-failed" ? "apply-failed" : "backend-unavailable",
                            String(message.message || "Night Light backend is unavailable."))
    }
  }

  function _stateIntentFromContext(context) {
    context = context || {}
    return { candidate: _clone(context.candidate), preview: context.preview,
             reason: context.reason, after: context.after || "",
             conflictRetries: Number(context.conflictRetries || 0) }
  }

  function _beginConflictRead(intent) {
    if (!intent || !intent.candidate) return false
    // Every intent receives at most one authoritative read plus one rebased
    // CAS attempt. A later user intent gets its own bounded attempt, but a hot
    // external writer can never make one intent spin forever.
    intent.conflictRetries = 1
    _stateError = null
    _stateBusy = true
    _send("readLocationState", {}, "state", { conflictResolution: true, intent: intent })
    return true
  }

  function _retainConflictedIntent(intent, message) {
    // An interaction made during recovery supersedes the failed in-flight
    // intent. Keep whichever is newest for explicit Refresh recovery instead
    // of acknowledging it and silently throwing it away.
    var retained = _queuedStateWrite || intent
    _queuedStateWrite = retained || null
    var detail = String(message || "Location changed again.")
    if (detail.toLowerCase().indexOf("refresh") < 0)
      detail += " Refresh to retry your latest location change."
    _stateError = _error("revision-conflict", detail)
    _finishInitialization(true)
  }

  function _resolveRevisionConflict(pending, message) {
    var context = pending.context || {}
    var attempts = Number(context.conflictRetries || 0)
    if (attempts >= 1) {
      var newer = _queuedStateWrite
      _queuedStateWrite = null
      // The retry exhausted B's budget, not C's. Re-read for a C that arrived
      // while B was in flight; if C also conflicts it will be retained below.
      if (newer) {
        if (_beginConflictRead(newer)) return
        _retainConflictedIntent(newer, "The latest location change could not be retried.")
        return
      }
      _retainConflictedIntent(_stateIntentFromContext(context),
        String(message.message || "Location changed again. Refresh to retry your latest location change."))
      return
    }

    // Keep only the newest local intent. The failed write is still the intent
    // when nothing newer was queued while it was in flight.
    var intent = _queuedStateWrite
    _queuedStateWrite = null
    if (!intent) intent = _stateIntentFromContext(context)

    // A startup Weather cache write is ancillary to an already valid schedule.
    // Publish that validated in-memory schedule while the authoritative state
    // read and bounded retry are in flight rather than falling back to setup.
    var preview = context.preview
    if (context.weatherPersistence === true && preview && preview.ok && !preview.setup &&
        preview.state && preview.state.mode === "weather" && preview.location &&
        preview.location.source === "weather") {
      _stateError = null
      _installCommittedState(preview.state, preview)
    }

    if (!_beginConflictRead(intent))
      _retainConflictedIntent(intent, "The latest location change could not be retried.")
  }

  function _handleConflictRead(message, pending) {
    var read = _privateReadResult(message)
    if (!read.ok || !read.state) {
      _retainConflictedIntent(pending.context && pending.context.intent,
        read.error ? read.error.message : "Location state changed and could not be read. Refresh to retry your latest location change.")
      return
    }

    var authoritative = read.state
    _privateRead = read
    _privateState = authoritative
    _stateReady = true
    _pendingWeatherPersistence = null
    _stateError = null
    // The external winner is committed and therefore safe to operate while a
    // rebased local intent is retried. For Weather, _previewState deliberately
    // continues to prefer the current in-memory Weather observation.
    _installCommittedState(authoritative, null)

    // An edit made during the conflict read supersedes the intent that caused
    // the conflict, preserving the service's one-slot latest-wins contract.
    var intent = _queuedStateWrite || (pending.context && pending.context.intent)
    _queuedStateWrite = null
    if (!intent) return
    var retry = _sendRebasedStateIntent(intent, authoritative)
    if (retry.superseded) return
    if (!retry.ok)
      _retainConflictedIntent(intent, retry.error ? retry.error.message :
        "Location intent could not be rebased. Refresh to retry your latest location change.")
  }

  function _rebaseStateIntent(intent, authoritative) {
    if (!intent || !intent.candidate)
      return { ok: false, error: _error("state-malformed", "Location intent is missing.") }
    var source = intent.candidate
    var candidate = _clone(authoritative)
    var reason = String(intent.reason || "")
    if (reason === "startup" || reason === "weather-refresh") {
      // Cache maintenance must not undo an external source selection.
      if (authoritative.mode !== "weather") return { ok: false, superseded: true }
      candidate.weatherCache = _clone(source.weatherCache)
    } else if (reason === "manual") {
      candidate.mode = "manual"
      candidate.manual = _clone(source.manual)
    } else if (reason === "weather") {
      candidate.mode = "weather"
      candidate.weatherCache = _clone(source.weatherCache)
    } else if (reason === "auto-consent") {
      candidate.autoConsentVersion = source.autoConsentVersion
    } else if (reason === "auto-accept") {
      candidate.mode = "auto-ip"
      candidate.autoConsentVersion = source.autoConsentVersion
      candidate.autoIpCache = _clone(source.autoIpCache)
    } else {
      return { ok: false, error: _error("state-malformed", "Location intent is unsupported.") }
    }
    candidate.revision = authoritative.revision
    var parsed = LocationModel.parsePrivateState(candidate)
    if (!parsed.ok) return { ok: false, error: parsed.error }
    var preview = _previewState(parsed.state)
    if (!preview.ok) return { ok: false, error: preview.error }
    return { ok: true, candidate: parsed.state, preview: preview }
  }

  function _sendRebasedStateIntent(intent, authoritative) {
    var rebased = _rebaseStateIntent(intent, authoritative)
    if (!rebased.ok) return rebased
    var revision = Number(authoritative.revision)
    _stateBusy = true
    _send("writeLocationState", { state: rebased.candidate, expectedRevision: revision }, "state",
          { reason: intent.reason, preview: rebased.preview, after: intent.after || "",
            candidate: _clone(rebased.candidate), expectedRevision: revision,
            conflictRetries: Number(intent.conflictRetries || 0),
            weatherPersistence: (intent.reason === "startup" || intent.reason === "weather-refresh") &&
              rebased.candidate.mode === "weather" })
    return { ok: true }
  }

  function _drainQueuedStateWrite(authoritative, precedingMode) {
    if (!_queuedStateWrite) return false
    var queued = _queuedStateWrite
    _queuedStateWrite = null
    // A Weather watcher event captured under Weather mode cannot overtake a
    // user transaction that has just selected another source, including when
    // that user transaction itself failed to persist.
    if (queued.reason === "weather-refresh" && precedingMode !== "weather") return false
    if (!authoritative) {
      _queuedStateWrite = queued
      _stateError = _error("state-malformed", "Location intent could not be rebased onto known state.")
      _finishInitialization(true)
      return true
    }
    // The queued object is only an intent snapshot. Always reconstruct its
    // candidate and preview from the latest canonical state: on success this
    // is predecessor A's committed result, while on failure it is the state
    // that preceded A.
    var sent = _sendRebasedStateIntent(queued, authoritative)
    if (sent.superseded) return false
    if (!sent.ok) {
      _queuedStateWrite = queued
      _stateError = sent.error || _error("state-malformed", "Location intent could not be rebased.")
      _finishInitialization(true)
    }
    return true
  }

  function _installWeatherAfterPersistenceFailure(pending) {
    var context = pending && pending.context
    var preview = context && context.preview
    if (!context || context.weatherPersistence !== true || !preview || !preview.ok || preview.setup ||
        !preview.state || preview.state.mode !== "weather" || !preview.location || preview.location.source !== "weather") return false
    _pendingWeatherPersistence = {
      candidate: _clone(context.candidate),
      expectedRevision: Number(context.expectedRevision),
      reason: String(context.reason || "weather-refresh")
    }
    _stateError = _error("state-persistence-failed",
      "Weather location is active, but its private cache could not be saved. Refresh to retry when storage is writable.")
    // Weather is already validated and its schedule preview is valid. Storage
    // failure must not turn that usable in-memory location into setup mode.
    _installCommittedState(preview.state, preview)
    return true
  }

  function _retryWeatherPersistence() {
    var retry = _pendingWeatherPersistence
    if (!retry || _stateBusy || !_privateState || _privateState.mode !== "weather") return false
    return _persistState(_clone(retry.candidate), retry.expectedRevision, retry.reason)
  }

  function _maybeInitialize() {
    if (_initializationComplete || _initializationInFlight || !_settingsReady || !_weatherReady ||
        !_controllerReady || !_stateReady || !_backendProbed) return
    _initializationInFlight = true
    var boot = LocationModel.bootstrap(_privateRead, _weatherRead, Date.now())
    if (!boot.ok) {
      _stateError = boot.error || _error("location-unavailable", "Choose a location.")
      _finishInitialization(false)
      return
    }
    if (boot.shouldPersist && boot.state) {
      var candidate = _clone(boot.state)
      if (boot.location && candidate.mode === "weather") candidate.weatherCache = _clone(boot.location)
      _persistState(candidate, boot.state.revision, "startup")
      return
    }
    _privateState = boot.state
    _installCommittedState(boot.state, null)
  }

  function _finishInitialization(allowSchedule) {
    _initializationInFlight = false
    _initializationComplete = true
    _stateBusy = false
    if (allowSchedule === false) {
      scheduleTimer.stop()
      probeTimer.stop()
      return
    }
    if (_scheduleValid) {
      _armTimers()
      // Startup and replacement attachments are observational when the probe
      // already found the scheduled target.  Divergence is still reconciled by
      // _sendScheduled's comparison with the freshly published actual state.
      if (_settings.automationEnabled && _backendAvailable && _backendProbed && !_override) _sendScheduled(false)
    }
  }

  function _previewState(state) {
    var parsed = LocationModel.parsePrivateState(state)
    if (!parsed.ok) return { ok: false, error: parsed.error }
    var selected = LocationModel.selectedLocation(parsed.state, _weatherRead, Date.now())
    if (!selected.ok) {
      if (parsed.state.mode === "none") return { ok: true, setup: true, state: parsed.state, location: null, schedule: null }
      return { ok: false, error: selected.error }
    }
    var calculated = _calculate(Date.now(), selected.location)
    if (!calculated.ok) return { ok: false, error: calculated.error }
    return { ok: true, setup: false, state: parsed.state, location: selected.location, schedule: calculated }
  }

  function _persistState(candidate, expectedRevision, reason, after) {
    if (!_controllerReady) return false
    var preview = _previewState(candidate)
    if (!preview.ok) {
      _calculationError = preview.error || _error("calculation-failed", "The location could not produce a schedule.")
      _finishInitialization()
      return false
    }
    _actionError = null
    if (_stateBusy) {
      _queuedStateWrite = { candidate: _clone(candidate), preview: preview,
                            reason: reason, after: after || "", conflictRetries: 0 }
      return true
    }
    // A fresh interaction supersedes an older terminally conflicted intent.
    // That retained slot is otherwise retried only by explicit Refresh.
    _queuedStateWrite = null
    _stateBusy = true
    var weatherPersistence = (reason === "startup" || reason === "weather-refresh") &&
      candidate && candidate.mode === "weather"
    _send("writeLocationState", { state: candidate, expectedRevision: expectedRevision }, "state",
          { reason: reason, preview: preview, after: after || "", candidate: _clone(candidate),
            expectedRevision: expectedRevision, conflictRetries: 0,
            weatherPersistence: weatherPersistence })
    return true
  }

  function _installCommittedState(state, preview) {
    _privateState = state
    if (!state || state.mode === "none") {
      _committedLocation = null
      _activeScheduleLocation = null
      _scheduleValid = false
      _calculationError = null
      _publishTimelineUnavailable(null, { locationKey: "" })
      _refreshMoon(Date.now())
      _finishInitialization()
      return
    }
    var result = preview && preview.ok ? preview : _previewState(state)
    if (!result.ok || result.setup) {
      _calculationError = result.error || _error("location-unavailable", "Choose a location.")
      _finishInitialization()
      return
    }
    _committedLocation = _clone(result.location)
    _activeScheduleLocation = _clone(result.location)
    _schedule = result.schedule
    _scheduleValid = true
    _calculationError = null
    _refreshMoon(Date.now())
    _finishInitialization()
    _requestTimeline()
    _maybeRefreshAutomatic()
  }

  function _maybeRefreshAutomatic() {
    if (_sessionAutoRefreshUsed || !_privateState || _privateState.mode !== "auto-ip" ||
        _privateState.autoConsentVersion !== 1 || !_privateState.autoIpCache) return
    var fresh = LocationModel.freshness(_privateState.autoIpCache, Date.now(), {})
    if (fresh.ok && fresh.stale) _requestAutoLocation(false)
  }

  function _calculate(now, locationValue) {
    try {
      var coordinateCheck = SolarModel.validateCoordinates(locationValue.latitude, locationValue.longitude)
      if (coordinateCheck === false || (coordinateCheck && coordinateCheck.ok === false))
        return { ok: false, error: _error("calculation-failed", "Location coordinates are invalid.") }
      var events = SolarModel.surroundingEvents(now, locationValue.latitude, locationValue.longitude)
      var result = ScheduleModel.evaluate(now, events, _settings)
      return result.ok ? result : { ok: false, error: result.error || _error("calculation-failed", "Solar schedule could not be calculated.") }
    } catch (exception) {
      return { ok: false, error: _error("calculation-failed", "Solar schedule could not be calculated.") }
    }
  }

  function _evaluateSchedule(forceApply, resumeOverride, observational, temperatureOnly) {
    if (!_activeScheduleLocation) return false
    var result = _calculate(Date.now(), _activeScheduleLocation)
    if (!result.ok) {
      _calculationError = result.error
      _scheduleValid = false
      scheduleTimer.interval = 30000
      scheduleTimer.restart()
      return false
    }
    _schedule = result
    _scheduleValid = true
    _calculationError = null
    _armTimers()
    if (observational !== true && _initializationComplete && _settings.automationEnabled &&
        _backendAvailable && _backendProbed && (!_override || resumeOverride === true) &&
        (temperatureOnly !== true || (_schedule.target && _schedule.target.kind === "temperature")))
      _sendScheduled(forceApply === true, resumeOverride === true)
    return true
  }

  function _armTimers() {
    if (!_scheduleValid) return
    var delay = Math.max(1, Math.min(2147483000, _schedule.nextEvaluationMs - Date.now()))
    scheduleTimer.interval = delay
    scheduleTimer.restart()
    var transition = _schedule.phase === "evening-transition" || _schedule.phase === "morning-transition"
    probeTimer.interval = transition ? 5000 : 30000
    probeTimer.restart()
  }

  function _clockDiscontinuity() {
    var now = Date.now()
    if (_lastWallMs === 0) {
      _lastWallMs = now
      monotonicClock.restartMs()
      return false
    }
    var wallDelta = now - _lastWallMs
    var monotonicDelta = monotonicClock.restartMs()
    _lastWallMs = now
    return Math.abs(wallDelta - monotonicDelta) > 2000
  }

  function _handleTimerWake() {
    if (_clockDiscontinuity()) {
      _lastSent = null
      _wakeProbeStep = 0
      _evaluateSchedule(false)
      _requestTimeline()
      _refreshMoon(Date.now())
      _probeBackend(false)
      wakeProbeTimer.interval = 1000
      wakeProbeTimer.restart()
      return
    }
    _evaluateSchedule(false)
  }

  ElapsedTimer { id: monotonicClock }

  Timer {
    id: timelineTimer
    repeat: false
    onTriggered: {
      var jumped = root._clockDiscontinuity()
      root._requestTimeline()
      if (jumped) root._refreshMoon(Date.now())
      root._armTimelineTimer()
    }
  }

  Timer {
    id: lunarTimer
    repeat: false
    onTriggered: {
      var jumped = root._clockDiscontinuity()
      root._refreshMoon(Date.now())
      if (jumped) root._requestTimeline()
      root._armLunarTimer()
    }
  }

  Timer {
    id: scheduleTimer
    repeat: false
    onTriggered: root._handleTimerWake()
  }

  Timer {
    id: probeTimer
    repeat: false
    onTriggered: {
      var jumped = root._clockDiscontinuity()
      if (jumped) {
        root._requestTimeline()
        root._refreshMoon(Date.now())
      }
      root._probeBackend(false)
      var transition = root._schedule.phase === "evening-transition" || root._schedule.phase === "morning-transition"
      interval = transition ? 5000 : 30000
      restart()
    }
  }

  Timer {
    id: wakeProbeTimer
    repeat: false
    onTriggered: {
      root._probeBackend(false)
      ++root._wakeProbeStep
      if (root._wakeProbeStep < 2) { interval = 2000; restart() }
    }
  }

  function _probeBackend(startup) {
    if (!_controllerReady) return
    // Probes have their own publication generation.  They must not suppress
    // the verified response to an in-flight desired-state transaction.
    _send("probe", {}, "probe", { startupProbe: startup === true })
  }

  function _sendScheduled(force, resume, assertMatching) {
    if (!_scheduleValid || !_settings.automationEnabled || !_backendAvailable || !_backendProbed) return false
    if (_override && resume !== true) return false
    var desired = { kind: _schedule.target.kind }
    if (desired.kind === "temperature") desired.temperature = _schedule.target.temperature
    var ifActual = null
    if (_actual && _actual.kind === "identity") ifActual = { kind: "identity" }
    else if (_actual && _actual.kind === "temperature" && isFinite(Number(_actual.temperature)) &&
             Math.floor(Number(_actual.temperature)) === Number(_actual.temperature) &&
             Number(_actual.temperature) >= 1000 && Number(_actual.temperature) <= 6500)
      ifActual = { kind: "temperature", temperature: Number(_actual.temperature) }
    if (!ifActual) return false
    var marker = { desired: desired, boundary: _schedule.nextBoundaryMs, intent: "schedule" }

    // A normal schedule assertion is unnecessary when observation already
    // proves the display is at its target. Resume clears an override, while a
    // health-recovery assertion replaces any failed deferred target even when
    // fresh schedule pixels already match. Controller preflight keeps both
    // matching cases observational. Force alone never creates a matching write.
    if (resume !== true && assertMatching !== true && _sameTarget(_actual, desired)) {
      _lastSent = marker
      return false
    }
    if (resume !== true && !force && _applyBusy) return false

    _lastSent = marker
    _applyBusy = true
    var fields = { desired: desired, ifActual: ifActual, intent: "schedule", overrideUntil: _schedule.nextBoundaryMs }
    if (resume === true) fields.resume = true
    _send("setDesired", fields, "backend", { apply: true })
    return true
  }

  function _manualDesired(desired) {
    if (!_controllerReady || !_backendProbed) {
      _actionError = _error("backend-unavailable", "Night Light is not ready yet.")
      return false
    }
    var checked = _publicTarget(desired)
    if (!checked) return false
    var wire = { kind: checked.kind }
    if (wire.kind === "temperature") wire.temperature = checked.temperature
    var until = _scheduleValid ? _schedule.nextBoundaryMs : 0
    _lastSent = { desired: wire, boundary: until, intent: "override" }
    _applyBusy = true
    _send("setDesired", { desired: wire, intent: "override", overrideUntil: until }, "backend", { apply: true })
    return true
  }

  function warm() { return _manualDesired({ kind: "temperature", temperature: _settings.nightTemperature }) }
  function daylight() { return _manualDesired({ kind: "identity" }) }
  function toggleManual() {
    if (_override) return resume()
    return _actual && _actual.kind === "identity" ? warm() : daylight()
  }
  function resume() {
    if (!_scheduleValid) return false
    // Keep showing the authoritative override until Controller.py confirms
    // that resume was applied and reports override:null.
    _lastSent = null
    return _evaluateSchedule(true, true)
  }

  function refresh() {
    // Failed private transactions are nonblocking, but Refresh is their
    // explicit, user-bounded recovery path. Recompute/probe remain observational.
    if (!_retryConflictedStateWrite()) _retryWeatherPersistence()
    _evaluateSchedule(false, false, true)
    _probeBackend(false)
    return true
  }

  function _retryConflictedStateWrite() {
    if (_stateBusy || !_queuedStateWrite) return false
    var intent = _queuedStateWrite
    _queuedStateWrite = null
    if (_beginConflictRead(intent)) return true
    _retainConflictedIntent(intent, "The latest location change could not be retried.")
    return true
  }

  // ------------------------------- location editor / private transactions

  function openLocationEditor() {
    _editorOpen = true
    _editorUserChanged = false
    _manualQuery = ""
    _searchResults = []
    _draftLocation = null
    ++_searchEpoch
  }

  function closeLocationEditor() {
    _editorOpen = false
    _editorUserChanged = false
    _manualQuery = ""
    _searchResults = []
    _draftLocation = null
    ++_searchEpoch
    searchDebounce.stop()
    _cancelNetworkRequests()
  }

  function setManualQuery(value, language) {
    _manualQuery = String(value || "")
    _editorUserChanged = true
    _searchResults = []
    _draftLocation = null
    ++_searchEpoch
    searchDebounce.language = String(language || Qt.locale().name || "en")
    var decision = LocationModel.networkDecision("geocode", {
      query: _manualQuery, editorOpen: _editorOpen, userChanged: true
    })
    searchDebounce.stop()
    if (decision.legal) searchDebounce.restart()
    return LocationModel.classifyManualInput(_manualQuery)
  }

  Timer {
    id: searchDebounce
    interval: 350
    repeat: false
    property string language: "en"
    onTriggered: root._startSearch(language)
  }

  function _startSearch(language) {
    var decision = LocationModel.networkDecision("geocode", {
      query: _manualQuery, editorOpen: _editorOpen, userChanged: _editorUserChanged
    })
    if (!decision.legal) return false
    _networkBusy = true
    _networkError = null
    _send("geocode", { query: decision.normalizedQuery, language: language,
                       searchEpoch: _searchEpoch }, "search",
          { query: decision.normalizedQuery, searchEpoch: _searchEpoch })
    return true
  }

  function useManualCoordinates(text) {
    var made = LocationModel.manualCoordinateLocation(text, Date.now())
    if (!made.ok) { _actionError = made.error; return false }
    return commitManualLocation(made.location)
  }

  function commitManualLocation(value) {
    var checked = LocationModel.canonicalLocation(value)
    if (!checked.ok || ["manual-search", "manual-coordinates"].indexOf(checked.location.source) < 0) {
      _actionError = _error("location-invalid", "Choose a valid manual location.")
      return false
    }
    var state = _baseState()
    state.mode = "manual"
    state.manual = checked.location
    ++_locationEpoch
    return _persistState(state, _privateState ? _privateState.revision : 0, "manual")
  }

  function useWeatherLocation() {
    if (!_weatherRead.ok) {
      _actionError = _error("location-unavailable", "Weather location is unavailable.")
      return false
    }
    var state = _baseState()
    state.mode = "weather"
    state.weatherCache = _clone(_weatherRead.location)
    ++_locationEpoch
    return _persistState(state, _privateState ? _privateState.revision : 0, "weather")
  }

  function _baseState() {
    return _clone(_privateState || {
      schemaVersion: 1, revision: 0, mode: "none", autoConsentVersion: 0,
      manual: null, weatherCache: null, autoIpCache: null
    })
  }

  function consentAutomaticLocation() {
    var state = _baseState()
    state.autoConsentVersion = 1
    ++_locationEpoch
    return _persistState(state, _privateState ? _privateState.revision : 0, "auto-consent", "auto-locate")
  }

  function _requestAutoLocation(userRequested) {
    if (!_privateState || _privateState.autoConsentVersion !== 1) {
      _actionError = _error("consent-required", "Approximate location requires confirmation.")
      return false
    }
    _sessionAutoRefreshUsed = true
    _networkBusy = true
    _networkError = null
    _send("autoLocate", { locationEpoch: _locationEpoch }, "auto", { locationEpoch: _locationEpoch })
    return true
  }

  function refreshAutomaticLocation() { return _requestAutoLocation(true) }

  function acceptAutomaticCandidate() {
    if (!_autoCandidate || !_autoCandidate.location) return false
    var checked = LocationModel.canonicalLocation(_autoCandidate.location, "auto-ip")
    if (!checked.ok) return false
    var state = _baseState()
    state.mode = "auto-ip"
    state.autoConsentVersion = 1
    state.autoIpCache = checked.location
    ++_locationEpoch
    _autoCandidate = null
    return _persistState(state, _privateState ? _privateState.revision : 0, "auto-accept")
  }

  function _cancelNetworkRequests() {
    for (var id in _pendingRequests) {
      var item = _pendingRequests[id]
      if (item.operation !== "geocode" && item.operation !== "autoLocate") continue
      var requestId = _nextRequestId()
      var generation = _nextGeneration()
      controllerProcess.write(JSON.stringify({ protocol: 1, requestId: requestId, generation: generation,
                                               operation: "cancel", cancelRequestId: id }) + "\n")
      delete _pendingRequests[id]
    }
    _networkBusy = false
  }

  function forgetLocation(confirm) {
    if (String(confirm || "") !== "confirm") return false
    if (!_controllerReady) return false
    ++_locationEpoch
    ++_searchEpoch
    searchDebounce.stop()
    _cancelNetworkRequests()
    _stateBusy = true
    _send("forgetLocationState", { expectedRevision: _privateState ? _privateState.revision : 0 },
          "state", { forget: true })
    return true
  }

  // ------------------------------- stock indicator compare-and-swap

  function hideStockIndicator(items) {
    if (!Array.isArray(items)) return false
    var before = _clone(items)
    var after = items.filter(function(item) {
      return !(_plain(item) ? String(item.id || "") === "NightLight" : String(item) === "NightLight")
    })
    if (shell && typeof shell.updateEntryInline === "function")
      shell.updateEntryInline("omarchy.indicators", { id: "omarchy.indicators", items: after })
    return updateSettings({ stockIndicator: { choice: "hidden", before: before, after: after } })
  }

  function keepStockIndicator() {
    return updateSettings({ stockIndicator: { choice: "keep", before: null, after: null } })
  }

  function restoreStockIndicator() {
    var stock = _settings.stockIndicator
    if (!stock || stock.choice !== "hidden" || !Array.isArray(stock.before) || !Array.isArray(stock.after)) return "not-hidden"
    var indicator = _settingsEntryFor("omarchy.indicators")
    var current = indicator && Array.isArray(indicator.items) ? indicator.items : null
    if (!current || JSON.stringify(current) !== JSON.stringify(stock.after)) {
      _actionError = _error("indicators-changed", "Indicators changed since setup. Restore NightLight from Bar settings.")
      return "changed"
    }
    var merged = _clone(indicator)
    merged.id = "omarchy.indicators"
    merged.items = _clone(stock.before)
    if (shell && typeof shell.updateEntryInline === "function") shell.updateEntryInline("omarchy.indicators", merged)
    updateSettings({ stockIndicator: { choice: "keep", before: null, after: null } })
    return "restored"
  }

  function _settingsEntryFor(id) {
    var config = shell ? shell.shellConfig : null
    if (!_plain(config) || !config.bar || !_plain(config.bar.layout)) return null
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; ++s) {
      var rows = config.bar.layout[sections[s]]
      if (!Array.isArray(rows)) continue
      for (var i = 0; i < rows.length; ++i)
        if (_plain(rows[i]) && String(rows[i].id || "") === id) return rows[i]
    }
    return null
  }

  // ------------------------------- stable status and shell routing

  function statusObject() {
    var publicActual = _clone(_actual)
    if (publicActual.kind === "identity" && publicActual.temperature === undefined) publicActual.temperature = 6500
    return {
      schemaVersion: 1,
      mode: mode,
      available: available,
      phase: phase,
      busy: busy,
      actual: publicActual,
      target: target ? _clone(target) : null,
      location: _publicLocation(),
      sunset: sunset,
      sunrise: sunrise,
      nextBoundary: nextBoundary,
      overrideUntil: overrideUntil,
      nextUpdate: nextUpdate,
      error: error ? _clone(error) : null
    }
  }

  function _summon() { return shell && typeof shell.summon === "function" ? shell.summon(moduleName, "{}") : false }
  function _hide() { return shell && typeof shell.hide === "function" ? shell.hide(moduleName) : false }
  function _toggle() { return shell && typeof shell.toggle === "function" ? shell.toggle(moduleName, "{}") : false }

  IpcHandler {
    target: "jgordijn.night-light"

    function status(): string { return JSON.stringify(root.statusObject()) }
    function refresh(): string { return root.refresh() ? "ok" : "unavailable" }
    function warm(): string { return root.warm() ? "ok" : "unavailable" }
    function daylight(): string { return root.daylight() ? "ok" : "unavailable" }
    function resume(): string { return root.resume() ? "ok" : "unavailable" }
    function open(): string { return root._summon() ? "ok" : "unknown" }
    function show(): string { return root._summon() ? "ok" : "unknown" }
    function close(): string { return root._hide() ? "ok" : "unknown" }
    function hide(): string { return root._hide() ? "ok" : "unknown" }
    function toggle(): string { return root._toggle() ? "ok" : "unknown" }
    function forgetLocation(confirm: string): string { return root.forgetLocation(confirm) ? "ok" : "confirmation-required" }
    function restoreStockIndicator(): string { return root.restoreStockIndicator() }
  }

  function _start() {
    if (_started) return
    _started = true
    reconcileSettings()
    _lastWallMs = Date.now()
    monotonicClock.restartMs()
    // Lunar startup is independent of controller, location, and backend state.
    _refreshMoon(_lastWallMs)
    _armTimelineTimer()
    _armLunarTimer()
    controllerProcess.running = true
  }

  Component.onCompleted: Qt.callLater(root._start)
  Component.onDestruction: {
    _shuttingDown = true
    scheduleTimer.stop()
    probeTimer.stop()
    wakeProbeTimer.stop()
    timelineTimer.stop()
    lunarTimer.stop()
    weatherDebounce.stop()
    searchDebounce.stop()
    controllerRestart.stop()
    // Closing stdin drops only this attachment lease.  The controller daemon
    // owns the eight-second hot-reload grace and compare-and-swap restoration.
    controllerProcess.running = false
  }
}
