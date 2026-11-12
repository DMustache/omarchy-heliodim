import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root
  visible: false

  readonly property string launcher: Quickshell.env("HOME") + "/.config/omarchy/plugins/dmustache.heliodim/bin/heliodim"

  Process {
    id: daemon
    command: [root.launcher, "run"]
    running: true
    onExited: retry.start()
  }

  Timer {
    id: retry
    interval: 30000
    onTriggered: daemon.running = true
  }

  Component.onDestruction: daemon.running = false
}
