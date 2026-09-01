import QtQuick
import qs.Commons
import qs.Ui

// Stable bar affordance and Clock-style owner for the nested Night Light panel.
// Scheduling, location policy, persistence and backend I/O belong to Service.qml.
BarWidget {
  id: root
  moduleName: "jgordijn.night-light"

  readonly property var nightLightService: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor("jgordijn.night-light") : null
  readonly property var nestedPanel: panelLoader.item

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

  readonly property bool serviceInitialized: nightLightService ? serviceValue("initialized", true) === true : false
  readonly property string runtimeMode: serviceInitialized ? String(serviceValue("mode", "setup")) : "loading"
  readonly property string phase: String(serviceValue("phase", "error"))
  readonly property bool overridden: runtimeMode === "override" || Number(serviceValue("overrideUntil", 0)) > 0
  readonly property bool available: serviceValue("available", false) === true
  readonly property var errorState: serviceValue("error", null)
  readonly property var actualState: serviceValue("actual", null)
  readonly property var locationState: serviceValue("location", null)
  readonly property int configuredNightTemperature: {
    var local = root.settings ? root.settings.nightTemperature : undefined
    var localNumber = Number(local)
    if (typeof local === "number" && isFinite(localNumber) && Math.floor(localNumber) === localNumber && localNumber >= 1000 && localNumber <= 6500)
      return localNumber
    var serviceNumber = Number(serviceValue("nightTemperature", 4000))
    return isFinite(serviceNumber) && Math.floor(serviceNumber) === serviceNumber && serviceNumber >= 1000 && serviceNumber <= 6500 ? serviceNumber : 4000
  }
  readonly property int actualTemperature: {
    var actual = root.actualState
    var value = actual && Number(actual.temperature)
    return isFinite(value) && value >= 1000 && value <= 6500 ? Math.round(value) : 6500
  }
  readonly property bool actualWarm: actualState && String(actualState.kind) === "temperature" && actualTemperature < 6500
  readonly property bool setupState: runtimeMode === "setup"
  readonly property bool loadingState: runtimeMode === "loading"
  readonly property string errorCode: errorState && errorState.code ? String(errorState.code) : ""
  readonly property bool fatalError: errorCode === "backend-unavailable" || errorCode === "apply-failed" ||
    errorCode === "calculation-failed" || errorCode === "state-malformed" || errorCode === "state-unsupported-schema"
  readonly property bool errorDisplay: !loadingState && ((!available && serviceInitialized) || fatalError || phase === "error")
  readonly property bool transitionState: phase === "evening-transition" || phase === "morning-transition"
  readonly property bool nightState: phase === "night" || phase === "polar-night"
  readonly property bool dayState: phase === "day" || phase === "polar-day"
  readonly property bool displayedDaylight: overridden ? !actualWarm : dayState
  readonly property int displayedTemperature: overridden ? actualTemperature : (transitionState ? actualTemperature : configuredNightTemperature)

  function compactKelvin(value) {
    var k = Math.max(1000, Math.min(6500, Number(value) || 6500)) / 1000
    return k.toLocaleString(Qt.locale(), "f", 1) + "k"
  }

  function formatTime(epoch) {
    var value = Number(epoch)
    return isFinite(value) && value > 0 ? Qt.formatTime(new Date(value), Qt.locale().timeFormat(Locale.ShortFormat)) : "—"
  }

  readonly property string barGlyph: loadingState ? "󰔟" : (setupState ? "󰍎" : (errorDisplay ? "󰀪" : (displayedDaylight ? "󰖙" : "󰖔")))
  readonly property string barLabel: loadingState ? "…" : (setupState ? "SET" : (errorDisplay ? "ERR" : (displayedDaylight ? "DAY" : compactKelvin(displayedTemperature))))
  readonly property string plainState: {
    if (loadingState) return "Night Light is loading"
    if (setupState) return "Choose a location"
    if (errorDisplay) return "Night Light is unavailable"
    if (overridden) return actualWarm ? "Manual warm override" : "Manual daylight override"
    if (phase === "evening-transition") return "Night Light is warming the display"
    if (phase === "morning-transition") return "Night Light is returning to daylight"
    if (nightState) return phase === "polar-night" ? "Polar night" : "Night light is active"
    return phase === "polar-day" ? "Midnight sun" : "Daylight"
  }
  readonly property string nextLine: {
    if (loadingState) return "Waiting for the scheduler service"
    if (setupState) return "Location is needed only for sunrise and sunset"
    var location = root.locationState
    var source = location && location.label ? String(location.label) : "Location unavailable"
    var boundary = Number(serviceValue("nextBoundary", 0))
    if (boundary > 0) {
      var nextName = (phase === "night" || phase === "morning-transition" || phase === "polar-night") ? "Sunrise" : "Sunset"
      return (overridden ? "Automatic resumes at " : nextName + " at ") + formatTime(boundary) + (overridden ? "" : " · Automatic is active")
    }
    return source + (overridden ? "" : " · Automatic is active")
  }
  readonly property string tooltipText: plainState + "\n" + nextLine

  // Bar.findPanelWidget and Bar.requestPopout identify this root, not Panel.qml.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  function toggleManual() {
    if (root.actualWarm) root.serviceCall(["daylight", "useDaylight"], [])
    else root.serviceCall(["warm", "useWarmth"], [])
  }

  function resumeAutomatic() {
    if (root.overridden) root.serviceCall(["resume", "resumeAutomatic"], [])
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  // Match Clock's painted-label mark horizontally and one icon slot vertically.
  readonly property real openPanelIndicatorWidth: button.labelWidth > 0 ? button.labelWidth : Style.space(54)
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.vertical ? "" : root.barLabel
    labelVisible: false
    hasVisualContent: true
    fixedWidth: root.vertical ? -1 : Style.space(76)
    fixedHeight: root.vertical ? Style.bar.iconSlot : -1
    horizontalMargin: 0
    verticalPadding: 0
    tooltipText: root.tooltipText

    Accessible.name: "Night Light, " + root.plainState
    Accessible.description: root.nextLine
    Accessible.role: Accessible.Button
    Accessible.onPressAction: root.togglePanel()

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) root.toggleManual()
      else if (mouseButton === Qt.MiddleButton) root.resumeAutomatic()
      else root.togglePanel()
    }

    Item {
      anchors.fill: parent

      Row {
        id: horizontalContent
        visible: !root.vertical
        anchors.centerIn: parent
        spacing: Style.space(6)

        OpticalGlyph {
          width: Style.bar.iconCanvas
          height: Style.bar.iconCanvas
          anchors.verticalCenter: parent.verticalCenter
          text: root.barGlyph
          fontFamily: button.fontFamily
          fontSize: Style.bar.iconFont
          color: button.foreground
        }

        Text {
          id: stableLabel
          anchors.verticalCenter: parent.verticalCenter
          text: root.barLabel
          color: button.foreground
          font.family: button.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 0.8
          horizontalAlignment: Text.AlignHCenter
          width: Style.space(30)
        }

        Text {
          visible: root.overridden
          anchors.verticalCenter: parent.verticalCenter
          text: "•"
          color: Style.selectedStateColor(button.foreground, Color.accent)
          font.family: button.fontFamily
          font.pixelSize: Style.font.bodySmall
          Accessible.ignored: true
        }
      }

      OpticalGlyph {
        visible: root.vertical
        anchors.centerIn: parent
        width: Style.bar.iconCanvas
        height: Style.bar.iconCanvas
        text: root.overridden ? "󰖔•" : root.barGlyph
        fontFamily: button.fontFamily
        fontSize: Style.bar.iconFont
        color: button.foreground
      }
    }
  }
}
