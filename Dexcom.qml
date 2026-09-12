import QtQuick
import Quickshell.Io
import qs.Ui

WidgetButton {
  id: root

  property string moduleName
  property var settings

  readonly property string scriptPath: Qt.resolvedUrl("scripts/dexcom-status").toString().replace("file://", "")

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null || value === "" ? fallback : value
  }

  // omarchy bar set stores everything as a string, including booleans - so
  // a stored "false" must not be treated as JS-truthy (a non-empty string).
  function settingBool(name, fallback) {
    var value = setting(name, fallback)
    if (typeof value === "boolean") return value
    return String(value).toLowerCase() === "true"
  }

  // Third-party plugins get a sandboxed PluginBarApi facade, not the raw
  // bar - it has no shellQuote (despite bar/README.md listing one; that's
  // first-party-only). Quoting our own args here avoids depending on it.
  function shQuote(s) {
    return "'" + String(s).replace(/'/g, "'\\''") + "'"
  }

  property bool ok: false
  property string mgdl: "--"
  property string trendArrow: "?"
  property var minutesAgo: null
  property string status: "unknown"
  property string tooltip: "Loading Dexcom data…"

  useActiveColor: false
  foreground: colorFor(status)
  text: ok ? ("BG " + mgdl + " " + trendArrow) : "BG --"
  tooltipText: tooltip

  function colorFor(s) {
    switch (s) {
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
        return bar ? bar.barForeground : "white"
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
      "--units", String(setting("units", "mgdl")),
      "--show-history", settingBool("showHistoryInTooltip", true) ? "true" : "false",
      "--history-minutes", String(setting("historyWindowMinutes", 60)),
      "--show-trend-word", settingBool("showTrendWord", false) ? "true" : "false",
    ]
    if (credentialsPath !== "") {
      args.push("--credentials", credentialsPath)
    }
    return args.map(shQuote).join(" ")
  }

  function refresh() {
    if (!proc.running) proc.running = true
  }

  onPressed: root.refresh()

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
}
