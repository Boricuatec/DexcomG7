import QtQuick
import Quickshell.Io
import qs.Ui

// Panel (not WidgetButton) is the root because a popup graph needs the
// open/close lifecycle Panel+PanelController provide; the bar's visible
// text/tooltip/cursor live on a WidgetButton child instead (see button
// below), same split first-party panels like weather use.
Panel {
  id: root

  moduleName: "io.github.boricuatec.dexcomg7"
  ipcTarget: "io.github.boricuatec.dexcomg7"

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
  property string unit: "mg/dL"
  property string trendArrow: "?"
  property var minutesAgo: null
  property var secondsAgo: null
  property string status: "unknown"
  property string tooltip: "Loading Dexcom data…"
  property var series: []
  property var thresholds: ({})

  // Dexcom G7 publishes a new reading roughly every 5 minutes. Rather than
  // poll on a fixed interval (out of phase with that cadence, and far more
  // API calls than needed - part of why testing hit Dexcom's rate limit),
  // schedule the next poll for shortly after the next reading is expected,
  // based on the age of the one we just got.
  readonly property int readingIntervalSeconds: 300
  readonly property int publishBufferSeconds: 20
  readonly property int minPollSeconds: 15

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

  function commonArgs() {
    var credentialsPath = String(setting("credentialsPath", ""))
    var args = [
      Qt.resolvedUrl("scripts/dexcom-status").toString().replace("file://", ""),
      "--server", String(setting("server", "share2")),
      "--low", String(setting("lowThreshold", 70)),
      "--high", String(setting("highThreshold", 180)),
      "--urgent-low", String(setting("urgentLow", 55)),
      "--urgent-high", String(setting("urgentHigh", 250)),
      "--stale-after", String(setting("staleAfterMinutes", 20)),
      "--units", String(setting("units", "mgdl")),
    ]
    if (credentialsPath !== "") {
      args.push("--credentials", credentialsPath)
    }
    return args
  }

  function buildCommand() {
    var args = commonArgs().concat([
      "--show-history", settingBool("showHistoryInTooltip", true) ? "true" : "false",
      "--history-minutes", String(setting("historyWindowMinutes", 60)),
      "--show-trend-word", settingBool("showTrendWord", false) ? "true" : "false",
      "--graph-minutes", String(setting("graphWindowMinutes", 180)),
    ])
    return args.map(shQuote).join(" ")
  }

  // Used only when the popup's range buttons ask for a different window than
  // the regular poll fetched - independent of the adaptive poll schedule.
  function buildGraphCommand(minutes) {
    var args = commonArgs().concat(["--show-history", "false", "--graph-minutes", String(minutes)])
    return args.map(shQuote).join(" ")
  }

  function refresh() {
    if (!proc.running) proc.running = true
  }

  property int selectedRangeMinutes: Number(setting("graphWindowMinutes", 180))
  property bool graphLoading: false

  function loadRange(minutes) {
    var changed = minutes !== root.selectedRangeMinutes
    root.selectedRangeMinutes = minutes
    // Persist the pick as the new default so it survives a shell restart -
    // omarchy bar set writes shell.json, not just this running instance.
    if (changed && bar) {
      bar.run("omarchy bar set " + root.moduleName + " graphWindowMinutes " + minutes)
    }
    if (graphProc.running) return
    root.graphLoading = true
    graphProc.command = ["bash", "-lc", root.buildGraphCommand(minutes)]
    graphProc.running = true
  }

  function fallbackDelaySeconds() {
    return Math.max(30, Number(setting("pollIntervalSeconds", 60)))
  }

  function scheduleNextPoll() {
    var fallback = fallbackDelaySeconds()
    var delay = fallback

    if (root.ok && root.status !== "stale" && typeof root.secondsAgo === "number") {
      var wait = (root.readingIntervalSeconds + root.publishBufferSeconds) - root.secondsAgo
      delay = Math.max(root.minPollSeconds, wait)
      delay = Math.min(delay, fallback)
    }

    pollTimer.interval = delay * 1000
    pollTimer.restart()
  }

  onOpenedChanged: if (opened) root.refresh()

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

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
            root.unit = data.unit
            root.trendArrow = data.trendArrow
            root.minutesAgo = data.minutesAgo
            root.secondsAgo = data.secondsAgo
            root.status = data.status
            root.tooltip = data.tooltip
            root.series = data.series || []
            root.thresholds = data.thresholds || {}
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
        root.scheduleNextPoll()
      }
    }
  }

  // Fires only when the popup's range buttons ask for a window different
  // from the regular poll's - separate from proc so it never disturbs the
  // adaptive poll schedule above.
  Process {
    id: graphProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.graphLoading = false
        try {
          var data = JSON.parse(text)
          if (data.ok) {
            root.series = data.series || []
            root.thresholds = data.thresholds || {}
          }
        } catch (e) {
          // Leave the previously-shown graph in place on a bad response.
        }
      }
    }
  }

  Timer {
    id: pollTimer
    interval: 1000
    repeat: false
    running: true
    onTriggered: root.refresh()
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    useActiveColor: false
    foreground: root.colorFor(root.status)
    text: root.ok ? ("BG " + root.mgdl + " " + root.trendArrow) : "BG --"
    tooltipText: root.tooltip
    onPressed: root.toggle()
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    centerOnBar: true
    contentWidth: 300
    contentHeight: 252

    Column {
      anchors.fill: parent
      spacing: 8

      Row {
        width: parent.width
        spacing: 8

        Text {
          id: bigValue
          text: root.ok ? root.mgdl : "--"
          color: root.colorFor(root.status)
          font.pixelSize: 24
          font.bold: true
        }
        Text {
          text: root.unit + "  " + root.trendArrow
          color: bar ? bar.barForeground : "white"
          font.pixelSize: 14
          anchors.verticalCenter: bigValue.verticalCenter
        }
      }

      Text {
        width: parent.width
        text: root.minutesAgo !== null ? (root.minutesAgo + " min ago") : "time unknown"
        color: "#888888"
        font.pixelSize: 11
      }

      Row {
        width: parent.width
        spacing: 6

        Repeater {
          model: [
            { label: "3h", minutes: 180 },
            { label: "6h", minutes: 360 },
            { label: "12h", minutes: 720 },
            { label: "24h", minutes: 1440 },
          ]

          Rectangle {
            required property var modelData
            readonly property bool active: root.selectedRangeMinutes === modelData.minutes

            width: 44
            height: 22
            radius: 4
            color: active ? (bar ? bar.barForeground : "white") : "transparent"
            border.width: 1
            border.color: bar ? bar.barForeground : "#888888"

            Text {
              anchors.centerIn: parent
              text: parent.modelData.label
              color: parent.active ? (bar ? bar.background : "black") : (bar ? bar.barForeground : "white")
              font.pixelSize: 11
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.loadRange(parent.modelData.minutes)
            }
          }
        }

        Text {
          visible: root.graphLoading
          text: "…"
          color: "#888888"
          font.pixelSize: 14
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      Canvas {
        id: graphCanvas
        width: parent.width
        height: 120

        onPaint: {
          var ctx = getContext("2d")
          ctx.clearRect(0, 0, width, height)
          var series = root.series

          if (!series || series.length < 2) {
            ctx.fillStyle = "#888888"
            ctx.font = "11px sans-serif"
            ctx.fillText("Not enough data yet", 10, height / 2)
            return
          }

          var values = series.map(function (p) { return p.value })
          var th = root.thresholds || {}
          var lo = Math.min.apply(null, values)
          var hi = Math.max.apply(null, values)
          if (typeof th.urgentLow === "number") lo = Math.min(lo, th.urgentLow)
          if (typeof th.urgentHigh === "number") hi = Math.max(hi, th.urgentHigh)
          var pad = Math.max((hi - lo) * 0.15, 1)
          var yMin = lo - pad
          var yMax = hi + pad
          var range = yMax - yMin || 1

          function xFor(i) { return (i / (series.length - 1)) * width }
          function yFor(v) {
            var c = Math.max(yMin, Math.min(yMax, v))
            return height - ((c - yMin) / range) * height
          }

          if (typeof th.high === "number") {
            ctx.fillStyle = "rgba(224,82,82,0.12)"
            ctx.fillRect(0, 0, width, yFor(th.high))
          }
          if (typeof th.low === "number") {
            ctx.fillStyle = "rgba(224,82,82,0.12)"
            ctx.fillRect(0, yFor(th.low), width, height - yFor(th.low))
          }

          ctx.strokeStyle = "#5b9bd5"
          ctx.lineWidth = 2
          ctx.beginPath()
          for (var i = 0; i < series.length; i++) {
            var x = xFor(i)
            var y = yFor(series[i].value)
            if (i === 0) ctx.moveTo(x, y)
            else ctx.lineTo(x, y)
          }
          ctx.stroke()

          var lastX = xFor(series.length - 1)
          var lastY = yFor(series[series.length - 1].value)
          ctx.fillStyle = root.colorFor(root.status)
          ctx.beginPath()
          ctx.arc(lastX, lastY, 3.5, 0, Math.PI * 2)
          ctx.fill()

          ctx.fillStyle = "#888888"
          ctx.font = "10px sans-serif"
          ctx.fillText(hi.toFixed(1), 4, 10)
          ctx.fillText(lo.toFixed(1), 4, height - 4)
        }
      }

      Text {
        width: parent.width
        text: {
          var series = root.series
          if (!series || series.length < 2) return ""
          var oldest = series[0], newest = series[series.length - 1]
          var values = series.map(function (p) { return p.value })
          var lo = Math.min.apply(null, values)
          var hi = Math.max.apply(null, values)
          var spanMin = 0
          if (typeof oldest.secondsAgo === "number" && typeof newest.secondsAgo === "number")
            spanMin = Math.round((oldest.secondsAgo - newest.secondsAgo) / 60)
          return "Last " + spanMin + " min: " + lo + "-" + hi + " " + root.unit
        }
        color: "#888888"
        font.pixelSize: 11
      }
    }
  }

  Connections {
    target: root
    function onSeriesChanged() { graphCanvas.requestPaint() }
    function onStatusChanged() { graphCanvas.requestPaint() }
  }
}
