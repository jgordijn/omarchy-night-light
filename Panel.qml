import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "LocationModel.js" as LocationModel

// Stable-width presentation for Service.qml with a composed dashboard and
// content-fitted editors. This file performs no network, filesystem, solar,
// clock-authority, or display-controller I/O.
Panel {
  id: root
  moduleName: "jgordijn.night-light"
  ipcTarget: "jgordijn.night-light"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root
  readonly property var nightLightService: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor("jgordijn.night-light") : null

  property string editorMode: "normal" // normal, location, manual, consent, auto, forget, stock
  // Timeline leads the normal roving order, while Automatic remains the
  // keyboard-open starting point.
  property int focusIndex: 1
  property int editorFocusIndex: 0
  property int resultIndex: 0
  property bool manualTouched: false
  property bool manualSearchObservedBusy: false
  property bool autoSearchObservedBusy: false
  property bool reviewingAutoCandidate: false
  property bool animateEditorHeight: false

  readonly property int nominalContentWidth: Style.space(520)
  readonly property int nominalContentHeight: Style.space(440)
  readonly property var keyboardPanel: panel
  readonly property Item normalKeyboardTarget: keyCatcher
  readonly property Item timelineControl: daylightTimeline
  readonly property Item sourceRowControl: sourceRow
  readonly property Item automaticRowControl: automaticRow
  readonly property var editorViewport: editorScroll
  // The dashboard deliberately keeps its full composition. Editors instead
  // fit their laid-out content, up to the same screen-aware maximum.
  readonly property int normalPanelContentHeight: panel.cappedContentHeight(nominalContentHeight)
  // Do not bind fitted height to editorColumn.implicitHeight: Qt Positioners can
  // retain a hidden branch's previous/max geometry after a mode switch. Build
  // the desired height from the shared chrome and the active branch only.
  readonly property Item activeEditorColumn: {
    if (editorMode === "location") return locationEditorColumn
    if (editorMode === "manual") return manualEditorColumn
    if (editorMode === "consent") return consentEditorColumn
    if (editorMode === "auto") return autoEditorColumn
    if (editorMode === "forget") return forgetEditorColumn
    if (editorMode === "stock") return stockEditorColumn
    return null
  }
  readonly property real editorHeaderImplicitHeight: editorTitleLabel.implicitHeight +
    editorDetailLabel.implicitHeight + editorSeparator.implicitHeight
  readonly property real activeEditorImplicitHeight: activeEditorColumn ? activeEditorColumn.implicitHeight : 0
  readonly property real editorCompositionImplicitHeight: activeEditorColumn
    ? editorHeaderImplicitHeight + activeEditorImplicitHeight + editorColumn.spacing * 3
    : 0
  readonly property int editorPanelContentHeight: panel.fittedContentHeight(editorCompositionImplicitHeight, nominalContentHeight)
  readonly property int targetPanelContentHeight: editorMode === "normal" ? normalPanelContentHeight : editorPanelContentHeight

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property color contentUrgent: bar ? bar.urgent : Color.urgent
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dimForeground: Qt.darker(contentForeground, 1.5)

  function serviceValue(name, fallback) {
    var service = root.nightLightService
    if (!service) return fallback
    if (name in service && service[name] !== undefined && service[name] !== null) return service[name]
    if ("settings" in service && service.settings && name in service.settings && service.settings[name] !== undefined && service.settings[name] !== null)
      return service.settings[name]
    var snapshot = null
    if ("statusSnapshot" in service) snapshot = service.statusSnapshot
    else if ("state" in service) snapshot = service.state
    if (snapshot && name in snapshot && snapshot[name] !== undefined && snapshot[name] !== null)
      return snapshot[name]
    return fallback
  }

  function serviceCall(names, args) {
    var service = root.nightLightService
    if (!service) return false
    var list = typeof names === "string" ? [names] : names
    var argv = args || []
    for (var i = 0; i < list.length; i++) {
      if (typeof service[list[i]] === "function") {
        service[list[i]].apply(service, argv)
        return true
      }
    }
    return false
  }

  function arrayFrom(value) {
    if (!value || typeof value.length !== "number" || typeof value === "string") return []
    var output = []
    for (var i = 0; i < value.length; i++) output.push(value[i])
    return output
  }

  readonly property bool serviceInitialized: nightLightService ? serviceValue("initialized", true) === true : false
  readonly property string runtimeMode: serviceInitialized ? String(serviceValue("mode", "setup")) : "loading"
  readonly property string phase: String(serviceValue("phase", "error"))
  readonly property bool busy: serviceValue("busy", false) === true
  readonly property bool available: serviceValue("available", false) === true
  readonly property var errorState: serviceValue("error", null)
  readonly property string errorCode: errorState && errorState.code ? String(errorState.code) : ""
  readonly property bool backendError: errorCode === "backend-unavailable" || errorCode === "apply-failed" || (!available && serviceInitialized)
  readonly property bool calculationError: errorCode === "calculation-failed" || (phase === "error" && errorCode !== "state-malformed" && errorCode !== "state-unsupported-schema")
  readonly property bool locationStateError: !serviceValue("activeScheduleLocation", null) &&
    (errorCode === "state-malformed" || errorCode === "state-unsupported-schema" || errorCode === "location-unavailable")
  readonly property bool overridden: runtimeMode === "override" || Number(serviceValue("overrideUntil", 0)) > 0
  readonly property var actualState: serviceValue("actual", null)
  readonly property var targetState: serviceValue("target", null)
  readonly property var locationState: serviceValue("location", null)
  readonly property var privateLocationState: serviceValue("privateLocationState", null)
  readonly property var weatherLocation: serviceValue("weatherLocation", serviceValue("availableWeatherLocation",
    privateLocationState ? privateLocationState.weatherCache : null))
  readonly property var searchResults: arrayFrom(serviceValue("searchResults", serviceValue("locationResults", [])))
  readonly property var explicitSearchError: serviceValue("searchError", null)
  readonly property var searchError: explicitSearchError ? explicitSearchError :
    (errorCode === "offline" || errorCode === "rate-limited" ? errorState : null)
  readonly property string searchState: {
    var explicit = serviceValue("searchState", serviceValue("locationSearchState", ""))
    if (explicit) return String(explicit)
    if (busy && editorMode !== "normal") return editorMode === "auto" ? "locating" : "loading"
    if (searchError && searchError.code === "rate-limited") return "rate-limited"
    if (searchError) return "error"
    return searchResults.length > 0 ? "ready" : "idle"
  }
  readonly property var automaticCandidateValue: serviceValue("automaticCandidate", serviceValue("autoCandidate", serviceValue("locationCandidate", null)))
  readonly property var autoCandidate: automaticCandidateValue && automaticCandidateValue.location ? automaticCandidateValue.location : automaticCandidateValue
  readonly property var autoAssessment: automaticCandidateValue && automaticCandidateValue.assessment ? automaticCandidateValue.assessment : null
  readonly property bool autoLocationChanged: autoAssessment && autoAssessment.changed === true
  readonly property bool autoRetryVisible: !autoCandidate && !busy &&
    (searchState === "error" || searchState === "offline" || searchState === "rate-limited" || autoSearchObservedBusy)
  readonly property bool manualRetryVisible: !busy &&
    (searchState === "error" || searchState === "offline" || searchState === "rate-limited")
  readonly property int autoConsentVersion: Number(serviceValue("autoConsentVersion", privateLocationState ? privateLocationState.autoConsentVersion : 0)) || 0
  readonly property var stockSettings: serviceValue("stockIndicator", null)
  readonly property bool stockChoicePending: {
    var explicit = serviceValue("showStockIndicatorChoice", serviceValue("stockIndicatorPending", null))
    if (explicit !== null) return explicit === true
    var choice = stockSettings && stockSettings.choice ? String(stockSettings.choice) : "pending"
    return choice === "pending" && indicatorItemsContainNightLight(currentIndicatorItems())
  }

  readonly property bool automaticEnabled: {
    var local = root.settings ? root.settings.automationEnabled : undefined
    return typeof local === "boolean" ? local : serviceValue("automationEnabled", true) === true
  }
  readonly property int nightTemperature: {
    var local = root.settings ? root.settings.nightTemperature : undefined
    var localNumber = Number(local)
    if (typeof local === "number" && isFinite(localNumber) && Math.floor(localNumber) === localNumber && localNumber >= 1000 && localNumber <= 6500)
      return localNumber
    var serviceNumber = Number(serviceValue("nightTemperature", 4000))
    return isFinite(serviceNumber) && Math.floor(serviceNumber) === serviceNumber && serviceNumber >= 1000 && serviceNumber <= 6500 ? serviceNumber : 4000
  }
  readonly property int transitionMinutes: {
    var local = root.settings ? root.settings.transitionMinutes : undefined
    var localNumber = Number(local)
    if (typeof local === "number" && isFinite(localNumber) && Math.floor(localNumber) === localNumber && localNumber >= 0 && localNumber <= 180)
      return localNumber
    var serviceNumber = Number(serviceValue("transitionMinutes", 45))
    return isFinite(serviceNumber) && Math.floor(serviceNumber) === serviceNumber && serviceNumber >= 0 && serviceNumber <= 180 ? serviceNumber : 45
  }
  readonly property int actualTemperature: {
    var value = actualState && Number(actualState.temperature)
    return isFinite(value) && value >= 1000 && value <= 6500 ? Math.round(value) : 6500
  }
  readonly property bool actualWarm: actualState && String(actualState.kind) === "temperature" && actualTemperature < 6500

  // Service publishes each civil-day timeline as one immutable transaction.
  // Keep that object intact through the panel/component boundary; do not mix
  // its marker, events, zone, or display labels with stable IPC epochs.
  readonly property var timelineSnapshot: serviceValue("timeline", null)
  readonly property var moonPhaseSnapshot: serviceValue("moonPhase", null)
  readonly property var timelineDisplayTimes: timelineSnapshot && timelineSnapshot.displayTimes
    ? timelineSnapshot.displayTimes : null

  readonly property string stateTitle: {
    if (runtimeMode === "loading") return "Loading Night Light"
    if (backendError) return "Night Light is unavailable"
    if (calculationError) return "Schedule unavailable"
    if (overridden) return "Manual override"
    if (locationStateError) return "Location unavailable"
    if (runtimeMode === "setup") return "Choose a location"
    if (phase === "evening-transition") return "Warming"
    if (phase === "night") return "Night light"
    if (phase === "morning-transition") return "Cooling"
    if (phase === "polar-day") return "Midnight sun"
    if (phase === "polar-night") return "Polar night"
    return "Daylight"
  }

  readonly property string stateDetail: {
    if (runtimeMode === "loading") return "Waiting for the scheduler service."
    if (backendError) return "hyprsunset did not respond. Your schedule is still saved."
    if (calculationError) return "The last display setting was left unchanged."
    if (overridden) {
      var resumeAt = projectedDisplayTime("overrideUntil") || projectedDisplayTime("nextBoundary")
      return "Automatic resumes at " + projectedBoundaryName(resumeAt) + " · " +
        formatProjectedTime(resumeAt)
    }
    if (locationStateError) return errorState && errorState.message ? String(errorState.message) : "The saved location could not be read."
    if (runtimeMode === "setup") return "Needed only to calculate sunrise and sunset."
    if (phase === "evening-transition") return nightTemperature + " K by " + formatProjectedTime(projectedDisplayTime("nextBoundary"))
    if (phase === "night") return "Sunrise at " + formatProjectedTime(projectedDisplayTime("sunrise") || projectedDisplayTime("nextBoundary"))
    if (phase === "morning-transition") return "Daylight by " + formatProjectedTime(projectedDisplayTime("nextBoundary"))
    if (phase === "polar-day") return "Daylight until the next calculated sunset"
    if (phase === "polar-night") return "Night light until the next calculated sunrise"
    return "Sunset at " + formatProjectedTime(projectedDisplayTime("sunset") || projectedDisplayTime("nextBoundary"))
  }

  readonly property string heroGlyph: {
    if (runtimeMode === "setup") return "󰍎"
    if (backendError || calculationError) return "󰀪"
    if (overridden) return actualWarm ? "󰖔" : "󰖙"
    if (phase === "day" || phase === "polar-day") return "󰖙"
    return "󰖔"
  }

  readonly property string sourceBadge: {
    var location = locationState
    if (!location) return "No location"
    if (location.stale === true) return "Last known · " + ageText(location.observedAt)
    var source = String(location.source || "")
    var precision = String(location.precision || "")
    if (source === "weather") return "Weather"
    if (source === "manual-coordinates" || precision === "coordinates") return "Coordinates"
    if (source === "auto-ip" || precision === "approximate-city") return "Approximate"
    return "Manual"
  }

  function projectedDisplayTime(name) {
    var times = timelineDisplayTimes
    if (!times || !(name in times)) return null
    var value = times[name]
    return value && typeof value === "object" ? value : null
  }

  function projectedOffsetText(minutes) {
    var value = Number(minutes)
    if (!isFinite(value)) return ""
    var sign = value < 0 ? "−" : "+"
    var absolute = Math.abs(Math.round(value))
    var hours = Math.floor(absolute / 60)
    var mins = absolute % 60
    return "UTC" + sign + (hours < 10 ? "0" : "") + hours + ":" +
      (mins < 10 ? "0" : "") + mins
  }

  function formatProjectedTime(projected) {
    if (!projected) return "—"
    var value = Number(projected.wallMs)
    if (!isFinite(value) || value < 0 || value >= 86400000) return "—"
    var hours = Math.floor(value / 3600000)
    var minutes = Math.floor((value % 3600000) / 60000)
    var seconds = Math.floor((value % 60000) / 1000)
    var milliseconds = Math.floor(value % 1000)
    // Format only controller-projected wall fields. The projected epoch is
    // deliberately ignored so the shell timezone cannot relabel this event.
    var wall = new Date(1970, 0, 1, hours, minutes, seconds, milliseconds)
    var text = Qt.formatTime(wall, Qt.locale().timeFormat(Locale.ShortFormat))
    if (projected.ambiguous === true)
      text += " · " + projectedOffsetText(projected.offsetMinutes)
    return text
  }

  function projectedBoundaryName(projected) {
    var epoch = projected ? Number(projected.epochMs) : NaN
    var sunrise = projectedDisplayTime("sunrise")
    var sunset = projectedDisplayTime("sunset")
    if (isFinite(epoch) && sunrise && Number(sunrise.epochMs) === epoch) return "sunrise"
    if (isFinite(epoch) && sunset && Number(sunset.epochMs) === epoch) return "sunset"
    return (phase === "night" || phase === "morning-transition" || phase === "polar-night")
      ? "sunrise" : "sunset"
  }

  function ageText(observedAt) {
    var epoch = Date.parse(String(observedAt || ""))
    if (!isFinite(epoch)) return "unknown age"
    var hours = Math.max(0, Math.floor((Date.now() - epoch) / 3600000))
    if (hours < 1) return "now"
    if (hours < 24) return hours + "h"
    return Math.floor(hours / 24) + "d"
  }

  function transitionLabel(value) {
    return value === 0 ? "Instant" : value + " min"
  }

  function persistSettings(values) {
    var entry = { id: root.moduleName }
    var serviceEntry = serviceValue("inlineSettings", null)
    if (serviceEntry) {
      for (var serviceKey in serviceEntry)
        if (serviceKey !== "id") entry[serviceKey] = serviceEntry[serviceKey]
    }

    // Panel may persist Automatic, Transition, or presentation metadata, but
    // Warmth is Service-owned. Never let a stale per-panel/host snapshot (or a
    // generic caller) replace the canonical committed nightTemperature.
    if (root.settings) {
      for (var existing in root.settings)
        if (existing !== "id" && existing !== "nightTemperature") entry[existing] = root.settings[existing]
    }
    var canonicalTemperature = serviceEntry ? serviceEntry.nightTemperature : undefined
    if (!(typeof canonicalTemperature === "number" && isFinite(canonicalTemperature) &&
          Math.floor(canonicalTemperature) === canonicalTemperature &&
          canonicalTemperature >= 1000 && canonicalTemperature <= 6500))
      canonicalTemperature = serviceValue("nightTemperature", undefined)
    if (!(typeof canonicalTemperature === "number" && isFinite(canonicalTemperature) &&
          Math.floor(canonicalTemperature) === canonicalTemperature &&
          canonicalTemperature >= 1000 && canonicalTemperature <= 6500)) return false
    entry.nightTemperature = canonicalTemperature

    var serviceStock = serviceValue("stockIndicator", null)
    var localStock = entry.stockIndicator
    if (serviceStock && serviceStock.choice && (!localStock || localStock.choice === "pending") && serviceStock.choice !== "pending")
      entry.stockIndicator = serviceStock
    for (var key in values)
      if (key !== "id" && key !== "nightTemperature") entry[key] = values[key]
    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function setAutomatic(value) {
    persistSettings({ automationEnabled: value === true })
  }

  function stepWarmth(direction) {
    var service = root.nightLightService
    if (!service || typeof service.stepNightTemperature !== "function") return false
    // Service owns the complete persisted-first transaction. One UI step is
    // exactly one canonical service call; a failed/absent service is not faked.
    var committed = false
    try { committed = service.stepNightTemperature(direction) === true }
    catch (exception) { return false }
    if (!committed) return false
    syncSettingsFromService()
    return true
  }

  function stepTransition(direction) {
    var choices = [0, 30, 45, 60, 90]
    var next = transitionMinutes
    if (direction < 0) {
      for (var i = choices.length - 1; i >= 0; i--) if (choices[i] < transitionMinutes) { next = choices[i]; break }
    } else {
      for (var j = 0; j < choices.length; j++) if (choices[j] > transitionMinutes) { next = choices[j]; break }
    }
    if (next !== transitionMinutes) persistSettings({ transitionMinutes: next })
  }

  function manualNow() {
    if (actualWarm) serviceCall(["daylight", "useDaylight"], [])
    else serviceCall(["warm", "useWarmth"], [])
  }

  function resumeAutomatic() {
    if (overridden) serviceCall(["resume", "resumeAutomatic"], [])
  }

  function retry() {
    serviceCall(["refresh", "retry"], [])
  }

  function open() {
    root.controller.show()
    root.focusIndex = 1
    Qt.callLater(function() {
      if (!root.opened) return
      root.setCenterHoverRevealSuppressed(true)
      if (root.serviceInitialized && root.stockChoicePending) root.showEditor("stock")
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    daylightTimeline.clearPin()
    cancelEditor(false)
    root.controller.hide()
  }

  // Native popout handoff can close through the inherited Panel path rather
  // than root.close(); every close path still drops ephemeral event detail.
  onOpenedChanged: if (!opened) daylightTimeline.clearPin()

  function toggle() { opened ? close() : open() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function setFocus(index) {
    focusIndex = Math.max(0, Math.min(6, index))
    scrollFocusedControl()
  }

  function moveFocus(dx, dy) {
    if (dy !== 0) setFocus((focusIndex + (dy > 0 ? 1 : 6)) % 7)
    else if (dx !== 0) adjustFocused(dx)
  }

  function adjustFocused(direction) {
    if (focusIndex === 0) daylightTimeline.moveSelection(direction)
    else if (focusIndex === 1) setAutomatic(direction > 0)
    else if (focusIndex === 2) stepWarmth(direction)
    else if (focusIndex === 3) stepTransition(direction)
  }

  function activateFocused() {
    if (focusIndex === 0) daylightTimeline.activateSelection()
    else if (focusIndex === 1) setAutomatic(!automaticEnabled)
    else if (focusIndex === 2) stepWarmth(1)
    else if (focusIndex === 3) stepTransition(1)
    else if (focusIndex === 4) {
      if (backendError || calculationError) retry()
      else if (overridden) resumeAutomatic()
      else manualNow()
    } else if (focusIndex === 5) showEditor("location")
    else showEditor("forget")
  }

  function scrollFocusedControl() {
    var item = null
    if (focusIndex === 0) item = daylightTimeline
    else if (focusIndex === 1) item = automaticRow
    else if (focusIndex === 2) item = warmthRow
    else if (focusIndex === 3) item = transitionRow
    else if (focusIndex === 4) item = primaryAction
    else if (focusIndex === 5) item = locationAction
    else item = forgetAction
    if (!item || !normalScroll) return
    Qt.callLater(function() {
      var point = item.mapToItem(normalColumn, 0, 0)
      normalScroll.contentY = Math.max(0, Math.min(normalScroll.contentHeight - normalScroll.height,
        point.y + item.height - normalScroll.height + Style.space(8)))
    })
  }

  function showEditor(mode) {
    var previousMode = editorMode
    animateEditorHeight = true
    editorMode = mode
    // Do not wait for the activeEditorColumn binding to propagate: the mode
    // setter's caller may read the fitted target in this same event turn.
    forceEditorLayout(mode)
    editorFocusIndex = 0
    resultIndex = 0
    if (editorScroll) editorScroll.contentY = 0
    if (previousMode === "normal" && mode !== "stock")
      serviceCall(["openLocationEditor", "beginLocationEdit"], [])
    reviewingAutoCandidate = false
    if (mode === "manual") {
      manualTouched = false
      manualSearchObservedBusy = false
      Qt.callLater(function() {
        manualField.text = ""
        manualField.forceActiveFocus()
      })
    } else {
      if (mode === "auto") autoSearchObservedBusy = false
      Qt.callLater(function() { editorKeys.forceActiveFocus() })
    }
  }

  function editorColumnForMode(mode) {
    if (mode === "location") return locationEditorColumn
    if (mode === "manual") return manualEditorColumn
    if (mode === "consent") return consentEditorColumn
    if (mode === "auto") return autoEditorColumn
    if (mode === "forget") return forgetEditorColumn
    if (mode === "stock") return stockEditorColumn
    return null
  }

  function forceEditorLayout(mode) {
    // Resolve from the mode value directly: activeEditorColumn's binding may
    // still expose the previous branch inside onEditorModeChanged.
    var activeColumn = editorColumnForMode(mode === undefined ? editorMode : mode)
    if (activeColumn) activeColumn.forceLayout()
    if (editorColumn) editorColumn.forceLayout()
  }

  onEditorModeChanged: {
    forceEditorLayout(editorMode)
    var switchedMode = editorMode
    Qt.callLater(function() {
      if (root.editorMode !== switchedMode) return
      root.forceEditorLayout()
      root.clampEditorScroll()
    })
  }

  function editorHeightSnapshot() {
    return {
      mode: editorMode,
      header: editorHeaderImplicitHeight,
      body: activeEditorImplicitHeight,
      outerSpacing: editorColumn ? editorColumn.spacing : 0,
      composition: editorCompositionImplicitHeight,
      verticalInset: panel ? panel.verticalContentInset : 0,
      target: targetPanelContentHeight,
      actual: panel ? panel.contentHeight : 0,
      viewport: editorScroll ? editorScroll.height : 0
    }
  }

  function cancelEditor(restoreFocus) {
    if (editorMode === "normal") return
    serviceCall(["closeLocationEditor", "cancelLocationEdit", "cancelLocationSearch", "cancelDraft"], [])
    animateEditorHeight = false
    panelHeightAnimation.stop()
    editorMode = "normal"
    manualTouched = false
    manualSearchObservedBusy = false
    autoSearchObservedBusy = false
    resultIndex = 0
    if (restoreFocus !== false) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function useWeather() {
    if (!weatherLocation) return
    serviceCall(["useWeatherLocation", "selectWeatherLocation"], [])
    cancelEditor(true)
  }

  function beginAutomatic() {
    if (autoConsentVersion >= 1) {
      showEditor("auto")
      serviceCall(["refreshAutomaticLocation", "autoLocate", "requestAutoLocation", "refreshAutoLocation"], [])
    } else showEditor("consent")
  }

  function continueAutomatic() {
    showEditor("auto")
    serviceCall(["consentAutomaticLocation", "consentAutoLocation", "continueAutoLocation", "autoLocate"], [1])
  }

  function manualInputEdited() {
    if (editorMode !== "manual") return
    manualTouched = true
    manualSearchObservedBusy = false
    resultIndex = 0
    serviceCall(["setManualQuery", "searchLocation", "updateManualQuery"], [manualField.text, Qt.locale().name])
  }

  function retryManualSearch() {
    manualSearchObservedBusy = false
    serviceCall(["setManualQuery", "searchLocation", "updateManualQuery"], [manualField.text, Qt.locale().name])
  }

  function commitManual() {
    var classification = LocationModel.classifyManualInput(manualField.text)
    if (classification.committable === true) {
      serviceCall(["commitManualCoordinates", "useManualCoordinates"], [manualField.text])
      cancelEditor(true)
      return
    }
    if (searchResults.length > 0 && resultIndex >= 0 && resultIndex < searchResults.length) {
      serviceCall(["commitManualLocation", "selectSearchResult", "commitSearchResult", "useManualCandidate"], [searchResults[resultIndex], resultIndex])
      cancelEditor(true)
    }
  }

  function acceptAutoCandidate() {
    if (!autoCandidate) return
    serviceCall(["acceptAutomaticCandidate", "acceptAutoCandidate", "useAutoLocation", "commitAutoLocation"], [autoCandidate])
    cancelEditor(true)
  }

  function keepCurrentAutoLocation() {
    serviceCall(["keepCurrentAutoLocation", "rejectAutomaticCandidate"], [])
    cancelEditor(true)
  }

  function reviewNewAutoLocation() {
    reviewingAutoCandidate = true
    editorFocusIndex = 0
  }

  function confirmForget() {
    serviceCall(["forgetLocation", "forgetLocationState"], ["confirm"])
    cancelEditor(true)
  }

  function currentIndicatorItems() {
    var defaults = ["Dictation", "ScreenRecording", "Reminder", "NightLight", "Dnd", "StayAwake"]
    var config = root.bar && root.bar.shell ? root.bar.shell.shellConfig : null
    var layout = config && config.bar && config.bar.layout ? config.bar.layout : null
    if (!layout) return defaults
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var entries = layout[sections[s]]
      if (!entries || typeof entries.length !== "number") continue
      for (var i = 0; i < entries.length; i++) {
        var entry = entries[i]
        if (!entry || String(entry.id || "") !== "omarchy.indicators") continue
        if (!entry.items || typeof entry.items.length !== "number" || entry.items.length === 0) return defaults
        var items = []
        for (var j = 0; j < entry.items.length; j++) items.push(entry.items[j])
        return items
      }
    }
    return defaults
  }

  function syncSettingsFromService() {
    var entry = serviceValue("inlineSettings", null)
    if (!entry) return
    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
  }

  function indicatorItemsContainNightLight(items) {
    for (var i = 0; i < items.length; i++) {
      var id = items[i] && typeof items[i] === "object" ? String(items[i].id || "") : String(items[i])
      if (id === "NightLight") return true
    }
    return false
  }

  function keepStock() {
    serviceCall(["keepStockIndicator", "chooseStockIndicator"], ["keep"])
    syncSettingsFromService()
    cancelEditor(true)
  }

  function hideStock() {
    serviceCall(["hideStockIndicator", "chooseStockIndicator"], [currentIndicatorItems()])
    syncSettingsFromService()
    cancelEditor(true)
  }

  function restoreStock() {
    serviceCall(["restoreStockIndicator"], [])
    syncSettingsFromService()
  }

  function editorControlCount() {
    if (editorMode === "location") return weatherLocation ? 5 : 4
    if (editorMode === "manual") return Math.max(2, searchResults.length + 2 + (manualRetryVisible ? 1 : 0))
    if (editorMode === "consent" || editorMode === "forget" || editorMode === "stock") return 2
    if (editorMode === "auto") return autoCandidate || autoRetryVisible ? 2 : 1
    return 1
  }

  function editorItemForIndex(item, index) {
    if (!item || item.visible === false) return null
    if ("editorIndex" in item && item.editorIndex === index) return item
    var children = item.children || []
    for (var i = 0; i < children.length; i++) {
      var match = editorItemForIndex(children[i], index)
      if (match) return match
    }
    return null
  }

  function scrollFocusedEditorControl() {
    if (!editorScroll || !editorColumn) return
    var item = editorMode === "manual" && editorFocusIndex === 0
      ? manualField : editorItemForIndex(editorColumn, editorFocusIndex)
    if (!item) return
    Qt.callLater(function() {
      if (!item || !editorScroll || !editorColumn) return
      var point = item.mapToItem(editorColumn, 0, 0)
      var margin = Style.space(8)
      var top = editorScroll.contentY
      var bottom = top + editorScroll.height
      if (point.y < top + margin) editorScroll.contentY = Math.max(0, point.y - margin)
      else if (point.y + item.height > bottom - margin)
        editorScroll.contentY = Math.min(Math.max(0, editorScroll.contentHeight - editorScroll.height),
          point.y + item.height - editorScroll.height + margin)
    })
  }

  function clampEditorScroll() {
    if (!editorScroll) return
    editorScroll.contentY = Math.max(0, Math.min(editorScroll.contentY,
      Math.max(0, editorScroll.contentHeight - editorScroll.height)))
  }

  function editorTab(direction) {
    var count = editorControlCount()
    editorFocusIndex = (editorFocusIndex + (direction > 0 ? 1 : count - 1)) % count
    if (editorMode === "manual" && editorFocusIndex === 0) manualField.forceActiveFocus()
    else editorKeys.forceActiveFocus()
    scrollFocusedEditorControl()
  }

  function moveEditor(dx, dy) {
    if (editorMode === "manual" && dy !== 0 && searchResults.length > 0) {
      resultIndex = Math.max(0, Math.min(searchResults.length - 1, resultIndex + (dy > 0 ? 1 : -1)))
      editorFocusIndex = Math.min(resultIndex + 1, editorControlCount() - 2)
      editorKeys.forceActiveFocus()
      scrollFocusedEditorControl()
      return
    }
    if (dy !== 0 || dx !== 0) editorTab((dy !== 0 ? dy : dx) > 0 ? 1 : -1)
  }

  // PanelKeyCatcher reserves vim's `l` for rightward adjustment before its
  // textKey signal can fire. Night Light promises `l` for Location instead,
  // so normal mode owns its small key map and leaves h/l out of value changes.
  function handleNormalKey(event) {
    if (event.key === Qt.Key_Escape) root.close()
    else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab)
      root.switchPanel((event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_Backtab ? -1 : 1)
    else if (event.key === Qt.Key_Down || event.text === "j") root.moveFocus(0, 1)
    else if (event.key === Qt.Key_Up || event.text === "k") root.moveFocus(0, -1)
    else if (event.key === Qt.Key_Right) root.moveFocus(1, 0)
    else if (event.key === Qt.Key_Left) root.moveFocus(-1, 0)
    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space)
      root.activateFocused()
    else if (event.key === Qt.Key_Delete || event.text === "x" || event.text === "X") root.showEditor("forget")
    else if (event.text === "n" || event.text === "N") root.manualNow()
    else if (event.text === "a" || event.text === "A") root.resumeAutomatic()
    else if (event.text === "l" || event.text === "L") root.showEditor("location")
    else return
    event.accepted = true
  }

  function activateEditor() {
    if (editorMode === "location") {
      var offset = 0
      if (weatherLocation) {
        if (editorFocusIndex === 0) { useWeather(); return }
        offset = 1
      }
      if (editorFocusIndex === offset) beginAutomatic()
      else if (editorFocusIndex === offset + 1) showEditor("manual")
      else if (editorFocusIndex === offset + 2) restoreStock()
      else cancelEditor(true)
    } else if (editorMode === "manual") {
      if (editorFocusIndex === editorControlCount() - 1) cancelEditor(true)
      else if (manualRetryVisible && editorFocusIndex === searchResults.length + 1) retryManualSearch()
      else commitManual()
    } else if (editorMode === "consent") {
      if (editorFocusIndex === 0) cancelEditor(true); else continueAutomatic()
    } else if (editorMode === "auto") {
      if (autoLocationChanged && !reviewingAutoCandidate) {
        if (editorFocusIndex === 0) keepCurrentAutoLocation(); else reviewNewAutoLocation()
      } else if (autoCandidate) {
        if (editorFocusIndex === 0) acceptAutoCandidate(); else cancelEditor(true)
      } else if (autoRetryVisible) {
        if (editorFocusIndex === 0) serviceCall(["refreshAutomaticLocation", "autoLocate", "requestAutoLocation"], [])
        else cancelEditor(true)
      } else cancelEditor(true)
    } else if (editorMode === "forget") {
      if (editorFocusIndex === 0) cancelEditor(true); else confirmForget()
    } else if (editorMode === "stock") {
      if (editorFocusIndex === 0) keepStock(); else hideStock()
    }
  }

  Connections {
    target: root.nightLightService
    enabled: root.nightLightService !== null
    ignoreUnknownSignals: true
    function onBusyChanged() {
      if (!root.nightLightService || root.nightLightService.busy !== true) return
      if (root.editorMode === "manual") root.manualSearchObservedBusy = true
      else if (root.editorMode === "auto") root.autoSearchObservedBusy = true
    }
    function onInitializedChanged() {
      if (root.opened && root.editorMode === "normal" && root.serviceInitialized && root.stockChoicePending)
        root.showEditor("stock")
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    // KeyboardPanel's installed edge-aware mode centers the card on this
    // actual WidgetButton, then clamps it to the anchor screen.
    centerOnBar: false
    focusTarget: root.editorMode === "normal" ? keyCatcher : editorKeys
    contentWidth: panel.fittedContentWidth(root.nominalContentWidth)
    contentHeight: root.targetPanelContentHeight

    // Only the lower card edge moves on the common top-bar layout; content
    // remains top-aligned, so controls do not reflow underneath the pointer.
    // The Flickables below keep every mode usable while this is capped on a
    // short display.
    Behavior on contentHeight {
      // Editor contraction is visible; returning to the taller dashboard is
      // immediate and its existing cross-fade prevents partially clipped rows.
      enabled: root.opened && root.animateEditorHeight
      NumberAnimation { id: panelHeightAnimation; duration: 140; easing.type: Easing.OutCubic }
    }

    // PanelKeyCatcher reserves l for movement, so this panel uses a direct
    // focus owner to keep its documented Location shortcut unambiguous.
    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (root.editorMode === "normal") root.handleNormalKey(event)
      }

      // Both normal content and every editor occupy the same fitted viewport.
      Item {
        anchors.fill: parent

        Flickable {
          id: normalScroll
          anchors.fill: parent
          visible: opacity > 0
          enabled: root.editorMode === "normal"
          opacity: root.editorMode === "normal" ? 1 : 0
          contentWidth: width
          contentHeight: Math.max(height, normalColumn.implicitHeight)
          clip: true
          interactive: contentHeight > height
          boundsBehavior: Flickable.StopAtBounds

          Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

          Column {
            id: normalColumn
            width: normalScroll.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              height: Style.space(72)

              OpticalGlyph {
                id: heroIcon
                width: Style.space(58)
                height: Style.space(58)
                anchors.left: parent.left
                anchors.leftMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: root.heroGlyph
                fontFamily: root.contentFontFamily
                fontSize: Style.space(42)
                color: root.contentForeground
              }

              Column {
                anchors.left: heroIcon.right
                anchors.leftMargin: Style.space(16)
                anchors.right: parent.right
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(4)

                Text {
                  width: parent.width
                  text: root.stateTitle
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.display
                  font.bold: true
                  elide: Text.ElideRight
                }

                Text {
                  width: parent.width
                  text: root.stateDetail
                  color: root.dimForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }
              }
            }

            Item {
              id: sourceRow
              width: parent.width
              height: Style.space(26)

              Text {
                id: locationLabel
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, Math.max(0, parent.width - (sourceText.visible ? sourceText.implicitWidth + Style.space(8) : 0)))
                text: root.locationState && root.locationState.label ? String(root.locationState.label) : (root.runtimeMode === "setup" ? "No schedule location" : "Schedule location unavailable")
                color: root.dimForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }

              Text {
                id: sourceText
                anchors.left: locationLabel.right
                anchors.leftMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                visible: root.locationState !== null
                text: "via " + root.sourceBadge
                color: root.dimForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.italic: true
              }
            }

            DaylightTimeline {
              id: daylightTimeline
              width: parent.width
              snapshot: root.timelineSnapshot
              moonPhase: root.moonPhaseSnapshot
              current: root.focusIndex === 0
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              onFocusRequested: root.setFocus(0)
            }

            ControlRow {
              id: automaticRow
              controlIndex: 1
              label: "AUTOMATIC"
              valueText: root.automaticEnabled ? "On" : "Paused"
              description: root.automaticEnabled ? "Follows sunset and sunrise" : "Scheduled writes are paused"
              showAdjusters: false
              onActivated: root.setAutomatic(!root.automaticEnabled)
            }

            ControlRow {
              id: warmthRow
              controlIndex: 2
              label: "WARMTH"
              valueText: root.nightTemperature + " K"
              description: "Saved automatically · Live during automatic warmth"
              decreaseName: "Decrease night warmth"
              increaseName: "Increase night warmth"
              onDecreased: root.stepWarmth(-1)
              onIncreased: root.stepWarmth(1)
              onActivated: root.stepWarmth(1)
            }

            ControlRow {
              id: transitionRow
              controlIndex: 3
              label: "TRANSITION"
              valueText: root.transitionLabel(root.transitionMinutes)
              description: "At both horizon boundaries"
              decreaseName: "Shorter transition"
              increaseName: "Longer transition"
              onDecreased: root.stepTransition(-1)
              onIncreased: root.stepTransition(1)
              onActivated: root.stepTransition(1)
            }

            ActionRow {
              id: primaryAction
              controlIndex: 4
              iconText: root.backendError || root.calculationError ? "󰑐" : (root.overridden ? "󰑓" : (root.actualWarm ? "󰖙" : "󰖔"))
              label: root.backendError || root.calculationError ? "Retry" : (root.overridden ? "Resume automatic" : (root.actualWarm ? "Use daylight" : "Warm now"))
              detail: root.busy ? "Working…" : (root.overridden ? "Return to the calculated schedule" : "Manual until the next solar boundary")
              onActivated: root.activateFocusedAction()
            }

            Row {
              width: parent.width
              height: Style.space(42)
              spacing: Style.space(8)

              ActionRow {
                id: locationAction
                width: parent.width - forgetAction.width - parent.spacing
                height: parent.height
                controlIndex: 5
                iconText: "󰍎"
                label: root.runtimeMode === "setup" ? "Choose location" : "Change location"
                detail: ""
                onActivated: root.showEditor("location")
              }

              PanelActionButton {
                id: forgetAction
                width: Math.max(Style.space(42), implicitWidth)
                height: parent.height
                size: Math.max(Style.space(32), Style.spacing.controlHeight)
                iconText: "󰩺"
                tooltipText: "Forget Night Light location"
                foreground: root.contentForeground
                hoverColor: root.contentUrgent
                hasCursor: root.focusIndex === 6
                Accessible.name: "Forget Night Light location"
                Accessible.role: Accessible.Button
                onHovered: function(hovered) { if (hovered) root.setFocus(6) }
                onClicked: root.showEditor("forget")
              }
            }
          }
        }

        Item {
          id: editorView
          anchors.fill: parent
          visible: opacity > 0
          enabled: root.editorMode !== "normal"
          opacity: root.editorMode === "normal" ? 0 : 1
          Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

          Item {
            id: editorKeys
            anchors.fill: parent
            focus: true
            Keys.priority: Keys.BeforeItem
            Keys.onPressed: function(event) {
              if (root.editorMode === "manual" && manualField.activeFocus) {
                if (event.key === Qt.Key_Escape) {
                  root.cancelEditor(true); event.accepted = true
                } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                  root.editorTab((event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_Backtab ? -1 : 1)
                  event.accepted = true
                } else if (event.key === Qt.Key_Down) {
                  root.moveEditor(0, 1); event.accepted = true
                } else if (event.key === Qt.Key_Up) {
                  root.moveEditor(0, -1); event.accepted = true
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  root.commitManual(); event.accepted = true
                }
                return
              }
              if (event.key === Qt.Key_Escape) {
                root.cancelEditor(true); event.accepted = true
              } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                root.editorTab((event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_Backtab ? -1 : 1)
                event.accepted = true
              } else if (event.key === Qt.Key_Down || event.text === "j") {
                root.moveEditor(0, 1); event.accepted = true
              } else if (event.key === Qt.Key_Up || event.text === "k") {
                root.moveEditor(0, -1); event.accepted = true
              } else if (event.key === Qt.Key_Left || event.text === "h") {
                root.moveEditor(-1, 0); event.accepted = true
              } else if (event.key === Qt.Key_Right || event.text === "l") {
                root.moveEditor(1, 0); event.accepted = true
              } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                root.activateEditor(); event.accepted = true
              }
            }

            Flickable {
              id: editorScroll
              anchors.fill: parent
              contentWidth: width
              contentHeight: Math.max(height, editorColumn.implicitHeight)
              clip: true
              interactive: contentHeight > height
              boundsBehavior: Flickable.StopAtBounds
              onHeightChanged: root.clampEditorScroll()
              onContentHeightChanged: root.clampEditorScroll()

              Column {
                id: editorColumn
                width: parent.width
                // Keep editor controls fixed in screen space while the card
                // contracts: top bars hold the top edge, bottom bars hold the
                // bottom edge, and side bars hold the vertical center.
                y: {
                  var slack = Math.max(0, editorScroll.height - implicitHeight)
                  if (panel.barPos === "bottom") return slack
                  if (panel.barPos === "left" || panel.barPos === "right") return slack / 2
                  return 0
                }
                spacing: Style.space(10)

                Text {
                  id: editorTitleLabel
                  width: parent.width
                  text: root.editorTitle()
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.display
                  font.bold: true
                  wrapMode: Text.WordWrap
                }

                Text {
                  id: editorDetailLabel
                  width: parent.width
                  text: root.editorDetail()
                  color: root.dimForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                  wrapMode: Text.WordWrap
                }

                PanelSeparator {
                  id: editorSeparator
                  foreground: root.contentForeground
                }

                Column {
                  id: locationEditorColumn
                  visible: root.editorMode === "location"
                  width: parent.width
                  spacing: Style.space(6)

                  EditorAction {
                    visible: !!root.weatherLocation
                    editorIndex: 0
                    iconText: "󰖐"
                    label: "Use Weather location"
                    detail: root.weatherLocation && root.weatherLocation.label ? String(root.weatherLocation.label) : "Last valid Weather location"
                    onActivated: root.useWeather()
                  }

                  EditorAction {
                    editorIndex: root.weatherLocation ? 1 : 0
                    iconText: "󰑐"
                    label: "Automatic (approximate)"
                    detail: "Uses your public IP after you confirm"
                    onActivated: root.beginAutomatic()
                  }

                  EditorAction {
                    editorIndex: root.weatherLocation ? 2 : 1
                    iconText: "󰍎"
                    label: "Manual location"
                    detail: "Search a locality or enter coordinates"
                    onActivated: root.showEditor("manual")
                  }

                  EditorAction {
                    editorIndex: root.weatherLocation ? 3 : 2
                    iconText: "󰑓"
                    label: "Restore stock shortcut"
                    detail: "Only restores an unchanged Indicators setup"
                    onActivated: root.restoreStock()
                  }

                  EditorAction {
                    editorIndex: root.weatherLocation ? 4 : 3
                    iconText: "󰅖"
                    label: "Cancel"
                    detail: ""
                    onActivated: root.cancelEditor(true)
                  }
                }

                Column {
                  id: manualEditorColumn
                  visible: root.editorMode === "manual"
                  width: parent.width
                  spacing: Style.space(7)

                  TextField {
                    id: manualField
                    width: parent.width
                    height: Math.max(Style.space(36), implicitHeight)
                    placeholderText: "City or 52.27115, 5.13729"
                    foreground: root.contentForeground
                    accent: Color.accent
                    font.family: root.contentFontFamily
                    hasCursor: root.editorFocusIndex === 0
                    Accessible.name: "Manual location"
                    Accessible.description: "Search a locality or enter decimal latitude and longitude"
                    onTextEdited: root.manualInputEdited()
                  }

                  Text {
                    width: parent.width
                    text: "Search uses Open-Meteo only while this editor is open."
                    color: root.dimForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }

                  Text {
                    visible: text !== ""
                    width: parent.width
                    text: root.manualStatusText()
                    color: root.searchState === "error" || root.searchState === "rate-limited" ? root.contentUrgent : root.dimForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.WordWrap
                  }

                  Repeater {
                    model: Math.min(5, root.searchResults.length)

                    EditorAction {
                      required property int index
                      readonly property var candidate: root.searchResults[index]
                      editorIndex: index + 1
                      iconText: "󰍎"
                      label: root.candidateLabel(candidate)
                      detail: ""
                      active: root.resultIndex === index
                      onHovered: function(hovered) { if (hovered) root.resultIndex = index }
                      onActivated: {
                        root.resultIndex = index
                        root.commitManual()
                      }
                    }
                  }

                  EditorAction {
                    visible: root.manualRetryVisible
                    editorIndex: root.searchResults.length + 1
                    iconText: "󰑐"
                    label: "Retry search"
                    detail: "Try the current query again"
                    onActivated: root.retryManualSearch()
                  }

                  EditorAction {
                    editorIndex: root.editorControlCount() - 1
                    iconText: "󰅖"
                    label: "Cancel"
                    detail: ""
                    onActivated: root.cancelEditor(true)
                  }
                }

                Column {
                  id: consentEditorColumn
                  visible: root.editorMode === "consent"
                  width: parent.width
                  spacing: Style.space(10)

                  Text {
                    width: parent.width
                    text: "Night Light will contact wttr.in. The provider sees your public IP and returns an approximate city. No IP address or response history is saved."
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                    wrapMode: Text.WordWrap
                  }

                  EditorAction { editorIndex: 0; iconText: "󰅖"; label: "Cancel"; detail: ""; onActivated: root.cancelEditor(true) }
                  EditorAction { editorIndex: 1; iconText: "󰄬"; label: "Continue"; detail: "Contact wttr.in once"; onActivated: root.continueAutomatic() }
                }

                Column {
                  id: autoEditorColumn
                  visible: root.editorMode === "auto"
                  width: parent.width
                  spacing: Style.space(8)

                  BorderSurface {
                    visible: !!root.autoCandidate
                    width: parent.width
                    implicitHeight: autoCandidateColumn.implicitHeight + Style.space(20)
                    color: Style.normalFillFor(root.contentForeground, Color.accent)
                    borderSpec: Border.controlSpec("normal", root.contentForeground, Color.accent)
                    radius: Style.cornerRadius

                    Column {
                      id: autoCandidateColumn
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      anchors.margins: Style.space(10)
                      spacing: Style.space(4)
                      Text { text: "APPROXIMATE"; color: root.dimForeground; font.family: root.contentFontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                      Text { width: parent.width; text: root.autoCandidate && root.autoCandidate.label ? String(root.autoCandidate.label) : "Approximate location"; color: root.contentForeground; font.family: root.contentFontFamily; font.pixelSize: Style.font.title; font.bold: true; elide: Text.ElideRight }
                      Text { width: parent.width; text: "This may be wrong when using a VPN or proxy."; color: root.dimForeground; font.family: root.contentFontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap }
                    }
                  }

                  Text {
                    visible: !root.autoCandidate
                    width: parent.width
                    text: root.autoStatusText()
                    color: root.searchState === "error" || root.searchState === "rate-limited" ? root.contentUrgent : root.dimForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                    wrapMode: Text.WordWrap
                  }

                  EditorAction { visible: root.autoLocationChanged && !root.reviewingAutoCandidate; editorIndex: 0; iconText: "󰐃"; label: "Keep current"; detail: "Do not replace the accepted location"; onActivated: root.keepCurrentAutoLocation() }
                  EditorAction { visible: root.autoLocationChanged && !root.reviewingAutoCandidate; editorIndex: 1; iconText: "󰍎"; label: "Review new location"; detail: "Compare the approximate candidate"; onActivated: root.reviewNewAutoLocation() }
                  EditorAction { visible: !!root.autoCandidate && (!root.autoLocationChanged || root.reviewingAutoCandidate); editorIndex: 0; iconText: "󰄬"; label: "Use this location"; detail: "Approximate"; onActivated: root.acceptAutoCandidate() }
                  EditorAction { visible: root.autoRetryVisible; editorIndex: 0; iconText: "󰑐"; label: "Retry"; detail: "Request another approximate result"; onActivated: root.serviceCall(["refreshAutomaticLocation", "autoLocate", "requestAutoLocation"], []) }
                  EditorAction { visible: !root.autoLocationChanged || root.reviewingAutoCandidate; editorIndex: root.autoCandidate || root.autoRetryVisible ? 1 : 0; iconText: "󰅖"; label: "Cancel"; detail: ""; onActivated: root.cancelEditor(true) }
                }

                Column {
                  id: forgetEditorColumn
                  visible: root.editorMode === "forget"
                  width: parent.width
                  spacing: Style.space(10)

                  Text {
                    width: parent.width
                    text: "Removes Night Light’s saved location and consent. Omarchy Weather is unchanged."
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                    wrapMode: Text.WordWrap
                  }

                  EditorAction { editorIndex: 0; iconText: "󰅖"; label: "Cancel"; detail: "Keep the current schedule location"; onActivated: root.cancelEditor(true) }
                  EditorAction { editorIndex: 1; iconText: "󰩺"; label: "Forget"; detail: "Leave the current display setting unchanged"; urgent: true; onActivated: root.confirmForget() }
                }

                Column {
                  id: stockEditorColumn
                  visible: root.editorMode === "stock"
                  width: parent.width
                  spacing: Style.space(10)

                  Text {
                    width: parent.width
                    text: "Omarchy’s stock shortcut can stay, but it may show an older state. Hide it and use this panel as the source of truth?"
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                    wrapMode: Text.WordWrap
                  }

                  EditorAction { editorIndex: 0; iconText: "󰐃"; label: "Keep both"; detail: "Make no change to Indicators"; onActivated: root.keepStock() }
                  EditorAction { editorIndex: 1; iconText: "󰈉"; label: "Hide stock shortcut"; detail: "The first-party service stays enabled"; onActivated: root.hideStock() }
                }
              }
            }
          }
        }
      }
    }
  }

  function activateFocusedAction() {
    if (backendError || calculationError) retry()
    else if (overridden) resumeAutomatic()
    else manualNow()
  }

  function candidateLabel(candidate) {
    if (!candidate) return "Unknown locality"
    var parts = []
    if (candidate.label || candidate.name) parts.push(String(candidate.label || candidate.name))
    if (candidate.admin1) parts.push(String(candidate.admin1))
    if (candidate.country) parts.push(String(candidate.country))
    return parts.join(" · ")
  }

  function manualStatusText() {
    var classification = LocationModel.classifyManualInput(manualField.text)
    if (classification.outcome === "coordinates") return "Coordinates are valid. Press Enter to use them."
    if (classification.outcome === "invalid-coordinates") return classification.error ? classification.error.message : "Enter valid coordinates."
    if (!manualTouched || classification.outcome === "empty") return ""
    if (classification.outcome === "query-too-short") return "Enter at least three non-space characters."
    if (searchState === "loading" || searchState === "searching") return "Searching…"
    if (searchState === "rate-limited" || (searchError && searchError.code === "rate-limited")) return "Search is temporarily rate limited. Try again later."
    if (searchState === "error" || searchState === "offline") return "Couldn’t search. Check your connection and try again."
    if ((searchState === "empty" || searchState === "done" || searchState === "ready" || manualSearchObservedBusy) && searchResults.length === 0) return "No matching localities."
    return ""
  }

  function autoStatusText() {
    if (searchState === "loading" || searchState === "locating") return "Finding an approximate location…"
    if (searchState === "rate-limited" || (searchError && searchError.code === "rate-limited")) return "Automatic location is temporarily rate limited. Try again later."
    if (searchState === "error" || searchState === "offline") return "Couldn’t find an approximate location. Check your connection and try again."
    return autoSearchObservedBusy ? "No approximate location was returned." : "Waiting to request an approximate location…"
  }

  function editorTitle() {
    if (editorMode === "location") return "Location"
    if (editorMode === "manual") return "Manual location"
    if (editorMode === "consent") return "Use approximate location?"
    if (editorMode === "auto") return autoLocationChanged && !reviewingAutoCandidate ? "Approximate location changed" : (autoCandidate ? "Review approximate location" : "Approximate location")
    if (editorMode === "forget") return "Forget Night Light location?"
    if (editorMode === "stock") return "One Night Light shortcut"
    return "Night Light"
  }

  function editorDetail() {
    if (editorMode === "location") return "Choose where sunrise and sunset are calculated."
    if (editorMode === "manual") return "Free text must match a result; decimal coordinates work offline."
    if (editorMode === "consent") return "Night Light contacts wttr.in only after you continue."
    if (editorMode === "auto") return "Every automatic result is approximate and must be reviewed."
    if (editorMode === "forget") return "This does not change Omarchy Weather."
    if (editorMode === "stock") return "Choose which shortcut should represent Night Light."
    return ""
  }

  component ControlRow: CursorSurface {
    id: control
    required property int controlIndex
    required property string label
    required property string valueText
    property string description: ""
    property bool showAdjusters: true
    property string decreaseName: "Decrease value"
    property string increaseName: "Increase value"
    signal activated()
    signal decreased()
    signal increased()

    width: parent ? parent.width : Style.space(480)
    height: Style.space(44)
    hasCursor: root.focusIndex === controlIndex
    foreground: root.contentForeground
    accent: Color.accent
    Accessible.name: label + ", " + valueText
    Accessible.description: description
    Accessible.role: Accessible.Button
    Accessible.onPressAction: control.activated()

    HoverHandler { onHoveredChanged: if (hovered) root.setFocus(control.controlIndex) }

    MouseArea {
      anchors.left: parent.left
      anchors.right: decrementButton.visible ? decrementButton.left : parent.right
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      cursorShape: Qt.PointingHandCursor
      onClicked: control.activated()
    }

    Column {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      width: Math.max(1, parent.width - valueLabel.width - (control.showAdjusters ? Style.space(92) : Style.space(28)))
      spacing: Style.space(1)
      Text { text: control.label; color: root.dimForeground; font.family: root.contentFontFamily; font.pixelSize: Style.font.caption; font.bold: true; font.letterSpacing: 1 }
      Text { width: parent.width; visible: control.description !== ""; text: control.description; color: root.contentForeground; font.family: root.contentFontFamily; font.pixelSize: Style.font.bodySmall; elide: Text.ElideRight }
    }

    Text {
      id: valueLabel
      anchors.right: control.showAdjusters ? decrementButton.left : parent.right
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      text: control.valueText
      color: root.contentForeground
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.title
      font.bold: true
      Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
    }

    PanelActionButton {
      id: decrementButton
      visible: control.showAdjusters
      anchors.right: incrementButton.left
      anchors.rightMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      size: Math.max(Style.space(28), Style.spacing.controlHeight)
      iconText: "−"
      tooltipText: control.decreaseName
      foreground: root.contentForeground
      Accessible.name: control.decreaseName
      Accessible.role: Accessible.Button
      onClicked: control.decreased()
    }

    PanelActionButton {
      id: incrementButton
      visible: control.showAdjusters
      anchors.right: parent.right
      anchors.rightMargin: Style.space(5)
      anchors.verticalCenter: parent.verticalCenter
      size: Math.max(Style.space(28), Style.spacing.controlHeight)
      iconText: "+"
      tooltipText: control.increaseName
      foreground: root.contentForeground
      Accessible.name: control.increaseName
      Accessible.role: Accessible.Button
      onClicked: control.increased()
    }
  }

  component ActionRow: CursorSurface {
    id: action
    required property int controlIndex
    required property string iconText
    required property string label
    property string detail: ""
    signal activated()

    width: parent ? parent.width : Style.space(480)
    height: Style.space(40)
    hasCursor: root.focusIndex === controlIndex
    foreground: root.contentForeground
    accent: Color.accent
    Accessible.name: label
    Accessible.description: detail
    Accessible.role: Accessible.Button
    Accessible.onPressAction: action.activated()

    HoverHandler { onHoveredChanged: if (hovered) root.setFocus(action.controlIndex) }
    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: action.activated() }

    OpticalGlyph { anchors.left: parent.left; anchors.leftMargin: Style.space(10); anchors.verticalCenter: parent.verticalCenter; width: Style.space(24); height: width; text: action.iconText; fontFamily: root.contentFontFamily; fontSize: Style.font.title; color: root.contentForeground }
    Text { anchors.left: parent.left; anchors.leftMargin: Style.space(44); anchors.verticalCenter: parent.verticalCenter; text: action.label; color: root.contentForeground; font.family: root.contentFontFamily; font.pixelSize: Style.font.body; font.bold: true }
    Text { visible: action.detail !== ""; anchors.right: parent.right; anchors.rightMargin: Style.space(10); anchors.verticalCenter: parent.verticalCenter; width: Math.min(implicitWidth, Style.space(235)); text: action.detail; color: root.dimForeground; font.family: root.contentFontFamily; font.pixelSize: Style.font.caption; elide: Text.ElideRight; horizontalAlignment: Text.AlignRight }
  }

  component EditorAction: CursorSurface {
    id: editorAction
    required property int editorIndex
    required property string iconText
    required property string label
    property string detail: ""
    property bool urgent: false
    property bool active: false
    signal activated()
    signal hovered(bool hovered)

    width: parent ? parent.width : Style.space(480)
    height: Style.space(48)
    hasCursor: root.editorFocusIndex === editorIndex
    current: active
    foreground: urgent ? root.contentUrgent : root.contentForeground
    accent: urgent ? root.contentUrgent : Color.accent
    Accessible.name: label
    Accessible.description: detail
    Accessible.role: Accessible.Button
    Accessible.onPressAction: editorAction.activated()

    HoverHandler {
      onHoveredChanged: {
        if (hovered) root.editorFocusIndex = editorAction.editorIndex
        editorAction.hovered(hovered)
      }
    }
    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: editorAction.activated() }

    OpticalGlyph { anchors.left: parent.left; anchors.leftMargin: Style.space(10); anchors.verticalCenter: parent.verticalCenter; width: Style.space(24); height: width; text: editorAction.iconText; fontFamily: root.contentFontFamily; fontSize: Style.font.title; color: editorAction.foreground }
    Column { anchors.left: parent.left; anchors.leftMargin: Style.space(46); anchors.right: parent.right; anchors.rightMargin: Style.space(10); anchors.verticalCenter: parent.verticalCenter; spacing: Style.space(2)
      Text { width: parent.width; text: editorAction.label; color: editorAction.foreground; font.family: root.contentFontFamily; font.pixelSize: Style.font.body; font.bold: true; elide: Text.ElideRight }
      Text { visible: editorAction.detail !== ""; width: parent.width; text: editorAction.detail; color: root.dimForeground; font.family: root.contentFontFamily; font.pixelSize: Style.font.caption; elide: Text.ElideRight }
    }
  }
}
