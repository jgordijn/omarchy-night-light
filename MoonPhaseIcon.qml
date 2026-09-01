import QtQuick
import QtQuick.Shapes
import qs.Commons

// Primitive lunar disk. The parent owns sizing, interaction, tooltip copy,
// and accessibility.
Item {
  id: root

  property real illumination: 0
  property string trend: "waxing"
  property string orientation: "northern"
  property color foreground: Color.foreground

  QtObject {
    id: geometry

    readonly property real diameter: Math.max(0, Math.min(root.width, root.height))
    readonly property real radius: diameter / 2
    readonly property real centerX: root.width / 2
    readonly property real centerY: root.height / 2
    readonly property real kappa: 0.5522847498307936
    readonly property real lit: isFinite(root.illumination)
      ? Math.max(0, Math.min(1, root.illumination)) : 0
    readonly property real hemisphere: root.orientation === "southern" ? -1 : 1
    readonly property real trendSide: root.trend === "waning" ? -1 : 1
    readonly property real side: hemisphere * trendSide
    readonly property real terminator: side * (1 - 2 * lit)
  }

  // The complete disk remains subtly visible when none of it is illuminated.
  Rectangle {
    id: shadowDisk
    width: geometry.diameter
    height: geometry.diameter
    anchors.centerIn: parent
    radius: width / 2
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b,
                   root.foreground.a * 0.12)
    border.width: 0
  }

  Shape {
    anchors.fill: parent
    visible: geometry.lit > 0
    preferredRendererType: Shape.CurveRenderer

    ShapePath {
      strokeWidth: 0
      strokeColor: "transparent"
      fillColor: root.foreground
      startX: geometry.centerX
      startY: geometry.centerY - geometry.radius

      // Outer semicircle on the illuminated side, top to bottom.
      PathCubic {
        control1X: geometry.centerX + geometry.side * geometry.kappa * geometry.radius
        control1Y: geometry.centerY - geometry.radius
        control2X: geometry.centerX + geometry.side * geometry.radius
        control2Y: geometry.centerY - geometry.kappa * geometry.radius
        x: geometry.centerX + geometry.side * geometry.radius
        y: geometry.centerY
      }
      PathCubic {
        control1X: geometry.centerX + geometry.side * geometry.radius
        control1Y: geometry.centerY + geometry.kappa * geometry.radius
        control2X: geometry.centerX + geometry.side * geometry.kappa * geometry.radius
        control2Y: geometry.centerY + geometry.radius
        x: geometry.centerX
        y: geometry.centerY + geometry.radius
      }

      // Return bottom-to-top on the projected elliptical terminator.  Together
      // with the two outer quadrants these are the four cubic quadrants of the
      // closed illuminated region.  Its signed horizontal radius reaches the
      // outer rim at new/full moon and is zero at quarter moon.
      PathCubic {
        control1X: geometry.centerX + geometry.terminator * geometry.kappa * geometry.radius
        control1Y: geometry.centerY + geometry.radius
        control2X: geometry.centerX + geometry.terminator * geometry.radius
        control2Y: geometry.centerY + geometry.kappa * geometry.radius
        x: geometry.centerX + geometry.terminator * geometry.radius
        y: geometry.centerY
      }
      PathCubic {
        control1X: geometry.centerX + geometry.terminator * geometry.radius
        control1Y: geometry.centerY - geometry.kappa * geometry.radius
        control2X: geometry.centerX + geometry.terminator * geometry.kappa * geometry.radius
        control2Y: geometry.centerY - geometry.radius
        x: geometry.centerX
        y: geometry.centerY - geometry.radius
      }
    }
  }

  // Draw last so every phase, especially new moon, keeps a theme-native edge.
  Rectangle {
    width: geometry.diameter
    height: geometry.diameter
    anchors.centerIn: parent
    radius: width / 2
    color: "transparent"
    border.color: Style.normalBorderFor(root.foreground, Color.accent)
    border.width: Style.spacing.hairline
  }
}
