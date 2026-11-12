import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import qs.Commons as Commons
import "Art.js" as Art
import "Sun.js" as Sun

// heliodim in the bar: an icon of where the sun stands, and a panel with
// today's sky, the brightness heliodim holds and the offset you gave it.
//
// The daemon (heliodim run, a systemd user service) owns the screen. It writes
// $XDG_RUNTIME_DIR/heliodim.json on every change; this widget only reads it
// and draws. The sun itself is computed here from the same lat/lon with the
// same formula, so the icon moves even while the daemon sleeps.
Panel {
  id: root
  moduleName: "dmustache.heliodim"
  ipcTarget: "dmustache.heliodim"

  // ---- state from the daemon; null while heliodim is not running
  property var daemon: null
  property real now: Date.now()

  readonly property bool running: daemon !== null
  readonly property var sun: running ? Sun.position(daemon.lat, daemon.lon, now) : null
  readonly property var iconRows: sun ? Sun.iconRows(sun) : Art.states[2].rows
  readonly property real curvePct: sun ? Sun.curve(sun.elevation, daemon.min, daemon.max) : 0
  readonly property bool paused: running && daemon.paused_until > 0
  readonly property bool rising: sun ? sun.azimuth < 180 : true
  readonly property bool hasOffset: running && Math.abs(daemon.offset) >= 0.05
  property var today: null

  readonly property color ink: bar ? bar.foreground : Commons.Color.foreground
  readonly property color dim: Qt.darker(ink, 1.4)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  function parse(text) {
    try {
      var s = JSON.parse(text)
      return typeof s.lat === "number" && typeof s.lon === "number" ? s : null
    } catch (e) {
      return undefined
    }
  }

  function refreshDay() {
    root.today = running ? Sun.day(daemon.lat, daemon.lon, now) : null
  }

  function signal(name) {
    if (!running || ctl.running) return
    ctl.command = ["kill", "-" + name, String(daemon.pid)]
    ctl.running = true
  }

  function stateLine() {
    if (!running) return "NOT RUNNING"
    var where = sun.elevation >= Sun.HORIZON ? (rising ? "RISING" : "SETTING") : "BELOW THE HORIZON"
    return "SUN " + sun.elevation.toFixed(1) + "° · " + where
  }

  function nextLine() {
    if (!running) return ""
    if (paused) return "paused until " + Sun.clock(daemon.paused_until * 1000)
    var minutes = Math.round((daemon.next * 1000 - now) / 60000)
    if (minutes <= 0) return "now"
    if (minutes < 120) return "in " + minutes + " min"
    return "at " + Sun.clock(daemon.next * 1000)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onDaemonChanged: refreshDay()
  onOpenedChanged: if (opened) { now = Date.now(); refreshDay() }

  FileView {
    id: stateFile
    path: Quickshell.env("XDG_RUNTIME_DIR") + "/heliodim.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    // An empty read lands between the daemon's truncate and write: keep the
    // last good state rather than flashing "not running".
    onLoaded: {
      var s = root.parse(text())
      if (s !== undefined) root.daemon = s
    }
    onLoadFailed: root.daemon = null
  }

  // The icon only changes state every few degrees; once a minute is plenty.
  // The open panel ticks faster so "next step" counts down.
  Timer {
    interval: root.opened ? 10000 : 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      var before = new Date(root.now).getDate()
      root.now = Date.now()
      if (new Date(root.now).getDate() !== before) root.refreshDay()
    }
  }

  Process { id: ctl }

  // ---- bar icon: the 12x12 pixel map, one canvas pixel per map cell, in the
  // bar's text color. A Canvas keeps its item bounds, so every state lands at
  // the same size and place.
  Component {
    id: sunIcon
    Canvas {
      width: 12
      height: 12
      opacity: root.running ? 1 : 0.45
      property var rows: root.iconRows
      property color fill: root.ink
      onRowsChanged: requestPaint()
      onFillChanged: requestPaint()
      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        ctx.fillStyle = fill
        for (var y = 0; y < rows.length; y++)
          for (var x = 0; x < rows[y].length; x++)
            if (rows[y][x] === "#") ctx.fillRect(x, y, 1, 1)
      }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: sunIcon
    tooltipText: ""
    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.signal("USR2")
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(320))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(520))

    content: PanelKeyCatcher {
      implicitHeight: column.implicitHeight
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(14)

        // ---------- Hero: the sundial mark · name · sun
        Item {
          width: parent.width
          implicitHeight: Math.max(logo.height, heroLabels.implicitHeight)

          Canvas {
            id: logo
            readonly property int cell: Math.max(2, Math.round(Style.font.display / 8))
            width: Art.logo[0].length * cell
            height: Art.logo.length * cell
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            property color fill: root.ink
            onFillChanged: requestPaint()
            onPaint: {
              var ctx = getContext("2d")
              ctx.reset()
              ctx.fillStyle = fill
              for (var y = 0; y < Art.logo.length; y++)
                for (var x = 0; x < Art.logo[y].length; x++)
                  if (Art.logo[y][x] === "#") ctx.fillRect(x * cell, y * cell, cell, cell)
            }
          }

          Column {
            id: heroLabels
            anchors.left: logo.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Heliodim"
              textFormat: Text.PlainText
              color: root.ink
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              text: root.stateLine()
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }
        }

        // ---------- Not running
        Text {
          visible: !root.running
          width: parent.width
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: "The heliodim service is not running. Start it with:\nsystemctl --user enable --now heliodim"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        PanelSeparator { visible: root.running; foreground: root.ink }

        // ---------- Sky: today's elevation, midnight to midnight
        Canvas {
          id: sky
          visible: root.running && root.today !== null
          width: parent.width
          height: Style.space(96)
          property var day: root.today
          property real nowMs: root.now
          property color fill: root.ink
          onDayChanged: requestPaint()
          onNowMsChanged: requestPaint()
          onFillChanged: requestPaint()
          onWidthChanged: requestPaint()
          onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            if (!day) return
            var labelH = Style.font.caption + 4
            var top = 6, base = Math.round((height - labelH) * 0.62)
            var bottom = height - labelH - 2
            var hi = Math.max(20, day.peak + 6), lo = -60
            function x(m) { return m / 1440 * width }
            function y(el) { return el >= 0 ? base - el / hi * (base - top) : base + Math.min(1, el / lo) * (bottom - base) }

            // the day: area above the horizon
            ctx.fillStyle = Qt.rgba(fill.r, fill.g, fill.b, 0.12)
            ctx.beginPath()
            ctx.moveTo(0, base)
            for (var i = 0; i < day.samples.length; i++) ctx.lineTo(x(i * 5), Math.min(base, y(day.samples[i])))
            ctx.lineTo(width, base)
            ctx.closePath()
            ctx.fill()

            // the night part of the path, dashed by hand
            ctx.fillStyle = Qt.rgba(fill.r, fill.g, fill.b, 0.45)
            for (var j = 0; j < day.samples.length; j += 2)
              if (day.samples[j] < 0) ctx.fillRect(x(j * 5), y(day.samples[j]), 1.5, 1.5)

            // the day part of the path
            ctx.strokeStyle = fill
            ctx.lineWidth = 1.5
            ctx.beginPath()
            var pen = false
            for (var k = 0; k < day.samples.length; k++) {
              if (day.samples[k] < 0) { pen = false; continue }
              if (!pen) { ctx.moveTo(x(k * 5), y(day.samples[k])); pen = true }
              else ctx.lineTo(x(k * 5), y(day.samples[k]))
            }
            ctx.stroke()

            // horizon
            ctx.fillStyle = Qt.rgba(fill.r, fill.g, fill.b, 0.4)
            ctx.fillRect(0, base, width, 1)

            // sunrise, noon, sunset
            ctx.font = Style.font.caption + "px \"" + root.fontFamily + "\""
            ctx.textAlign = "center"
            var marks = [day.rise, day.noon, day.set]
            for (var t = 0; t < marks.length; t++) {
              if (marks[t] === null) continue
              var mx = Math.max(16, Math.min(width - 16, x(marks[t])))
              ctx.fillStyle = Qt.rgba(fill.r, fill.g, fill.b, 0.55)
              ctx.fillRect(x(marks[t]), base, 1, 5)
              ctx.fillStyle = Qt.rgba(fill.r, fill.g, fill.b, 0.75)
              ctx.fillText(Sun.minutesClock(marks[t]), mx, height - 2)
            }

            // now
            var nm = (nowMs - day.start) / 60000
            var el = Sun.position(root.daemon.lat, root.daemon.lon, nowMs).elevation
            ctx.beginPath()
            ctx.arc(x(nm), y(el), 4, 0, Math.PI * 2)
            ctx.fillStyle = el > 0 ? fill : Commons.Color.popups.background
            ctx.fill()
            ctx.strokeStyle = fill
            ctx.lineWidth = 1.5
            ctx.stroke()
          }
        }

        PanelSeparator { visible: root.running; foreground: root.ink }

        // ---------- Brightness: on screen, and where the sun alone would put it
        Column {
          visible: root.running
          width: parent.width
          spacing: Style.space(6)

          Item {
            width: parent.width
            implicitHeight: brightnessHeader.implicitHeight
            PanelSectionHeader {
              id: brightnessHeader
              text: "Brightness"
              foreground: root.ink
              fontFamily: root.fontFamily
              anchors.left: parent.left
            }
            Text {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.running ? Math.round(root.daemon.pct) + "%" : ""
              color: root.ink
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }

          Item {
            width: parent.width
            height: Style.space(6)
            Rectangle {
              anchors.fill: parent
              color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.1)
            }
            Rectangle {
              height: parent.height
              width: root.running ? parent.width * Math.max(0, Math.min(100, root.daemon.pct)) / 100 : 0
              color: root.ink
            }
            // the sun curve alone; the gap to the fill is your offset
            Rectangle {
              x: parent.width * Math.max(0, Math.min(100, root.curvePct)) / 100 - width / 2
              y: -Style.space(3)
              width: 1
              height: parent.height + Style.space(6)
              color: Commons.Color.accent
            }
          }
        }

        // ---------- Facts
        Column {
          visible: root.running
          width: parent.width
          spacing: 0

          Repeater {
            model: root.running ? [
              ["sun curve", root.curvePct.toFixed(1) + "%"],
              ["your offset", Sun.signed(root.daemon.offset)
                + (root.hasOffset && root.daemon.offset_t > 0 ? " · since " + Sun.clock(root.daemon.offset_t * 1000) : "")],
              ["next step", root.nextLine()],
              ["location", root.daemon.lat.toFixed(2) + ", " + root.daemon.lon.toFixed(2) + " · " + root.daemon.source]
            ] : []

            delegate: Item {
              required property var modelData
              width: column.width
              implicitHeight: Math.max(key.implicitHeight, value.implicitHeight) + Style.space(12)

              Rectangle {
                width: parent.width
                height: 1
                color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.12)
              }
              Text {
                id: key
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: modelData[0]
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                id: value
                anchors.right: parent.right
                anchors.left: key.right
                anchors.leftMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignRight
                elide: Text.ElideLeft
                text: modelData[1]
                color: root.ink
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }
          }
        }

        // ---------- Actions
        Row {
          visible: root.running
          width: parent.width
          spacing: Style.space(8)

          Button {
            width: (parent.width - parent.spacing) / 2
            text: root.paused ? "Resume" : "Pause"
            tooltipText: root.paused ? "Follow the sun again" : "Leave brightness to you until the next sunrise or sunset"
            bordered: true
            foreground: root.ink
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: root.signal("USR2")
          }

          Button {
            width: (parent.width - parent.spacing) / 2
            text: "Forget offset"
            tooltipText: "Return to the plain sun curve"
            bordered: true
            enabled: root.hasOffset
            opacity: enabled ? 1 : 0.4
            foreground: root.ink
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: root.signal("USR1")
          }
        }
      }
    }
  }
}
