import QtQuick
import qs.Commons

// Workspace layout drawn as window tiles on a 12 x 12 whole-pixel grid, the
// size of the Omarchy menu glyph, so every edge lands on a pixel. Used by the
// bar button and by the Workspace Layout rows of the menu (omarchy-menu-plus draws "layout:" icons with its own copy).
//
// Outlined by default; `filled` paints the tiles solid (the bar button on
// hover, like the active workspace square).
Item {
  id: glyph

  property string layout: "dwindle"
  property int unit: 1
  property color color: Commons.Color.foreground
  property bool filled: false

  implicitWidth: 12 * unit
  implicitHeight: 12 * unit

  // Window tiles: [x, y, width, height].
  readonly property var boxes: ({
    dwindle: [[0, 0, 5, 12], [7, 0, 5, 5], [7, 7, 5, 5]],
    scrolling: [[0, 0, 7, 12], [9, 0, 3, 12]],
    matrix: [[0, 0, 5, 5], [7, 0, 5, 5], [0, 7, 5, 5], [7, 7, 5, 5]],
    floating: [[4, 5, 8, 7]]
  })

  // Solid strips: the window behind the floating one, cut one unit clear of it.
  readonly property var strips: ({
    floating: {
      outline: [[0, 0, 8, 1], [0, 0, 1, 7], [7, 0, 1, 4], [0, 6, 3, 1]],
      filled: [[0, 0, 8, 4], [0, 4, 3, 3]]
    }
  })

  readonly property string key: boxes[layout] ? layout : "dwindle"

  Repeater {
    model: glyph.boxes[glyph.key]

    Rectangle {
      required property var modelData
      x: modelData[0] * glyph.unit
      y: modelData[1] * glyph.unit
      width: modelData[2] * glyph.unit
      height: modelData[3] * glyph.unit
      color: glyph.filled ? glyph.color : "transparent"
      border.width: glyph.unit
      border.color: glyph.color
      Behavior on color { ColorAnimation { duration: Style.duration(160) } }
      Behavior on border.color { ColorAnimation { duration: Style.duration(160) } }
    }
  }

  Repeater {
    model: glyph.strips[glyph.key] ? glyph.strips[glyph.key][glyph.filled ? "filled" : "outline"] : []

    Rectangle {
      required property var modelData
      x: modelData[0] * glyph.unit
      y: modelData[1] * glyph.unit
      width: modelData[2] * glyph.unit
      height: modelData[3] * glyph.unit
      color: glyph.color
      Behavior on color { ColorAnimation { duration: Style.duration(160) } }
    }
  }
}
