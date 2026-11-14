pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Logic.js" as Logic

// The running tminus timer in the bar. It follows `t- ctl status --follow`,
// which prints a line of Waybar-style JSON per change and never ends on its
// own (an idle line while no timer runs), and steers the timer it shows with
// `t- ctl -n NAME ...`. Right click opens a popup with every running timer
// (`t- ctl list --json`, re-read every second while it is open).
BarWidget {
  id: root
  moduleName: "seaglenet.tminus"

  Commons.Translations {
    id: strings
    directory: Qt.resolvedUrl("i18n")
  }

  // A leading `~/` is expanded here: no shell sees the command to do it.
  readonly property string command: Logic.expandHome(setting("command", "t-"), Quickshell.env("HOME"))
  readonly property string followName: String(setting("name", "")).trim()
  // A timer picked in the popup, shown in the bar instead of the newest one
  // until it ends. Not saved: a shell restart goes back to the setting.
  property string pinnedName: ""
  readonly property string shownName: pinnedName || followName
  readonly property string step: String(setting("step", "1m")).trim() || "1m"
  readonly property string startArgs: String(setting("start", "")).trim()

  // From the last status line.
  property string clock: ""
  property string tooltip: ""
  property string timerState: "idle"
  property string timerName: ""
  // The follow process could not run (t- missing, or exited with an error).
  property bool broken: false

  // From the last `t- ctl list --json`, while the popup is open. Rows are
  // updated in place: rebuilding them every second would tear down whatever
  // the mouse is over, so buttons blink and lose their hover.
  ListModel {
    id: timerModel
  }
  // One row's height (they're all alike), for the list's four-row cap.
  property real timerRowHeight: Style.space(40)
  property bool popupOpen: false

  readonly property bool running: timerState !== "idle" && clock !== ""
  readonly property bool canStart: startArgs !== ""

  // Material Design glyphs from the bar's Nerd Font, like the media widget's
  // (slimmer than Font Awesome); above U+FFFF, hence fromCodePoint.
  readonly property string iconPause: String.fromCodePoint(0xF03E4)
  readonly property string iconPlay: String.fromCodePoint(0xF040A)
  readonly property string iconNext: String.fromCodePoint(0xF04AD)
  readonly property string iconStop: String.fromCodePoint(0xF04DB)
  readonly property string iconBell: String.fromCodePoint(0xF009C)
  readonly property string iconTimer: String.fromCodePoint(0xF051F)
  // The buttons on each timer row are packed tight, leaving the row's text
  // as much room as they can.
  readonly property real rowButtonPadding: Style.space(4)

  readonly property string iconTerminal: String.fromCodePoint(0xF07B7)
  readonly property string iconMinus: String.fromCodePoint(0xF0374)
  readonly property string iconPlus: String.fromCodePoint(0xF0415)

  function glyphFor(state) {
    if (state === "paused")
      return iconPause
    if (state === "done" || state === "waiting")
      return iconBell
    return iconTimer
  }

  visible: running || canStart
  implicitWidth: visible ? button.implicitWidth : 0
  implicitHeight: barSize

  function close() {
    popupOpen = false
  }

  function update(line) {
    var status = Logic.parseStatus(line)
    if (!status)
      return
    root.broken = false
    // The picked timer is gone: back to the newest (or the configured one).
    if (status.state === "idle" && root.pinnedName) {
      root.pinnedName = ""
      return
    }
    root.timerState = status.state
    // In the final seconds, every tick flashes white and fades to red.
    if (root.timerState === "alert" && status.clock !== root.clock) {
      root.alertFlash = true
      alertFlashEnd.restart()
    }
    root.clock = status.clock
    root.tooltip = status.tooltip
    root.timerName = status.name
  }

  function updateList(raw) {
    var list = Logic.parseTimerList(raw)
    if (!list)
      return
    for (var j = 0; j < list.length; j++) {
      if (j < timerModel.count && timerModel.get(j).name === list[j].name) {
        timerModel.set(j, list[j])
      } else {
        if (j < timerModel.count)
          timerModel.remove(j, timerModel.count - j)
        timerModel.append(list[j])
      }
    }
    if (timerModel.count > list.length)
      timerModel.remove(list.length, timerModel.count - list.length)
  }

  // `t- ctl -n NAME <words>`. No shell parses the words: they only land in
  // bash's positional parameters, and the login shell gives t- the PATH a
  // terminal would.
  function ctlFor(name, words) {
    var argv = ["bash", "-lc", 'exec "$@"', "bash", root.command, "ctl"]
    if (name)
      argv.push("-n", name)
    // A stopped timer leaves the list at once, not when it has quit.
    if (words[0] === "stop" && name)
      root.dropRow(name)
    var p = ctlRunner.createObject(root, {
      command: argv.concat(words)
    })
    p.running = true
  }

  // Each command is its own process; the list is read again as soon as one
  // has done its work, instead of after a guess at how long that takes.
  Component {
    id: ctlRunner
    Process {
      onExited: {
        root.listChanged()
        destroy()
      }
    }
  }

  function dropRow(name) {
    for (var i = 0; i < timerModel.count; i++) {
      if (timerModel.get(i).name === name) {
        timerModel.remove(i)
        return
      }
    }
  }

  // Show a timer with its clock and effects. A bar-only timer moves into a
  // new terminal (`t- ctl attach` takes it over there, same name); one with
  // a window already gets that window focused.
  function openWindow(timer) {
    if (timer.headless) {
      // If attaching fails (an older t-), keep the terminal open to read why.
      Util.execArgv(["omarchy-launch-tui", "--app-id=org.omarchy.tminus", "bash", "-c", attachScript, "attach", root.command, timer.name])
    } else if (timer.pid > 1) {
      // The window belongs to the terminal: walk up from t- to a process
      // Hyprland knows as a client. The pid is a number from t-'s JSON.
      Util.execArgv(["bash", "-c", focusScript, "focus", String(timer.pid)])
    }
    root.close()
  }

  readonly property string attachScript: '"$1" ctl -n "$2" attach || read -rsn1 -p "Press a key to close"'

  readonly property string focusScript: 'p=$1; clients=$(hyprctl clients -j | jq -r ".[].pid"); ' + 'while [ "${p:-0}" -gt 1 ]; do ' + 'if grep -qx "$p" <<<"$clients"; then exec hyprctl dispatch focuswindow "pid:$p"; fi; ' + 'p=$(ps -o ppid= -p "$p" | tr -d " "); done'

  // Aimed at the timer on display.
  function ctl(words) {
    ctlFor(root.timerName || root.shownName, words)
  }

  // `t- <args> --headless`: a timer that lives only in the bar. `t- --check`
  // looks at the arguments first (and the config, presets, themes, name),
  // so a mistake shows under the start field instead of as a notification;
  // the timer itself is started detached, to outlive the shell.
  // `fromField`: clear the field once it started.
  property string startError: ""
  function startWith(args, fromField) {
    var argv = Logic.words(args)
    if (argv.length === 0 || checker.running)
      return
    checker.argv = argv
    checker.fromField = fromField
    checker.command = ["bash", "-lc", 'exec "$@"', "bash", root.command, "--check"].concat(argv, ["--headless"])
    checker.running = true
  }

  function started(argv, fromField) {
    root.startError = ""
    // A timer just started is the one to see, as without a pick.
    root.pinnedName = ""
    Util.execArgv([root.command].concat(argv, ["--headless"]))
    if (fromField) {
      startField.text = ""
      root.clearSuggestions()
    }
    if (root.popupOpen)
      refreshSoon.restart()
  }

  Process {
    id: checker
    property var argv: []
    property bool fromField: false
    stderr: StdioCollector {
      id: checkerErrors
    }
    onExited: function (exitCode) {
      if (exitCode === 0)
        root.started(checker.argv, checker.fromField)
      else
        root.startError = Logic.errorLine(checkerErrors.text) || strings.t("popup.startFailed").arg(exitCode)
    }
  }

  function start() {
    root.startWith(root.startArgs, false)
  }

  // Completion for the start field, from t- itself: clap's dynamic
  // completion answers `COMPLETE=fish t- -- t- <words>` with one
  // `candidate<TAB>description` line per match for the last word.
  property var suggestions: []
  // Where the word the suggestions were fetched for starts: a new word (after
  // a space or an accepted suggestion) drops them.
  property int suggestionsStart: -1
  property int suggestionIndex: 0
  // The field text the running request belongs to.
  property string requestedText: ""
  // The last answer, narrowed to what still fits the word being typed: it
  // stays on screen while t- is asked again after each key, instead of
  // blinking out until the new answer arrives.
  readonly property var shownSuggestions: {
    var text = startField.text
    var start = Logic.currentWordStart(text)
    if (start < 0 || start !== root.suggestionsStart)
      return []
    var word = text.slice(start)
    return root.suggestions.filter(function (item) {
      return item.value.indexOf(word) === 0 && item.value !== word
    })
  }
  readonly property int shownIndex: Math.min(root.suggestionIndex, root.shownSuggestions.length - 1)

  function complete(text) {
    var start = Logic.currentWordStart(text)
    if (start < 0) {
      root.setSuggestions(text, [])
      return
    }
    root.requestedText = text
    if (completer.running)
      // picked up when it exits
      return
    var argv = Logic.completionArgs(text)
    completer.command = ["bash", "-lc", 'COMPLETE=fish exec "$@"', "bash", root.command, "--", "t-"].concat(argv)
    completer.forText = text
    completer.running = true
  }

  function setSuggestions(text, list) {
    root.suggestionsStart = Logic.currentWordStart(text)
    root.suggestions = list
    root.suggestionIndex = 0
  }

  function clearSuggestions() {
    completionDebounce.stop()
    root.requestedText = ""
    root.setSuggestions("", [])
  }

  // Replace the word being typed with a suggestion and move on to the next.
  function acceptSuggestion(index) {
    var item = root.shownSuggestions[index]
    var text = startField.text
    var start = Logic.currentWordStart(text)
    if (!item || start < 0)
      return
    startField.text = text.slice(0, start) + item.value + " "
    startField.cursorPosition = startField.text.length
  }

  Process {
    id: completer
    property string forText: ""
    stdout: StdioCollector {
      onStreamFinished: {
        // Only for the text it was asked about; typing on asks again.
        if (completer.forText === startField.text)
          root.setSuggestions(completer.forText, Logic.parseSuggestions(completer.forText, text))
      }
    }
    onExited: {
      if (root.requestedText !== completer.forText && root.requestedText === startField.text)
        Qt.callLater(function () {
          root.complete(startField.text)
        })
    }
  }

  Timer {
    id: completionDebounce
    interval: 80
    onTriggered: {
      if (startField.text.trim() === "")
        root.clearSuggestions()
      else
        root.complete(startField.text)
    }
  }

  Process {
    id: follow
    command: {
      var argv = ["bash", "-lc", 'exec "$@"', "bash", root.command, "ctl"]
      if (root.shownName)
        argv.push("-n", root.shownName)
      return argv.concat(["status", "--follow"])
    }
    running: true
    stdout: SplitParser {
      onRead: function (line) {
        root.update(line)
      }
    }
    // Following never ends by itself, so an exit means t- is missing, too old
    // or was killed: show nothing and try again in a while.
    onExited: function (exitCode) {
      // Stopped on purpose to follow another timer: start it again at once.
      if (root.restarting) {
        root.restarting = false
        follow.running = true
        return
      }
      root.broken = true
      root.timerState = "idle"
      root.clock = ""
      retry.start()
    }
  }

  // Changing the command or the timer to show restarts the follower.
  onCommandChanged: restart()
  onShownNameChanged: restart()
  property bool restarting: false
  function restart() {
    retry.stop()
    if (follow.running) {
      root.restarting = true
      follow.running = false
    } else {
      follow.running = true
    }
  }

  Timer {
    id: retry
    interval: 10000
    onTriggered: follow.running = true
  }

  Process {
    id: lister
    property int generation: 0
    command: ["bash", "-lc", 'exec "$@"', "bash", root.command, "ctl", "list", "--json"]
    stdout: StdioCollector {
      onStreamFinished: {
        if (lister.generation === root.listGeneration)
          root.updateList(text)
      }
    }
    onExited: {
      if (lister.generation !== root.listGeneration && root.popupOpen)
        Qt.callLater(root.refreshList)
    }
  }

  // Bumped whenever a command changed the timers: a list read that was
  // already under way may show the old state, so it is thrown away and read
  // again (a stopped timer would otherwise come back for a moment).
  property int listGeneration: 0
  function listChanged() {
    root.listGeneration++
    if (root.popupOpen)
      root.refreshList()
  }

  function refreshList() {
    if (lister.running)
      return
    lister.generation = root.listGeneration
    lister.running = true
  }

  Timer {
    interval: 1000
    running: root.popupOpen
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshList()
  }

  // After starting a timer, which runs detached: time for it to come up.
  Timer {
    id: refreshSoon
    interval: 300
    onTriggered: root.listChanged()
  }

  onPopupOpenChanged: if (!popupOpen) {
    timerModel.clear()
    clearSuggestions()
    startError = ""
  }

  // The alert pulse: white for a moment after each tick, then red again.
  // Two plain color changes; the button's own color transition fades
  // between them (animating the color here would fight that transition).
  property bool alertFlash: false
  Timer {
    id: alertFlashEnd
    interval: 250
    onTriggered: root.alertFlash = false
  }

  WidgetButton {
    id: button
    activeColor: root.timerState === "alert" && root.alertFlash && !Style.reduceMotion ? root.bar.barForeground : root.bar.urgent
    anchors.fill: parent
    bar: root.bar
    text: root.running ? (root.vertical ? root.glyphFor(root.timerState) : root.glyphFor(root.timerState) + " " + root.clock) : root.iconTimer
    active: root.timerState === "alert" || root.timerState === "done" || root.timerState === "waiting"
    dimmed: root.timerState === "paused" || !root.running
    tooltipText: root.popupOpen ? "" : root.running ? root.tooltip : root.broken ? strings.t("tooltip.missing").arg(root.command) : strings.t("tooltip.start").arg(root.startArgs)

    onPressed: function (b) {
      if (b === Qt.RightButton) {
        root.popupOpen = !root.popupOpen
        return
      }
      if (!root.running) {
        if (b === Qt.LeftButton && root.canStart)
          root.start()
        return
      }
      if (b === Qt.MiddleButton || root.timerState === "waiting")
        root.ctl(["next"])
      else if (root.timerState === "done")
        root.ctl(["stop"])
      else
        root.ctl(["toggle"])
    }
    onWheelMoved: function (delta) {
      if (!root.running || delta === 0)
        return
      root.ctl([delta > 0 ? "add" : "sub", root.step])
    }
  }

  // A KeyboardPanel rather than a PopupCard: an xdg-popup only gets keys
  // after a click inside it, and the start field should take typing at once.
  KeyboardPanel {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    focusTarget: startField
    contentWidth: popup.fittedContentWidth(Style.space(380))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    Column {
      id: column
      anchors.fill: parent
      spacing: Style.space(6)

      Text {
        textFormat: Text.PlainText
        visible: timerModel.count === 0
        text: strings.t("popup.empty")
        color: Qt.darker(root.bar.foreground, 1.5)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        topPadding: Style.space(6)
        bottomPadding: Style.space(6)
      }

      // The timers, scrolling once there are more than four. The scroll bar
      // sits in the card's padding, beside the rows, so it showing up
      // doesn't narrow or shift them.
      Item {
        id: timerArea
        width: parent.width
        height: timerFlick.height
        visible: timerModel.count > 0

        Flickable {
          id: timerFlick
          width: parent.width
          height: Math.min(contentHeight, root.timerRowHeight * 4 + timerList.spacing * 3)
          contentWidth: width
          contentHeight: timerList.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          interactive: contentHeight > height

          ScrollBar.vertical: ScrollBar {
            id: timerScroll
            parent: timerArea
            anchors.left: timerFlick.right
            anchors.leftMargin: Style.space(3)
            anchors.top: timerFlick.top
            anchors.bottom: timerFlick.bottom
            // Always shown while the list scrolls, as the sign that it does;
            // it's in the margin, so it costs the rows nothing.
            policy: timerFlick.interactive ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
            // Qt's default handle is dark-on-dark here; this one takes the
            // theme's text color.
            contentItem: Rectangle {
              implicitWidth: Style.space(4)
              radius: width / 2
              color: root.bar.foreground
              opacity: timerScroll.pressed ? 0.6 : (timerScroll.hovered ? 0.45 : 0.3)
            }
            background: Item {}
          }

          Column {
            id: timerList
            width: timerFlick.width
            spacing: column.spacing

            Repeater {
              model: timerModel

              BorderSurface {
                id: timerRow
                required property string name
                required property string timerState
                required property string clock
                required property string title
                required property string segment
                required property bool headless
                required property int pid

                readonly property var timer: ({
                    name: name,
                    state: timerState,
                    clock: clock,
                    title: title,
                    segment: segment,
                    headless: headless,
                    pid: pid
                  })
                readonly property bool shown: timer.name === root.timerName
                readonly property bool ended: timer.state === "done" || timer.state === "waiting"

                width: timerList.width
                onHeightChanged: if (height > 0)
                  root.timerRowHeight = height
                height: rowInner.implicitHeight + Style.space(10)
                radius: Style.spacing.labelGap
                color: shown ? Style.selectedFillFor(root.bar.foreground, Commons.Color.accent) : "transparent"
                // Room for the border is kept on every row, so moving the
                // highlight doesn't shift the text and buttons.
                readonly property var shownSpec: Border.controlSpec("normal", root.bar.foreground, Commons.Color.accent)
                // The other rows get a faint outline of the same width, so
                // each timer reads as its own box.
                readonly property var restSpec: Border.flat(Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.15), Border.uniformWidth(shownSpec))
                borderSpec: shown ? shownSpec : restSpec

                // Click a row to show that timer in the bar. Under the row's
                // content, so its buttons keep their own clicks.
                MouseArea {
                  anchors.fill: parent
                  enabled: !timerRow.shown
                  cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                  onClicked: root.pinnedName = timerRow.timer.name
                }

                // Icon across both lines; clock and title, then the details, which
                // have the whole width; the controls sit on the first line. The text
                // sets the height, so the buttons don't make rows taller.
                Item {
                  id: rowInner
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Border.left(timerRow.shownSpec) + Style.space(8)
                  anchors.rightMargin: Border.right(timerRow.shownSpec) + Style.space(4)
                  implicitHeight: rowText.implicitHeight

                  // The whole text, when either line had to be cut short.
                  PanelToolTip {
                    visible: (titleHover.hovered || detailHover.hovered) && (rowTitle.truncated || rowDetail.truncated)
                    text: rowTitle.text + "\n" + rowDetail.text
                  }

                  Text {
                    id: rowGlyph
                    textFormat: Text.PlainText
                    text: root.glyphFor(timerRow.timer.state)
                    color: timerRow.ended || timerRow.timer.state === "alert" ? root.bar.urgent : root.bar.foreground
                    opacity: timerRow.timer.state === "paused" ? 0.6 : 1
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.body
                    width: Style.space(12)
                    horizontalAlignment: Text.AlignHCenter
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Column {
                    id: rowText
                    anchors.left: rowGlyph.right
                    anchors.leftMargin: Style.space(6)
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(1)

                    Text {
                      id: rowTitle
                      textFormat: Text.PlainText
                      text: timerRow.timer.clock + "  " + (timerRow.timer.title || timerRow.timer.name)
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.bold: timerRow.shown
                      elide: Text.ElideRight
                      width: parent.width - controls.width - Style.space(8)

                      HoverHandler {
                        id: titleHover
                      }
                    }

                    Text {
                      id: rowDetail
                      textFormat: Text.PlainText
                      text: {
                        var parts = [timerRow.timer.name]
                        if (timerRow.timer.segment)
                          parts.push(timerRow.timer.segment)
                        parts.push(strings.t(timerRow.timer.headless ? "mode.headless" : "mode.window"))
                        return parts.join(" \u00b7 ")
                      }
                      color: Qt.darker(root.bar.foreground, 1.5)
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                      width: parent.width

                      HoverHandler {
                        id: detailHover
                      }
                    }
                  }

                  Row {
                    id: controls
                    // On the first line, over the end of the details line's room.
                    anchors.right: parent.right
                    anchors.verticalCenter: rowText.top
                    anchors.verticalCenterOffset: rowTitle.height / 2
                    spacing: Style.space(2)
                    // Media-style controls keep their order in every language.
                    LayoutMirroring.enabled: false
                    LayoutMirroring.childrenInherit: true

                    // A stepper: minus, the step once, plus.
                    Button {
                      iconText: root.iconMinus
                      foreground: root.bar.foreground
                      horizontalPadding: root.rowButtonPadding
                      verticalPadding: 0
                      tooltipText: strings.t("action.sub").arg(root.step)
                      enabled: !timerRow.ended
                      opacity: enabled ? 1.0 : 0.4
                      onClicked: root.ctlFor(timerRow.timer.name, ["sub", root.step])
                    }

                    Text {
                      textFormat: Text.PlainText
                      anchors.verticalCenter: parent.verticalCenter
                      text: root.step
                      color: Qt.darker(root.bar.foreground, 1.5)
                      opacity: timerRow.ended ? 0.4 : 1.0
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.caption
                    }

                    Button {
                      iconText: root.iconPlus
                      foreground: root.bar.foreground
                      horizontalPadding: root.rowButtonPadding
                      verticalPadding: 0
                      tooltipText: strings.t("action.add").arg(root.step)
                      enabled: !timerRow.ended
                      opacity: enabled ? 1.0 : 0.4
                      onClicked: root.ctlFor(timerRow.timer.name, ["add", root.step])
                    }

                    // A wider gap between the groups: time, playback, window.
                    Item {
                      width: Style.space(6)
                      height: 1
                    }

                    Button {
                      iconText: timerRow.timer.state === "paused" ? root.iconPlay : root.iconPause
                      foreground: root.bar.foreground
                      horizontalPadding: root.rowButtonPadding
                      verticalPadding: 0
                      tooltipText: strings.t(timerRow.timer.state === "paused" ? "action.resume" : "action.pause")
                      enabled: !timerRow.ended
                      opacity: enabled ? 1.0 : 0.4
                      onClicked: root.ctlFor(timerRow.timer.name, ["toggle"])
                    }

                    Button {
                      iconText: root.iconNext
                      foreground: root.bar.foreground
                      horizontalPadding: root.rowButtonPadding
                      verticalPadding: 0
                      tooltipText: strings.t("action.next")
                      // A single timer has no next segment.
                      enabled: timerRow.timer.segment !== ""
                      opacity: enabled ? 1.0 : 0.4
                      onClicked: root.ctlFor(timerRow.timer.name, ["next"])
                    }

                    // A wider gap between the groups: time, playback, window.
                    Item {
                      width: Style.space(6)
                      height: 1
                    }

                    Button {
                      iconText: root.iconTerminal
                      foreground: root.bar.foreground
                      horizontalPadding: root.rowButtonPadding
                      verticalPadding: 0
                      tooltipText: strings.t(timerRow.timer.headless ? "action.attach" : "action.focus")
                      onClicked: root.openWindow(timerRow.timer)
                    }

                    Button {
                      iconText: root.iconStop
                      foreground: root.bar.foreground
                      horizontalPadding: root.rowButtonPadding
                      verticalPadding: 0
                      tooltipText: strings.t("action.stop")
                      onClicked: root.ctlFor(timerRow.timer.name, ["stop"])
                    }
                  }
                }
              }
            }
          }
        }
      }

      PanelSeparator {
        foreground: root.bar.foreground
      }

      Row {
        width: parent.width
        spacing: Style.space(6)

        TextField {
          id: startField
          width: parent.width - startButton.width - parent.spacing
          anchors.verticalCenter: parent.verticalCenter
          placeholderText: strings.t("popup.placeholder")
          foreground: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall

          function submit() {
            root.startWith(text, true)
          }

          onTextChanged: {
            root.startError = ""
            completionDebounce.restart()
          }

          Keys.onPressed: function (event) {
            var count = root.shownSuggestions.length
            var shown = count > 0
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              submit()
              event.accepted = true
            } else if (event.key === Qt.Key_Tab) {
              if (shown)
                root.acceptSuggestion(root.shownIndex)
              event.accepted = true
            } else if (event.key === Qt.Key_Down && shown) {
              root.suggestionIndex = (root.shownIndex + 1) % count
              event.accepted = true
            } else if (event.key === Qt.Key_Up && shown) {
              root.suggestionIndex = (root.shownIndex + count - 1) % count
              event.accepted = true
            } else if (event.key === Qt.Key_Escape) {
              if (shown)
                root.clearSuggestions()
              else
                root.close()
              event.accepted = true
            }
          }
        }

        Button {
          id: startButton
          anchors.verticalCenter: parent.verticalCenter
          iconText: root.iconPlay
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          tooltipText: strings.t("popup.startTyped")
          enabled: startField.text.trim() !== ""
          opacity: enabled ? 1.0 : 0.4
          onClicked: startField.submit()
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: root.startError !== ""
        text: root.startError
        color: root.bar.urgent
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
        width: parent.width
      }

      Column {
        id: suggestionList
        width: parent.width
        spacing: Style.space(1)
        visible: root.shownSuggestions.length > 0

        Repeater {
          model: root.shownSuggestions

          BorderSurface {
            id: suggestionRow
            required property var modelData
            required property int index

            readonly property bool selected: index === root.shownIndex

            width: suggestionList.width
            height: suggestionInner.implicitHeight + Style.space(6)
            radius: Style.spacing.labelGap
            color: selected ? Style.selectedFillFor(root.bar.foreground, Commons.Color.accent) : "transparent"
            borderSpec: Border.none()

            Row {
              id: suggestionInner
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(8)
              anchors.rightMargin: Style.space(8)
              spacing: Style.space(10)

              Text {
                id: suggestionValue
                textFormat: Text.PlainText
                text: suggestionRow.modelData.value
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: suggestionRow.selected
              }

              Text {
                id: suggestionHelp
                textFormat: Text.PlainText
                text: suggestionRow.modelData.help
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                width: parent.width - suggestionValue.width - parent.spacing
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            MouseArea {
              id: suggestionMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: root.suggestionIndex = suggestionRow.index
              onClicked: {
                root.acceptSuggestion(suggestionRow.index)
                startField.forceActiveFocus()
              }
            }

            // The whole description, when the row had to cut it short.
            PanelToolTip {
              visible: suggestionMouse.containsMouse && suggestionHelp.truncated
              text: suggestionRow.modelData.help
            }
          }
        }
      }

      Button {
        visible: root.canStart
        anchors.horizontalCenter: parent.horizontalCenter
        iconText: root.iconPlay
        text: strings.t("popup.start").arg(root.startArgs)
        foreground: root.bar.foreground
        horizontalPadding: Style.spacing.controlPaddingX
        verticalPadding: Style.spacing.controlPaddingY
        onClicked: root.start()
      }
    }
  }
}
