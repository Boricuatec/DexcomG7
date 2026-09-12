import QtQuick
import Quickshell.Io

Item {
  id: root

  property var bar
  property string moduleName
  property var settings

  readonly property string scriptPath: Qt.resolvedUrl("scripts/dexcom-status").toString().replace("file://", "")

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null || value === "" ? fallback : value
  }

  property bool ok: false
  property int mgdl: 0
  property string trendArrow: "?"
  property var minutesAgo: null
  property string status: "unknown"
  property string tooltip: "Loading Dexcom data…"

  implicitWidth: label.implicitWidth + 16
  implicitHeight: bar ? bar.barSize : 26

  function colorFor(status) {
    switch (status) {
      case "urgent_low":
      case "urgent_high":
        return bar ? bar.urgent : "#e05252"
      case "low":
      case "high":
        return "#e0a030"
      case "stale":
      case "unknown":
        return "#888888"
      default:
        return bar ? bar.foreground : "white"
    }
  }

  function buildCommand() {
    var credentialsPath = String(setting("credentialsPath", ""))
    var args = [
      root.scriptPath,
      "--server", String(setting("server", "share2")),
      "--low", String(setting("lowThreshold", 70)),
      "--high", String(setting("highThreshold", 180)),
      "--urgent-low", String(setting("urgentLow", 55)),
      "--urgent-high", String(setting("urgentHigh", 250)),
      "--stale-after", String(setting("staleAfterMinutes", 20)),
    ]
    if (credentialsPath !== "") {
      args.push("--credentials", credentialsPath)
    }
    var quoted = args.map(function(a) { return bar ? bar.shellQuote(a) : a })
    return quoted.join(" ")
  }

  function refresh() {
    if (!proc.running) proc.running = true
  }

  Process {
    id: proc
    command: ["bash", "-lc", root.buildCommand()]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var data = JSON.parse(text)
          if (data.ok) {
            root.ok = true
            root.mgdl = data.mgdl
            root.trendArrow = data.trendArrow
            root.minutesAgo = data.minutesAgo
            root.status = data.status
            root.tooltip = data.tooltip
          } else {
            root.ok = false
            root.status = "unknown"
            root.tooltip = data.tooltip || data.error || "Dexcom error"
          }
        } catch (e) {
          root.ok = false
          root.status = "unknown"
          root.tooltip = "dexcom-status produced invalid output"
        }
      }
    }
  }

  Timer {
    interval: Math.max(30, Number(root.setting("pollIntervalSeconds", 60))) * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Text {
    id: label
    anchors.centerIn: parent
    text: root.ok ? ("BG " + root.mgdl + " " + root.trendArrow) : "BG --"
    color: root.colorFor(root.status)
    font.family: bar ? bar.fontFamily : "monospace"
    font.pixelSize: 13
    font.bold: root.status === "urgent_low" || root.status === "urgent_high"
  }

  MouseArea {
    id: mouseArea
    anchors.fill: parent
    hoverEnabled: true
    onEntered: if (bar) bar.showTooltip(root, root.tooltip)
    onExited: if (bar) bar.hideTooltip(root)
    onClicked: root.refresh()
  }
}
