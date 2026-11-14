import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The running tminus timer in the bar. It follows `t- ctl status --follow`,
// which prints a line of Waybar-style JSON per change and never ends on its
// own (an idle line while no timer runs), and steers the timer it shows with
// `t- ctl -n NAME ...`.
BarWidget {
  id: root
  moduleName: "io.github.seaglenet.tminus"

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  readonly property string command: String(setting("command", "t-")).trim() || "t-"
  readonly property string followName: String(setting("name", "")).trim()
  readonly property string step: String(setting("step", "1m")).trim() || "1m"
  readonly property string startArgs: String(setting("start", "")).trim()

  // From the last status line.
  property string clock: ""
  property string tooltip: ""
  property string timerState: "idle"
  property string timerName: ""
  // The follow process could not run (t- missing, or exited with an error).
  property bool broken: false

  readonly property bool running: timerState !== "idle" && clock !== ""
  readonly property bool canStart: startArgs !== ""
  // Font Awesome glyphs from the bar's Nerd Font.
  readonly property string glyph: timerState === "paused" ? "\uf04c"
    : (timerState === "done" || timerState === "waiting") ? "\uf0f3"
    : "\uf252"

  visible: running || canStart
  implicitWidth: visible ? button.implicitWidth : 0
  implicitHeight: barSize

  function update(line) {
    var data
    try { data = JSON.parse(line) } catch (e) { return }
    if (!Util.isPlainObject(data)) return
    root.broken = false
    root.timerState = String(data["class"] || "idle")
    // Bounded: a label or title can be as long as anyone typed it.
    root.clock = String(data.text || "").slice(0, 80)
    root.tooltip = String(data.tooltip || "").slice(0, 600)
    root.timerName = typeof data.name === "string" ? data.name : ""
  }

  // `t- ctl [-n NAME] <words>`, aimed at the timer on display. No shell
  // parses the words: they only land in bash's positional parameters, and
  // the login shell gives t- the PATH a terminal would.
  function ctl(words) {
    var argv = [root.command, "ctl"]
    var name = root.timerName || root.followName
    if (name) argv.push("-n", name)
    Util.execArgv(argv.concat(words))
  }

  function start() {
    // The start arguments are shell words the user wrote into shell.json
    // (`25m:work 5m:break x4`); quoting the binary keeps a path with spaces.
    if (root.bar) root.bar.run(Util.shellQuote(root.command) + " " + root.startArgs + " --headless")
  }

  Process {
    id: follow
    command: {
      var argv = ["bash", "-lc", 'exec "$@"', "bash", root.command, "ctl"]
      if (root.followName) argv.push("-n", root.followName)
      return argv.concat(["status", "--follow"])
    }
    running: true
    stdout: SplitParser {
      onRead: function(line) { root.update(line) }
    }
    // Following never ends by itself, so an exit means t- is missing, too old
    // or was killed: show nothing and try again in a while.
    onExited: function(exitCode) {
      root.broken = true
      root.timerState = "idle"
      root.clock = ""
      retry.start()
    }
  }

  // Changing the command or name in shell.json restarts the follower.
  onCommandChanged: restart()
  onFollowNameChanged: restart()
  function restart() {
    retry.stop()
    follow.running = false
    follow.running = true
  }

  Timer {
    id: retry
    interval: 10000
    onTriggered: follow.running = true
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.running
      ? (root.vertical ? root.glyph : root.glyph + "  " + root.clock)
      : root.glyph
    active: root.timerState === "alert" || root.timerState === "done" || root.timerState === "waiting"
    dimmed: root.timerState === "paused" || !root.running
    tooltipText: root.running ? root.tooltip
      : root.broken ? strings.t("tooltip.missing").arg(root.command)
      : strings.t("tooltip.start").arg(root.startArgs)

    onPressed: function(b) {
      if (!root.running) {
        if (b === Qt.LeftButton && root.canStart) root.start()
        return
      }
      if (b === Qt.RightButton) root.ctl(["stop"])
      else if (b === Qt.MiddleButton) root.ctl(["next"])
      else if (root.timerState === "waiting") root.ctl(["next"])
      else if (root.timerState === "done") root.ctl(["stop"])
      else root.ctl(["toggle"])
    }
    onWheelMoved: function(delta) {
      if (!root.running || delta === 0) return
      root.ctl([delta > 0 ? "add" : "sub", root.step])
    }
  }
}
