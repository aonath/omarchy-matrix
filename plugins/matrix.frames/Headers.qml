import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets
import qs.Commons
import qs.Commons as Commons

// Panel frames for windows on matrix-layout workspaces. The Hyprland matrix
// layout (~/.config/hypr/matrix.lua) turns off Hyprland's border there, places
// each window inside a frame with a header row, and writes the frames to a
// state file. This draws them on a bottom-layer surface per screen, so windows
// (floating ones included) always stay on top: the border and the header show
// around the window as a single panel.
Item {
  id: root
  visible: false

  property var shell: null

  readonly property string stateFile: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/omarchy-matrix.json"

  property var headers: ({})
  // Monitor name -> header addresses on it.
  property var addresses: ({})
  property int borderWidth: 2
  // Hyprland's decoration:rounding (Window Corners): the frame around header and
  // window is rounded to match the window's own corners.
  property int rounding: 0
  // Glassy windows: see-through header, blurred by Hyprland (matrix.lua).
  property bool glassy: false
  readonly property color headerColor: glassy
    ? Qt.rgba(Commons.Color.background.r, Commons.Color.background.g, Commons.Color.background.b, 0.65)
    : Commons.Color.background
  property color activeColor: Commons.Color.accent
  property color inactiveColor: Style.normalBorderColor

  function parse(raw) {
    var data
    try {
      data = JSON.parse(raw)
    } catch (e) {
      return
    }

    var map = {}
    var lists = {}
    var items = data.headers || []
    for (var i = 0; i < items.length; i++) {
      map[items[i].address] = items[i]
      if (!lists[items[i].monitor]) lists[items[i].monitor] = []
      lists[items[i].monitor].push(items[i].address)
    }

    borderWidth = Math.round(data.border || 0)
    rounding = Math.max(0, Math.round(data.rounding || 0))
    glassy = data.glassy === true
    if (data.active_color) activeColor = data.active_color
    if (data.inactive_color) inactiveColor = data.inactive_color
    headers = map
    if (JSON.stringify(lists) !== JSON.stringify(addresses)) addresses = lists
  }

  function action(address, name) {
    Quickshell.execDetached(["hyprctl", "eval", "matrix.header_action(\"" + address + "\", \"" + name + "\")"])
  }

  function normalizeUrl(url) {
    return String(url || "").replace(/^["']|["']$/g, "").replace(/^https?:\/\//, "").replace(/[\/_]+$/, "").replace(/[\/_]+/g, "/")
  }

  // Browser --app windows (Omarchy web apps) are classed like
  // "chrome-outlook.cloud.microsoft__mail_-Default"; find the launcher whose
  // URL matches.
  function webAppEntry(windowClass) {
    var match = String(windowClass).match(/^(?:chrome|msedge|brave|chromium|vivaldi)-(.+)-[^-]+$/)
    if (!match) return null
    var key = normalizeUrl(match[1])
    var host = key.split("/")[0]
    var sameHost = null
    var values = DesktopEntries.applications.values || []
    for (var i = 0; i < values.length; i++) {
      var exec = String(values[i].execString || "")
      var url = exec.match(/--app=(\S+)/) || exec.match(/omarchy-launch-webapp\s+(\S+)/)
      if (!url) continue
      var launcher = normalizeUrl(url[1])
      if (launcher === key) return values[i]
      // Deep links (e.g. a Teams meeting window) belong to the web app of the
      // same site; Teams meeting links live on teams.microsoft.com while the
      // launcher opens teams.cloud.microsoft.
      var launcherHost = launcher.split("/")[0]
      if (!sameHost && (launcherHost === host || (host.indexOf("teams.") === 0 && launcherHost.indexOf("teams.") === 0))) sameHost = values[i]
    }
    return sameHost
  }

  // Window class -> { name, icon, webapp } of its launcher. Plain strings, not
  // DesktopEntry objects: those are destroyed when the launcher list is
  // rescanned (any change in ~/.local/share/applications), and a cached dead
  // entry has no icon, which showed the generic gear in the header.
  property var appCache: ({})
  // Desktop entries load after startup; bindings that read this re-run once
  // they arrive, and misses are never cached.
  readonly property int entriesRevision: (DesktopEntries.applications.values || []).length

  // Header names that differ from the launcher name.
  readonly property var nameOverrides: ({
    "com.anthropic.Claude": "Claude Desktop"
  })

  function appInfo(windowClass) {
    if (!windowClass || entriesRevision < 0) return null
    // Placeholder panel of a VM app that is starting: show the app itself.
    windowClass = String(windowClass).replace(/^wpx\.placeholder\./, "")
    if (appCache[windowClass]) return appCache[windowClass]
    // An exact StartupWMClass match first: the heuristic lookup mixed up the two
    // Outlook launchers (classic "outlook" and the new one's long UWP class).
    var entry = startupClassEntry(windowClass)
    entry = entry || (DesktopEntries.heuristicLookup ? DesktopEntries.heuristicLookup(windowClass) : null)
    entry = entry || DesktopEntries.byId(windowClass) || webAppEntry(windowClass)
    if (!entry) return null
    var exec = String(entry.execString || "")
    var data = {
      name: String(entry.name || ""),
      icon: String(entry.icon || ""),
      webapp: /omarchy-launch-webapp|--app=/.test(exec)
    }
    if (data.icon) appCache[windowClass] = data
    return data
  }

  // Launchers whose StartupWMClass is the window class (winpodx sets it for
  // every Windows VM app, e.g. "powerpnt" for PowerPoint).
  function startupClassEntry(windowClass) {
    var wanted = String(windowClass).toLowerCase()
    var values = DesktopEntries.applications.values || []
    for (var i = 0; i < values.length; i++) {
      if (String(values[i].startupClass || "").toLowerCase() === wanted) return values[i]
    }
    return null
  }

  // Memory of the app behind each window, from ~/.local/bin/matrix-panel-mem:
  // by window pid for Linux apps, by window class for Windows VM apps.
  property var memPids: ({})
  property var memVm: ({})
  property var memVmWindows: ({})
  // RAM of the OS each window runs in: Linux (host minus what running VMs were
  // given and hold) or the Windows VM. Used and total, for the shares shown
  // next to each window's usage.
  property real memHostTotal: 0
  property real memHostUsed: 0
  property real memVmTotal: 0
  property real memVmUsed: 0

  function memoryFor(info) {
    if (!info) return 0
    if (info.vm) return memVmWindows[info.address] || memVm[info.class] || 0
    return memPids[String(Math.round(info.pid || 0))] || 0
  }

  function formatBytes(bytes) {
    if (!bytes) return ""
    var mb = bytes / 1048576
    return mb >= 1024 ? (mb / 1024).toFixed(1) + "GB" : Math.round(mb) + "MB"
  }

  function formatGb(bytes) {
    return (bytes / 1073741824).toFixed(1) + "GB"
  }

  // Percentage with one decimal, none when it is a whole number.
  function formatPercent(part, whole) {
    var value = Math.round(1000 * part / whole) / 10
    return (value % 1 === 0 ? value.toFixed(0) : value.toFixed(1)) + "%"
  }

  // "<window>/<OS in use> | <OS total>, <window/in use>% | <window/total>%",
  // drawn after the RAM icon; Windows VM apps are measured against the VM's RAM.
  function memLabel(info) {
    var mine = memoryFor(info)
    if (!mine) return ""
    var used = info.vm ? memVmUsed : memHostUsed
    var total = info.vm ? memVmTotal : memHostTotal
    if (!used || !total) return formatBytes(mine)
    return formatBytes(mine) + "/" + formatGb(used) + " | " + formatGb(total) + ", "
      + formatPercent(mine, used) + " | " + formatPercent(mine, total)
  }

  Process {
    id: memScan
    command: [root.home + "/.local/bin/matrix-panel-mem"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var data = JSON.parse(text)
          root.memPids = data.pids || {}
          root.memVm = data.vm || {}
          root.memVmWindows = data.vm_windows || {}
          root.memHostTotal = data.host_total || 0
          root.memHostUsed = data.host_used || 0
          root.memVmTotal = data.vm_total || 0
          root.memVmUsed = data.vm_used || 0
        } catch (e) {}
      }
    }
  }

  Timer {
    interval: 5000
    repeat: true
    triggeredOnStart: true
    running: Object.keys(root.headers).length > 0
    onTriggered: if (!memScan.running) memScan.running = true
  }

  readonly property string home: Quickshell.env("HOME") || ""

  // Icon files to try in order. The themed lookup goes last: when the icon
  // theme cache is stale it returns a generic icon instead of failing.
  function iconSources(icon) {
    if (!icon) return [Quickshell.iconPath("application-x-executable", true)]
    if (icon.charAt(0) === "/") return ["file://" + icon]
    var list = []
    var bases = [home + "/.local/share/icons/hicolor", "/usr/share/icons/hicolor"]
    for (var i = 0; i < bases.length; i++) {
      list.push("file://" + bases[i] + "/256x256/apps/" + icon + ".png")
      list.push("file://" + bases[i] + "/scalable/apps/" + icon + ".svg")
      list.push("file://" + bases[i] + "/128x128/apps/" + icon + ".png")
    }
    list.push("file:///usr/share/pixmaps/" + icon + ".png")
    list.push(Quickshell.iconPath(icon, true))
    return list
  }

  function appName(windowClass, app) {
    if (nameOverrides[windowClass]) return nameOverrides[windowClass]
    // Launchers carry the run-mode mark in their name ("(VM <win>) <app glyph> ",
    // "(WPS <browser>) ", "(XW) ", see ~/.local/bin/app-name-prefixes); the
    // header draws the mark (and the app icon) itself, from the window.
    return app && app.name
      ? app.name.replace(/^\(VM [^)]*\)\s*\S+\s+/, "").replace(/^(?:\((?:XW|WPS[^)]*)\)\s*)+/, "")
          .replace(/ \((?:VM|WPS)\)$/, "")
      : windowClass
  }

  // Browser of a web app window, from its class ("chrome-<url>-<profile>").
  readonly property var browserMarks: ({
    "chrome": { glyph: "󰊯", color: "#4285F4" },
    "chromium": { glyph: "󰊯", color: "#5E97F6" },
    "msedge": { glyph: "󰇩", color: "#0C8CE9" },
    "brave": { glyph: "󰖟", color: "#FB542B" },
    "vivaldi": { glyph: "󰖟", color: "#EF3939" }
  })

  // Rich-text run-mode mark shown before the app name: "(VM <win>)" for winpodx
  // Windows VM apps, "(WPS <browser>)" for web apps, "(XW)" for XWayland apps.
  function runMark(info, app) {
    if (!info) return ""
    if (info.vm) return "(VM <font color=\"#00A4EF\">󰖳</font>)"
    var browser = String(info.class).match(/^(chrome|chromium|msedge|brave|vivaldi)-.+-[^-]+$/)
    if (browser || (app && app.webapp)) {
      var mark = browserMarks[browser ? browser[1] : "chrome"]
      return "(WPS <font color=\"" + mark.color + "\">" + mark.glyph + "</font>)"
    }
    if (info.xwayland) return "(XW)"
    return ""
  }

  FileView {
    path: root.stateFile
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.parse(text())
  }

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: surface

      required property var modelData

      screen: modelData
      visible: panels.count > 0
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      anchors { top: true; bottom: true; left: true; right: true }

      WlrLayershell.namespace: "omarchy-matrix-frames"
      WlrLayershell.layer: WlrLayer.Bottom
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      // Only the header rows take input; the rest of the surface lets clicks
      // through to the desktop.
      mask: Region {
        regions: {
          var list = []
          for (var i = 0; i < panels.count; i++) {
            var item = panels.itemAt(i)
            if (item) list.push(item.inputRegion)
          }
          return list
        }
      }

      Repeater {
        id: panels
        model: root.addresses[surface.modelData.name] || []

        Item {
          id: panel

          required property var modelData

          readonly property var info: root.headers[modelData] || null
          readonly property var app: info ? root.appInfo(info.class) : null
          readonly property string appName: info ? root.appName(info.class, app) : ""
          readonly property string runMark: root.runMark(info, app)
          // Last icon found for this window: a lookup that misses for a moment
          // (launchers being rescanned) keeps the icon instead of a gear.
          property string iconName: ""
          onAppChanged: if (app && app.icon && app.icon !== iconName) iconName = app.icon
          readonly property var iconSources: root.iconSources(iconName)
          property int iconIndex: 0
          onIconSourcesChanged: iconIndex = 0
          readonly property bool active: info ? info.active : false
          readonly property bool headerBottom: info ? info.bottom === true : false
          property Region inputRegion: Region { item: headerRow }

          // Frames move with their windows: same length and curve as
          // Omarchy's "windows" animation (3.79 = 379 ms, easeOutQuint), and
          // none when animations are off. A new panel appears in place.
          property bool animate: false
          Component.onCompleted: {
            if (app && app.icon) iconName = app.icon
            Qt.callLater(function() { panel.animate = true })
          }
          property real frameX: info ? Math.round(info.frame_x) : 0
          property real frameY: info ? Math.round(info.frame_y) : 0
          property real frameW: info ? Math.round(info.frame_w) : 0
          property real frameH: info ? Math.round(info.frame_h) : 0
          property real headerX: info ? Math.round(info.x) : 0
          property real headerY: info ? Math.round(info.y) : 0
          property real headerW: info ? Math.round(info.w) : 0
          Behavior on frameX { enabled: panel.animate; NumberAnimation { duration: Style.duration(379); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut } }
          Behavior on frameY { enabled: panel.animate; NumberAnimation { duration: Style.duration(379); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut } }
          Behavior on frameW { enabled: panel.animate; NumberAnimation { duration: Style.duration(379); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut } }
          Behavior on frameH { enabled: panel.animate; NumberAnimation { duration: Style.duration(379); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut } }
          Behavior on headerX { enabled: panel.animate; NumberAnimation { duration: Style.duration(379); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut } }
          Behavior on headerY { enabled: panel.animate; NumberAnimation { duration: Style.duration(379); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut } }
          Behavior on headerW { enabled: panel.animate; NumberAnimation { duration: Style.duration(379); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut } }

          visible: info !== null

          // Frame around header and window together. With rounded corners
          // its outer radius is the window's plus the border, so the border's
          // inner edge follows the window's corners, as Hyprland draws it.
          Rectangle {
            x: panel.frameX
            y: panel.frameY
            width: panel.frameW
            height: panel.frameH
            radius: root.rounding > 0 ? root.rounding + root.borderWidth : 0
            // Windows VM apps are transparent until first painted; show the bar color then.
            color: panel.info && panel.info.vm === true ? Commons.Color.background : "transparent"
            border.width: root.borderWidth
            border.color: panel.active ? root.activeColor : root.inactiveColor
            Behavior on border.color { enabled: panel.animate; ColorAnimation { duration: Style.duration(539); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut } }
          }

          // The window's own rounded corners next to the header show the header
          // behind them, so header and window read as one rounded panel.
          Rectangle {
            visible: root.rounding > 0
            x: panel.headerX
            y: panel.headerBottom ? panel.headerY - root.rounding : panel.headerY + headerRow.height
            width: panel.headerW
            height: root.rounding
            color: root.headerColor
          }

          Rectangle {
            id: headerRow
            x: panel.headerX
            y: panel.headerY
            width: panel.headerW
            height: panel.info ? Math.round(panel.info.h) : 0
            color: root.headerColor
            topLeftRadius: panel.headerBottom ? 0 : root.rounding
            topRightRadius: panel.headerBottom ? 0 : root.rounding
            bottomLeftRadius: panel.headerBottom ? root.rounding : 0
            bottomRightRadius: panel.headerBottom ? root.rounding : 0

            MouseArea {
              anchors.fill: parent
              acceptedButtons: Qt.LeftButton | Qt.MiddleButton
              onClicked: function(mouse) {
                root.action(panel.modelData, mouse.button === Qt.MiddleButton ? "close" : "focus")
              }
            }

            Row {
              anchors.left: parent.left
              anchors.leftMargin: 8
              anchors.right: memRow.visible ? memRow.left : buttons.left
              anchors.rightMargin: 8
              anchors.verticalCenter: parent.verticalCenter
              spacing: 6

              // Run-mode mark: "(VM <win>)", "(WPS <browser>)" or "(XW)".
              Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: panel.runMark.length > 0
                textFormat: Text.StyledText
                text: panel.runMark
                color: Commons.Color.foreground
                opacity: panel.active ? 1 : 0.7
                font.family: Style.fontFamily
                font.pixelSize: Style.fontPx(1)
              }

              Image {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(12, headerRow.height - 8)
                height: width
                sourceSize.width: width * 2
                sourceSize.height: height * 2
                fillMode: Image.PreserveAspectFit
                smooth: true
                asynchronous: true
                source: panel.iconSources[Math.min(panel.iconIndex, panel.iconSources.length - 1)] || ""
                onStatusChanged: if (status === Image.Error && panel.iconIndex < panel.iconSources.length - 1) panel.iconIndex++
              }

              Text {
                id: nameText
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, parent.width - x)
                text: panel.appName
                elide: Text.ElideRight
                color: Commons.Color.foreground
                opacity: panel.active ? 1 : 0.7
                font.family: Style.fontFamily
                font.pixelSize: Style.fontPx(1)
                font.bold: panel.active
              }

            }

            // RAM of the window, centered in the header row; same icon and text
            // style as the bar's RAM indicator (icon inset like the workspace
            // squares, text like an empty workspace's number).
            Row {
              id: memRow
              readonly property string label: root.memLabel(panel.info)
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.verticalCenter: parent.verticalCenter
              visible: label.length > 0 && implicitWidth + 2 * buttons.width + 160 < headerRow.width

              // As tall as the digits of the label, then a space.
              TextMetrics { id: memDigit; font: memLabelText.font; text: "0" }
              TextMetrics { id: memSpace; font: memLabelText.font; text: " " }

              RamIcon {
                anchors.verticalCenter: parent.verticalCenter
                implicitHeight: Math.round(memDigit.tightBoundingRect.height)
                // Solid look-alike of the dimmed label (half foreground over
                // the header background).
                color: Qt.rgba((Commons.Color.foreground.r + Commons.Color.background.r) / 2,
                  (Commons.Color.foreground.g + Commons.Color.background.g) / 2,
                  (Commons.Color.foreground.b + Commons.Color.background.b) / 2, 1)
              }

              Item { width: memSpace.advanceWidth; height: 1 }

              Text {
                id: memLabelText
                anchors.verticalCenter: parent.verticalCenter
                text: memRow.label
                color: Commons.Color.foreground
                opacity: 0.5
                renderType: Text.NativeRendering
                font.family: Style.fontFamily
                font.pixelSize: Style.font.body
              }
            }

            Row {
              id: buttons
              anchors.right: parent.right
              anchors.rightMargin: 2
              anchors.verticalCenter: parent.verticalCenter
              spacing: 2

              Repeater {
                model: [
                  { action: "d", glyph: "󰅀", shown: panel.info && panel.info.down },
                  { action: "u", glyph: "󰅃", shown: panel.info && panel.info.up },
                  { action: "l", glyph: "󰅁", shown: panel.info && panel.info.left },
                  { action: "r", glyph: "󰅂", shown: panel.info && panel.info.right },
                  { action: "close", glyph: "󰅖", shown: true }
                ]

                Rectangle {
                  required property var modelData

                  visible: modelData.shown === true
                  width: headerRow.height - 4
                  height: headerRow.height - 4
                  radius: Math.max(0, root.rounding - 2)
                  color: buttonArea.containsMouse
                    ? (modelData.action === "close" ? Commons.Color.urgent : Style.hoverFill)
                    : "transparent"

                  Text {
                    anchors.centerIn: parent
                    text: parent.modelData.glyph
                    color: Commons.Color.foreground
                    font.family: Style.fontFamily
                    font.pixelSize: Style.fontPx(1.1)
                  }

                  MouseArea {
                    id: buttonArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.action(panel.modelData, parent.modelData.action)
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
