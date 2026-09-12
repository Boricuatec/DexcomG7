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

  // Right-side margin reserved for the graph's axis labels, shared between
  // the canvas plot area and the x-axis time-label row below it so "Now"
  // lines up with the last dot instead of the popup's true right edge.
  readonly property int graphLabelMargin: 34

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

  function formatClockTime(secondsAgo) {
    var d = new Date(Date.now() - secondsAgo * 1000)
    var h = d.getHours()
    var ap = h >= 12 ? "PM" : "AM"
    var h12 = h % 12
    if (h12 === 0) h12 = 12
    return h12 + ap
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
  implicitWidth: barRow.implicitWidth
  implicitHeight: barRow.implicitHeight

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

  Row {
    id: barRow
    anchors.fill: parent
    spacing: 4

    // Original artwork (not Dexcom's logo/trademark): a round sensor patch
    // with an off-center transmitter bump, evoking a G7 without copying any
    // actual Dexcom imagery. Toggle with the showSensorIcon setting.
    Rectangle {
      id: sensorIcon
      visible: settingBool("showSensorIcon", true)
      width: 14
      height: 14
      radius: 7
      color: "transparent"
      border.width: 1.5
      border.color: root.colorFor(root.status)
      anchors.verticalCenter: parent.verticalCenter

      Rectangle {
        width: 6
        height: 6
        radius: 3
        color: parent.border.color
        anchors.centerIn: parent
        anchors.horizontalCenterOffset: 2
        anchors.verticalCenterOffset: -2
      }

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.toggle()
      }
    }

    WidgetButton {
      id: button
      bar: root.bar
      useActiveColor: false
      foreground: root.colorFor(root.status)
      text: root.ok ? ("BG " + root.mgdl + " " + root.trendArrow) : "BG --"
      tooltipText: root.tooltip
      onPressed: root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    contentWidth: panel.fittedContentWidth(300)
    contentHeight: panel.fittedContentHeight(popupColumn.implicitHeight, 340)

    Column {
      id: popupColumn
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

      Row {
        width: parent.width
        spacing: 6

        Repeater {
          model: [
            { hours: "3", minutes: 180 },
            { hours: "6", minutes: 360 },
            { hours: "12", minutes: 720 },
            { hours: "24", minutes: 1440 },
          ]

          Rectangle {
            id: rangeChip
            required property var modelData
            readonly property bool active: root.selectedRangeMinutes === modelData.minutes

            width: label.implicitWidth + (active ? 16 : 8)
            height: 22
            radius: height / 2
            color: active ? "#333333" : "transparent"

            Text {
              id: label
              anchors.centerIn: parent
              text: rangeChip.active ? (rangeChip.modelData.hours + " Hours") : rangeChip.modelData.hours
              color: rangeChip.active ? "#ffffff" : "#888888"
              font.pixelSize: 11
              font.bold: rangeChip.active
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.loadRange(rangeChip.modelData.minutes)
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

          // Reserve a right-side margin for axis labels so dots/lines never
          // run into them - matches the reference app, where the plot area
          // stops well before the numbers.
          var plotWidth = width - root.graphLabelMargin

          function xFor(i) { return (i / (series.length - 1)) * plotWidth }
          function yFor(v) {
            var c = Math.max(yMin, Math.min(yMax, v))
            return height - ((c - yMin) / range) * height
          }

          // Thin threshold lines (not shaded bands) - gold for high, red for
          // low - matching the official Dexcom app's own graph. Lines stop
          // at the plot edge; labels sit past them with a clear gap.
          if (typeof th.high === "number") {
            var highY = yFor(th.high)
            ctx.strokeStyle = "#e0a030"
            ctx.lineWidth = 1
            ctx.beginPath()
            ctx.moveTo(0, highY)
            ctx.lineTo(plotWidth, highY)
            ctx.stroke()
            ctx.fillStyle = "#e0a030"
            ctx.font = "10px sans-serif"
            ctx.fillText(th.high.toFixed(0), plotWidth + 5, highY + 3)
          }
          if (typeof th.low === "number") {
            var lowY = yFor(th.low)
            ctx.strokeStyle = "#e05252"
            ctx.lineWidth = 1
            ctx.beginPath()
            ctx.moveTo(0, lowY)
            ctx.lineTo(plotWidth, lowY)
            ctx.stroke()
            ctx.fillStyle = "#e05252"
            ctx.font = "10px sans-serif"
            ctx.fillText(th.low.toFixed(0), plotWidth + 5, lowY + 3)
          }

          // Faint scale-edge markers at the very top/bottom, same right-side
          // column as the threshold labels.
          ctx.fillStyle = "#555555"
          ctx.font = "9px sans-serif"
          ctx.fillText(yMax.toFixed(0), plotWidth + 5, 9)
          ctx.fillText(yMin.toFixed(0), plotWidth + 5, height - 3)

          // Discrete dots, not a connected line - each reading is a distinct
          // 5-minute sample, not part of a continuous interpolated signal.
          // Matches the official Dexcom app's own graph convention.
          ctx.fillStyle = "#ffffff"
          for (var i = 0; i < series.length - 1; i++) {
            var x = xFor(i)
            var y = yFor(series[i].value)
            ctx.beginPath()
            ctx.arc(x, y, 1, 0, Math.PI * 2)
            ctx.fill()
          }

          // Latest reading is a hollow ring, not a filled dot.
          var lastX = xFor(series.length - 1)
          var lastY = yFor(series[series.length - 1].value)
          ctx.strokeStyle = "#ffffff"
          ctx.lineWidth = 1.5
          ctx.beginPath()
          ctx.arc(lastX, lastY, 4, 0, Math.PI * 2)
          ctx.stroke()
        }
      }

      Row {
        width: parent.width - root.graphLabelMargin

        Repeater {
          model: {
            var series = root.series
            if (!series || series.length < 2) return []
            var idxs = [0, Math.floor(series.length / 3), Math.floor((2 * series.length) / 3)]
            var out = []
            for (var i = 0; i < idxs.length; i++) {
              var p = series[idxs[i]]
              out.push(typeof p.secondsAgo === "number" ? root.formatClockTime(p.secondsAgo) : "")
            }
            out.push("Now")
            return out
          }

          Text {
            required property var modelData
            required property int index
            readonly property bool isNow: index === 3

            width: parent.width / 4
            horizontalAlignment: index === 0 ? Text.AlignLeft : (isNow ? Text.AlignRight : Text.AlignHCenter)
            text: modelData
            color: isNow ? "#ffffff" : "#888888"
            font.pixelSize: 10
            font.bold: isNow
          }
        }
      }

      Rectangle {
        width: pillRow.implicitWidth + 20
        height: 22
        radius: height / 2
        color: "#2a2a2a"

        Row {
          id: pillRow
          anchors.centerIn: parent
          spacing: 5

          Rectangle {
            width: 8
            height: 8
            radius: 4
            anchors.verticalCenter: parent.verticalCenter
            color: root.colorFor(root.status)
          }
          Text {
            text: root.minutesAgo !== null ? (root.minutesAgo + " mins ago") : "time unknown"
            color: "#cccccc"
            font.pixelSize: 11
          }
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

      Text {
        width: parent.width
        text: "Informational only, not medical advice. Use at your own risk."
        color: "#555555"
        font.pixelSize: 9
        font.italic: true
        wrapMode: Text.WordWrap
      }
    }
  }

  Connections {
    target: root
    function onSeriesChanged() { graphCanvas.requestPaint() }
    function onStatusChanged() { graphCanvas.requestPaint() }
  }
}
