import QtQuick
import qs.Commons
import qs.Ui
import "TimelineModel.js" as TimelineModel

// Read-only, reusable 24-hour civil daylight rail. Timezone projection,
// astronomy, and clock ownership deliberately remain outside this component.
Item {
  id: root
  objectName: "daylightTimeline"

  required property var snapshot
  required property var moonPhase
  property bool current: false
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  signal focusRequested()

  property string _selectedEventKey: ""
  property string _pinnedEventKey: ""
  property string _hoveredEventKey: ""
  property string _hoverDetailReadyKey: ""
  property var _timeline: null
  property real _markerProgress: 0.5
  property bool _complete: false

  readonly property real _markerSize: Style.space(16)
  readonly property real _markerRadius: _markerSize / 2
  readonly property real _railStart: _markerRadius
  readonly property real _railSpan: Math.max(0, width - _markerSize)
  readonly property real _railY: height / 2
  readonly property real _trackHeight: Style.space(6)
  readonly property real _detailLaneHeight: height / 2
  readonly property real _detailGap: Style.spacing.sm
  readonly property real _detailTargetWidth: Style.space(32)
  readonly property Item _pinnedLabelItem: pinnedEventLabel
  readonly property var _events: _timeline ? _timeline.events : []
  readonly property bool _available: _timeline && _timeline.status !== "unavailable"
  readonly property bool _isDay: _available && _timeline.isDayNow === true
  readonly property bool _validMoon: {
    var moon = root.moonPhase
    if (!moon || moon.ok !== true) return false
    var illumination = Number(moon.illumination)
    return isFinite(illumination) && illumination >= 0 && illumination <= 1 &&
      (moon.trend === "waxing" || moon.trend === "waning") &&
      (moon.orientation === "northern" || moon.orientation === "southern") &&
      typeof moon.phaseName === "string" && moon.phaseName.length > 0
  }
  readonly property bool _showMoon: _available && !_isDay && _validMoon
  readonly property bool _revealArrows: railHover.hovered || current ||
    _hoveredEventKey !== "" || _pinnedEventKey !== ""
  readonly property string _displayedEventKey: _hoverDetailReadyKey !== ""
    ? _hoverDetailReadyKey : _pinnedEventKey
  readonly property var _pinnedEvent: _eventForKey(_pinnedEventKey)
  readonly property string _currentTimeText: _timeline
    ? _shortTime(_timeline.markerWallMs) : "—"

  implicitWidth: Style.space(320)
  implicitHeight: Style.space(58)
  height: implicitHeight
  z: _pinnedEventKey !== "" ? 10 : 0
  clip: false

  Accessible.role: Accessible.Grouping
  Accessible.name: "24-hour daylight timeline"
  Accessible.description: _accessibleDescription()

  function _canonicalSnapshot(value) {
    var result = TimelineModel.buildSnapshot(value)
    return result && result.ok === true ? result.snapshot : null
  }

  function _position(wallMs) {
    var position = TimelineModel.positionForWallMs(Number(wallMs))
    return position === null || !isFinite(position) ? 0 : position
  }

  function _eventIndex(key) {
    for (var i = 0; i < _events.length; i++)
      if (_events[i].key === key) return i
    return -1
  }

  function _eventForKey(key) {
    var index = _eventIndex(key)
    return index < 0 ? null : _events[index]
  }

  function _eventTargetY(event) {
    return event && event.kind === "sunrise" ? 0 :
      Math.max(0, height - Style.space(32))
  }

  function _detailTargetX(eventX) {
    return Math.max(0, Math.min(width - _detailTargetWidth,
      eventX - _detailTargetWidth / 2))
  }

  function _detailUsesRightLane(eventX) {
    var targetX = _detailTargetX(eventX)
    var leftSpace = targetX - _detailGap
    var rightSpace = width - (targetX + _detailTargetWidth + _detailGap)
    return rightSpace >= leftSpace
  }

  function _detailAvailableWidth(eventX) {
    var targetX = _detailTargetX(eventX)
    return Math.max(1, _detailUsesRightLane(eventX)
      ? width - (targetX + _detailTargetWidth + _detailGap)
      : targetX - _detailGap)
  }

  function _detailX(eventX, detailWidth) {
    var widthValue = Math.max(0, Math.min(_detailAvailableWidth(eventX),
      Number(detailWidth) || 0))
    var targetX = _detailTargetX(eventX)
    return _detailUsesRightLane(eventX)
      ? targetX + _detailTargetWidth + _detailGap
      : targetX - _detailGap - widthValue
  }

  function _detailY(event, detailHeight) {
    var heightValue = Math.max(0, Math.min(_detailLaneHeight,
      Number(detailHeight) || 0))
    // Detail stays in an explicit half-slot lane. Horizontal placement beside
    // the event target keeps its anchored arrow operable while neither label
    // can paint into a neighboring Panel row.
    return event && event.kind === "sunrise" ? 0 : height - heightValue
  }

  function _initialEventIndex() {
    if (_events.length === 0) return -1
    var now = _timeline ? Number(_timeline.nowMs) : 0
    for (var i = 0; i < _events.length; i++)
      if (Number(_events[i].epochMs) >= now) return i
    return _events.length - 1
  }

  function _ensureSelection() {
    if (_events.length === 0) {
      _selectedEventKey = ""
      return -1
    }
    var index = _eventIndex(_selectedEventKey)
    if (index < 0) {
      index = _initialEventIndex()
      _selectedEventKey = _events[index].key
    }
    return index
  }

  function moveSelection(direction) {
    if (direction !== -1 && direction !== 1) return false
    var index = _ensureSelection()
    if (index < 0 || _events.length === 1) return false
    var next = Math.max(0, Math.min(_events.length - 1, index + direction))
    if (next === index) return false
    _selectedEventKey = _events[next].key
    return true
  }

  function activateSelection() {
    var index = _ensureSelection()
    if (index < 0) return false
    _togglePin(_events[index].key)
    return true
  }

  function clearPin() {
    _pinnedEventKey = ""
    _hoveredEventKey = ""
    _hoverDetailReadyKey = ""
  }

  function _togglePin(key) {
    if (_eventIndex(key) < 0) return
    _hoveredEventKey = ""
    _pinnedEventKey = _pinnedEventKey === key ? "" : key
  }

  function _shortTime(wallMs) {
    var value = Number(wallMs)
    if (!isFinite(value) || value < 0 || value >= 86400000) return "—"
    var hours = Math.floor(value / 3600000)
    var minutes = Math.floor((value % 3600000) / 60000)
    var seconds = Math.floor((value % 60000) / 1000)
    var milliseconds = Math.floor(value % 1000)
    // This Date carries only caller-supplied wall fields. Event epoch and the
    // shell timezone never participate in the displayed civil time.
    var wall = new Date(1970, 0, 1, hours, minutes, seconds, milliseconds)
    return Qt.formatTime(wall, Qt.locale().timeFormat(Locale.ShortFormat))
  }

  function _offsetText(minutes) {
    var value = Number(minutes)
    if (!isFinite(value)) return ""
    var sign = value < 0 ? "−" : "+"
    var absolute = Math.abs(Math.round(value))
    var hours = Math.floor(absolute / 60)
    var mins = absolute % 60
    return "UTC" + sign + (hours < 10 ? "0" : "") + hours + ":" +
      (mins < 10 ? "0" : "") + mins
  }

  function _eventTime(event) {
    if (!event) return "—"
    var text = _shortTime(event.wallMs)
    if (event.ambiguous === true) text += " · " + _offsetText(event.offsetMinutes)
    return text
  }

  function _eventLabel(event) {
    if (!event) return ""
    return (event.kind === "sunrise" ? "Sunrise " : "Sunset ") + _eventTime(event)
  }

  function _markerAccessibleName() {
    var text = "Current time, " + _currentTimeText
    if (_timeline && _timeline.markerAmbiguous === true)
      text += ", " + _offsetText(_timeline.markerOffsetMinutes)
    if (_showMoon)
      text += ", " + moonPhase.phaseName + ", " +
        Math.round(Number(moonPhase.illumination) * 100) + "% illuminated"
    return text
  }

  function _markerTooltipText() {
    var currentLine = "Current time · " + _currentTimeText
    if (_showMoon)
      return moonPhase.phaseName + " · " +
        Math.round(Number(moonPhase.illumination) * 100) +
        "% illuminated\n" + currentLine
    return currentLine
  }

  function _kindEvent(kind) {
    for (var i = 0; i < _events.length; i++)
      if (_events[i].kind === kind) return _events[i]
    return null
  }

  function _accessibleDescription() {
    if (!_timeline || _timeline.status === "unavailable")
      return "Solar events unavailable. Current time " + _currentTimeText + "."
    if (_timeline.status === "polar-day")
      return "Daylight all day. Current time " + _currentTimeText + "."
    if (_timeline.status === "polar-night")
      return "Night all day. Current time " + _currentTimeText + "."
    var sunrise = _kindEvent("sunrise")
    var sunset = _kindEvent("sunset")
    if (sunrise && sunset)
      return "Daylight from " + _eventTime(sunrise) + " to " +
        _eventTime(sunset) + ". Current time " + _currentTimeText + "."
    if (sunrise)
      return "Daylight from " + _eventTime(sunrise) +
        " onward. Current time " + _currentTimeText + "."
    if (sunset)
      return "Daylight until " + _eventTime(sunset) +
        ". Current time " + _currentTimeText + "."
    return (_timeline.isDayNow ? "Daylight all day. Current time " :
      "Night all day. Current time ") + _currentTimeText + "."
  }

  function _applySnapshot() {
    var next = _canonicalSnapshot(snapshot)
    var previous = _timeline
    var contextChanged = previous && (!next ||
      previous.revision !== next.revision ||
      previous.dateKey !== next.dateKey || previous.zoneId !== next.zoneId)
    if (contextChanged) clearPin()

    if (_pinnedEventKey !== "") {
      var retained = false
      if (next) {
        for (var i = 0; i < next.events.length; i++)
          if (next.events[i].key === _pinnedEventKey) retained = true
      }
      if (!retained) clearPin()
    }

    markerAnimation.stop()
    var animate = _complete && previous && next &&
      TimelineModel.shouldAnimateMarker(previous, next)
    _timeline = next
    if (_eventIndex(_hoveredEventKey) < 0) _hoveredEventKey = ""
    if (_eventIndex(_hoverDetailReadyKey) < 0) _hoverDetailReadyKey = ""
    var target = next ? _position(next.markerWallMs) : 0.5
    if (animate) {
      markerAnimation.from = _markerProgress
      markerAnimation.to = target
      markerAnimation.start()
    } else {
      _markerProgress = target
    }

    if (_eventIndex(_selectedEventKey) < 0) _selectedEventKey = ""
    if (current) _ensureSelection()
  }

  onSnapshotChanged: if (_complete) _applySnapshot()
  onCurrentChanged: if (current) _ensureSelection()
  Component.onCompleted: {
    _applySnapshot()
    _complete = true
  }

  NumberAnimation {
    id: markerAnimation
    target: root
    property: "_markerProgress"
    duration: 160
    easing.type: Easing.OutCubic
  }

  BorderSurface {
    id: focusChrome
    objectName: "timelineFocusChrome"
    anchors.fill: parent
    color: root.current ? Style.focusFillFor(root.foreground, Color.accent) : "transparent"
    borderSpec: root.current
      ? Border.controlSpec("focus", root.foreground, Color.accent)
      : Border.none()
    radius: Style.cornerRadius
    z: -1
  }

  Rectangle {
    id: nightTrack
    objectName: "nightTrack"
    x: root._railStart
    y: root._railY - height / 2
    width: root._railSpan
    height: root._trackHeight
    radius: height / 2
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b,
                   root.foreground.a * 0.12)
  }

  Repeater {
    model: root._timeline ? root._timeline.daylightSegments : []
    delegate: Rectangle {
      required property var modelData
      objectName: "daylightSegment"
      x: root._railStart + root._railSpan * root._position(modelData.startWallMs)
      y: root._railY - height / 2
      width: Math.max(0, root._railSpan *
        (root._position(modelData.endWallMs) - root._position(modelData.startWallMs)))
      height: root._trackHeight
      radius: height / 2
      color: Style.selectedStateColor(root.foreground, Color.accent)
    }
  }

  Repeater {
    id: eventRepeater
    model: root._events

    delegate: Item {
      id: eventDelegate
      required property var modelData
      readonly property real eventX: root._railStart +
        root._railSpan * root._position(modelData.wallMs)
      readonly property bool selected: root._selectedEventKey === modelData.key
      readonly property bool pinned: root._pinnedEventKey === modelData.key
      readonly property bool sunrise: modelData.kind === "sunrise"
      anchors.fill: parent
      z: 4

      Rectangle {
        id: eventTick
        objectName: "eventTick-" + eventDelegate.modelData.kind
        x: eventDelegate.eventX - width / 2
        y: root._railY - (eventDelegate.sunrise ? Style.space(5) : 0)
        width: Style.spacing.hairline
        height: Style.space(5)
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b,
                       root.foreground.a * 0.42)
      }

      Text {
        id: arrow
        objectName: "eventArrow-" + eventDelegate.modelData.kind
        x: eventDelegate.eventX - width / 2
        y: eventDelegate.sunrise
          ? root._railY - height - Style.spacing.xs
          : root._railY + Style.spacing.xs
        text: eventDelegate.sunrise ? "↑" : "↓"
        color: eventDelegate.pinned
          ? Style.selectedStateColor(root.foreground, Color.accent)
          : (eventTarget.containsMouse || eventDelegate.selected && root.current
            ? Style.hoverStateColor(root.foreground, Color.accent)
            : root.foreground)
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        opacity: root._revealArrows || eventDelegate.pinned ? 1 : 0
        Behavior on opacity {
          NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
        }
      }

      BorderSurface {
        id: eventTarget
        objectName: "eventTarget-" + eventDelegate.modelData.kind + "-" +
          eventDelegate.modelData.key
        width: Math.max(Style.space(32), arrow.width)
        height: Style.space(32)
        x: Math.max(0, Math.min(root.width - width, eventDelegate.eventX - width / 2))
        y: eventDelegate.sunrise ? 0 : root.height - height
        color: eventDelegate.selected && root.current
          ? Style.focusFillFor(root.foreground, Color.accent) : "transparent"
        borderSpec: eventDelegate.selected && root.current
          ? Border.controlSpec("focus", root.foreground, Color.accent)
          : Border.none()
        radius: Style.cornerRadius

        Accessible.role: Accessible.Button
        Accessible.name: (eventDelegate.sunrise ? "Sunrise, " : "Sunset, ") +
          root._eventTime(eventDelegate.modelData)
        Accessible.onPressAction: {
          root._selectedEventKey = eventDelegate.modelData.key
          root._togglePin(eventDelegate.modelData.key)
        }

        property alias containsMouse: eventMouse.containsMouse

        MouseArea {
          id: eventMouse
          objectName: "eventMouse-" + eventDelegate.modelData.kind
          anchors.fill: parent
          acceptedButtons: Qt.LeftButton
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onEntered: {
            root._hoveredEventKey = eventDelegate.modelData.key
            root.focusRequested()
          }
          onExited: {
            if (root._hoveredEventKey === eventDelegate.modelData.key)
              root._hoveredEventKey = ""
          }
          onClicked: {
            root._selectedEventKey = eventDelegate.modelData.key
            // Clicking promotes the delayed hover detail to an immediate,
            // stable pinned label. It remains outward of this target.
            root._hoveredEventKey = ""
            root._togglePin(eventDelegate.modelData.key)
          }
        }
      }

      PanelToolTip {
        id: eventToolTip
        objectName: "eventToolTip-" + eventDelegate.modelData.kind
        // Pinned detail is rendered by the single stable overlay below;
        // hover remains the shell's native delayed PanelToolTip.
        visible: root._hoveredEventKey === eventDelegate.modelData.key
        text: root._eventLabel(eventDelegate.modelData)
        fontFamily: root.fontFamily
        delay: 400
        width: Math.min(implicitWidth, root._detailAvailableWidth(eventDelegate.eventX))
        height: Math.min(implicitHeight, root._detailLaneHeight)
        x: root._detailX(eventDelegate.eventX, width)
        y: root._detailY(eventDelegate.modelData, height)
        // aboutToShow fires only after PanelToolTip's native delay, just before
        // painting. Hide the pin in that same lifecycle turn to avoid overlap.
        onAboutToShow: root._hoverDetailReadyKey = eventDelegate.modelData.key
        onClosed: {
          if (root._hoverDetailReadyKey === eventDelegate.modelData.key)
            root._hoverDetailReadyKey = ""
        }
      }
    }
  }

  BorderSurface {
    id: pinnedEventLabel
    objectName: "pinnedEventLabel"
    readonly property real horizontalPadding: Style.spacing.controlPaddingX
    readonly property real verticalPadding: Style.spacing.controlPaddingY
    readonly property real naturalWidth: pinnedEventText.implicitWidth +
      horizontalPadding * 2 + borderLeft + borderRight
    readonly property real naturalHeight: pinnedEventText.implicitHeight +
      verticalPadding * 2 + borderTop + borderBottom
    readonly property real eventX: root._pinnedEvent
      ? root._railStart + root._railSpan * root._position(root._pinnedEvent.wallMs)
      : root._railStart

    // Preserve the pin throughout the native hover delay. The show/closed
    // lifecycle above swaps labels atomically and restores the pin only after
    // the hover popup is actually gone.
    visible: root._pinnedEvent !== null && root._hoverDetailReadyKey === ""
    width: Math.min(naturalWidth, root._detailAvailableWidth(eventX))
    height: Math.min(naturalHeight, root._detailLaneHeight)
    x: root._detailX(eventX, width)
    y: root._detailY(root._pinnedEvent, height)
    z: 10
    clip: true
    color: Color.tooltip.background
    borderSpec: Border.localOrSurfaceSpec("tooltip", "border",
      Color.tooltip.border, Color.tooltip.border, Style.normalBorderWidth)
    radius: Style.cornerRadius

    Text {
      id: pinnedEventText
      anchors.fill: parent
      anchors.leftMargin: pinnedEventLabel.borderLeft + pinnedEventLabel.horizontalPadding
      anchors.rightMargin: pinnedEventLabel.borderRight + pinnedEventLabel.horizontalPadding
      anchors.topMargin: pinnedEventLabel.borderTop + pinnedEventLabel.verticalPadding
      anchors.bottomMargin: pinnedEventLabel.borderBottom + pinnedEventLabel.verticalPadding
      text: root._eventLabel(root._pinnedEvent)
      color: Color.tooltip.text
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
      verticalAlignment: Text.AlignVCenter
    }
  }

  Item {
    id: marker
    objectName: "currentMarker"
    width: root._markerSize
    height: root._markerSize
    x: root._railStart + root._railSpan * root._markerProgress - width / 2
    y: root._railY - height / 2
    z: 3

    Accessible.role: Accessible.Indicator
    Accessible.name: root._markerAccessibleName()

    Item {
      id: sun
      objectName: "sunMarker"
      anchors.fill: parent
      visible: root._isDay

      Rectangle {
        anchors.centerIn: parent
        width: Style.space(8)
        height: width
        radius: width / 2
        color: Style.selectedStateColor(root.foreground, Color.accent)
      }
      Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        y: 0
        width: Style.spacing.hairline
        height: Style.space(3)
        color: Style.selectedStateColor(root.foreground, Color.accent)
      }
      Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        width: Style.spacing.hairline
        height: Style.space(3)
        color: Style.selectedStateColor(root.foreground, Color.accent)
      }
      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        x: 0
        width: Style.space(3)
        height: Style.spacing.hairline
        color: Style.selectedStateColor(root.foreground, Color.accent)
      }
      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        anchors.right: parent.right
        width: Style.space(3)
        height: Style.spacing.hairline
        color: Style.selectedStateColor(root.foreground, Color.accent)
      }
    }

    MoonPhaseIcon {
      objectName: "moonMarker"
      anchors.fill: parent
      visible: root._showMoon
      illumination: root._validMoon ? Number(root.moonPhase.illumination) : 0
      trend: root._validMoon ? String(root.moonPhase.trend) : "waxing"
      orientation: root._validMoon ? String(root.moonPhase.orientation) : "northern"
      foreground: root.foreground
    }

    Rectangle {
      objectName: "neutralMarker"
      anchors.fill: parent
      visible: !root._isDay && !root._showMoon
      color: "transparent"
      radius: width / 2
      border.width: Style.spacing.hairline
      border.color: Style.normalBorderFor(root.foreground, Color.accent)
    }
  }

  Item {
    id: markerTarget
    objectName: "markerTarget"
    width: Style.space(32)
    height: Style.space(32)
    x: Math.max(0, Math.min(root.width - width,
      root._railStart + root._railSpan * root._markerProgress - width / 2))
    y: root._railY - height / 2
    z: 2

    HoverHandler { id: markerHover }
    PanelToolTip {
      visible: markerHover.hovered
      text: root._markerTooltipText()
      fontFamily: root.fontFamily
    }
  }

  HoverHandler {
    id: railHover
    onHoveredChanged: if (hovered) root.focusRequested()
  }
}
