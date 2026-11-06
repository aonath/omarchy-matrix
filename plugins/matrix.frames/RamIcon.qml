import QtQuick

// RAM module: wide, low rounded body with four legs below (drawn from
// ~/Documents/omarchy/inconos topbar/ram2_sn.svg, 844x536).
Item {
  id: icon

  property color color: "white"

  implicitHeight: 10
  implicitWidth: Math.round(implicitHeight * 844 / 536)

  readonly property real unit: height / 536

  Rectangle {
    width: 844 * icon.unit
    height: 427 * icon.unit
    radius: 71 * icon.unit
    color: icon.color
  }

  Repeater {
    model: [0, 238, 476, 714]

    Rectangle {
      required property int modelData
      x: modelData * icon.unit
      y: 317 * icon.unit
      width: 130 * icon.unit
      height: 219 * icon.unit
      radius: 22 * icon.unit
      color: icon.color
    }
  }
}
