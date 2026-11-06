import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Workspace layout (Omarchy workspace mode) of the workspace shown on this
// bar's screen, drawn as window tiles. Click cycles dwindle -> scrolling ->
// floating -> matrix, right click goes back (matrix.toggle_layout in
// ~/.config/hypr/matrix.lua, which also writes the state file read here).
// Hovering fills the tiles with the color of the active workspace square.
BarWidget {
  id: root
  moduleName: "matrix.layout-mode"

  readonly property string stateFile: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/omarchy-matrix.json"
  readonly property string screenName: QsWindow.window && QsWindow.window.screen ? QsWindow.window.screen.name : ""
  property var monitors: ({})
  readonly property string layout: {
    var value = String(monitors[screenName] || "dwindle")
    return value.indexOf("matrix") >= 0 ? "matrix" : value
  }
  readonly property var names: ({ dwindle: "tiling", scrolling: "scrolling", floating: "floating", matrix: "matrix" })

  readonly property int unit: Math.max(1, Math.round(Style.fontPx(1) / 12))
  readonly property color foregroundColor: root.bar ? root.bar.barForeground : Commons.Color.foreground

  implicitWidth: root.vertical ? root.barSize : 12 * unit + Style.space(15)
  implicitHeight: root.barSize

  FileView {
    path: root.stateFile
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        root.monitors = JSON.parse(text()).monitors || {}
      } catch (e) {}
    }
  }

  LayoutGlyph {
    x: Math.round((root.width - width) / 2)
    y: Math.round((root.height - height) / 2)
    width: implicitWidth
    height: implicitHeight
    unit: root.unit
    layout: root.layout
    color: root.foregroundColor
    filled: button.containsMouse
  }

  MouseArea {
    id: button
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    cursorShape: Qt.PointingHandCursor
    onEntered: if (root.bar) root.bar.showTooltip(root, "Layout: " + (root.names[root.layout] || root.layout) + " (click: next, right click: back)")
    onExited: if (root.bar) root.bar.hideTooltip(root)
    onClicked: function(mouse) {
      if (root.bar) root.bar.hideTooltip(root)
      var arg = root.screenName ? "\"" + root.screenName + "\"" : "nil"
      var back = mouse.button === Qt.RightButton ? ", true" : ""
      Quickshell.execDetached(["hyprctl", "eval", "matrix.toggle_layout(" + arg + back + ")"])
    }
  }
}
