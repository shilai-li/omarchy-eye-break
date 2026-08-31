import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The bar face of the eye-break timer, and the one place the schedule is
// advanced.
//
// Left click opens the dashboard — asking "how long have I got?" is what a
// click on a countdown means — right click pauses, middle click takes the
// break now.
//
// A bar surface exists per monitor, so this file is instantiated once per
// screen. None of those instances owns the clock: the schedule is one
// timestamp in a state file that every instance derives from and any instance
// may write. Only the first live instance advances the cycle automatically,
// which is what keeps a two-monitor desktop from raising two break screens.
BarWidget {
  id: root
  moduleName: "shilai_li.eye-break"

  // ---- Settings, clamped in Model.js. A hand-edited shell.json should give
  //      a working plugin at the nearest sane value rather than a broken one.
  readonly property int intervalMinutes: Model.intervalMinutes(setting("intervalMinutes", 20))
  readonly property int breakSeconds: Model.breakSeconds(setting("breakSeconds", 20))
  readonly property bool pauseWhenIdle: Model.boolSetting(setting("pauseWhenIdle", true), true)
  readonly property int idleGraceSeconds: Model.idleGraceSeconds(setting("idleGraceSeconds", 60))
  readonly property bool pauseInFullscreen: Model.boolSetting(setting("pauseInFullscreen", false), false)
  readonly property bool strictMode: Model.boolSetting(setting("strictMode", false), false)
  readonly property int preNotifySeconds: Model.preNotifySeconds(setting("preNotifySeconds", 0))
  readonly property bool showCountdown: Model.boolSetting(setting("showCountdown", true), true)

  readonly property real intervalMs: intervalMinutes * 60000
  readonly property real breakMs: breakSeconds * 1000

  // ---- Shared state. `now` is only a repaint pulse; nothing counts down.
  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy/eye-break"
  readonly property string statePath: stateDir + "/state.json"
  readonly property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  property var state: Model.defaultState(Date.now())
  property real now: Date.now()

  // Set when there was no file to read. The first tick seeds one, by which
  // point the bar has been injected and the writer election is honest.
  property bool stateSeedNeeded: false

  // Whether a read has ever succeeded. A later read failure is a transient
  // fault, not a first run, and must not be answered by throwing away the
  // history we already hold.
  property bool stateLoaded: false

  // Guards the heads-up notification to one per cycle, keyed by the cycle it
  // belongs to so a new cycle re-arms it without any extra bookkeeping.
  property real warnedForCycle: 0

  readonly property real remainingMs: Model.remainingMs(state, intervalMs, now)
  readonly property real progress: Model.cycleProgress(state, intervalMs, now)
  readonly property string status: Model.statusOf(state, intervalMs, now)
  readonly property bool dimmed: status === "paused" || status === "idle"
  readonly property real urgency: dimmed || status === "break" ? 0 : Model.urgency(progress)

  readonly property string glyphText: dimmed ? "󰈉" : "󰈈"
  readonly property string labelText: Model.barLabel(status, remainingMs, showCountdown)
  readonly property string displayText: labelText === "" ? glyphText : glyphText + " " + labelText

  // Vertical bars have room for stacked icon-sized lines and nothing else, so
  // the countdown splits at its colons rather than being squeezed onto one.
  readonly property var verticalLines: {
    var lines = [glyphText]
    if (dimmed || status === "break" || !showCountdown) return lines
    var parts = Model.formatCountdown(remainingMs).split(":")
    for (var i = 0; i < parts.length; i++) lines.push(parts[i])
    return lines
  }

  // The bar's own foreground until the cycle is nearly up, then blended
  // toward the theme's urgent color. "Nearly time" should be legible without
  // adding a second glyph to a bar that is meant to stay quiet.
  readonly property color baseForeground: bar ? bar.barForeground : Color.foreground
  readonly property color glyphColor: {
    if (root.dimmed) return Qt.darker(root.baseForeground, 1.7)
    if (root.urgency <= 0) return root.baseForeground
    var hot = bar ? bar.urgent : Color.urgent
    return Qt.tint(root.baseForeground, Qt.rgba(hot.r, hot.g, hot.b, root.urgency))
  }

  // ---- Writer election. Every instance renders; the first one in the bar's
  //      own slot order advances the cycle. The order is the same array for
  //      all of them, so the choice needs no coordination.
  function amWriter() {
    if (!bar || typeof bar.moduleWidgets !== "function") return true
    var peers = bar.moduleWidgets(moduleName)
    return peers.length === 0 || peers[0] === root
  }

  function commit(next) {
    if (!next) return
    root.state = next
    stateFile.setText(Model.serializeState(next))
  }

  function adopt(text) {
    root.state = Model.parseState(text, Date.now())
  }

  // ---- The scheduler. Runs once a second on the writing instance; every
  //      other instance falls out after refreshing `now`.
  function tick() {
    root.now = Date.now()
    if (!root.amWriter()) return

    if (root.stateSeedNeeded) {
      root.stateSeedNeeded = false
      root.commit(Model.startCycle(root.state, root.now))
      return
    }

    // A break overlay that never reported back — the shell was killed
    // mid-break, or the plugin reloaded under it. Without this the widget
    // would sit on "on break" forever and never schedule again.
    if (Model.isBreakAbandoned(root.state, root.breakMs, root.now)) {
      root.commit(Model.recordBreak(root.state, "skipped", root.now))
      return
    }
    if (Model.isBreaking(root.state) || Model.isPaused(root.state)) return

    // Woken from suspend, or the shell was down. Nobody was here to take the
    // break, and firing one at the moment a lid opens interrupts the wrong
    // moment — start the cycle over instead.
    if (Model.isStale(root.state, root.intervalMs, root.now)) {
      root.commit(Model.startCycle(root.state, root.now))
      return
    }

    if (Model.isDue(root.state, root.intervalMs, root.now)) root.requestBreak()
    else root.maybeWarn()
  }

  function maybeWarn() {
    if (root.preNotifySeconds <= 0) return
    if (root.warnedForCycle === root.state.cycleStartedAt) return
    if (root.remainingMs > root.preNotifySeconds * 1000) return
    root.warnedForCycle = root.state.cycleStartedAt

    var command = root.omarchyPath && root.omarchyPath.length > 0
      ? [root.omarchyPath + "/bin/omarchy-notification-send"]
      : ["omarchy", "notification", "send"]
    Quickshell.execDetached(command.concat([
      "-g", "󰈈",
      "Eye break",
      "Looking away in " + Model.formatDuration(root.remainingMs)
    ]))
  }

  // ---- Raising the break. The overlay is a separate plugin kind so it can be
  //      a real fullscreen layer-shell surface instead of a popup pinned to
  //      the bar; the shell routes summon there because this plugin declares
  //      an overlay kind alongside its bar widget.
  function requestBreak() {
    if (!root.pauseInFullscreen) {
      root.startBreak()
      return
    }
    // Only asked once a cycle, at the moment it matters, so there is no
    // hyprctl running on the timer.
    if (!fullscreenProbe.running) fullscreenProbe.running = true
  }

  function applyFullscreenProbe(raw) {
    var fullscreen = false
    try {
      fullscreen = Number(JSON.parse(String(raw || "{}")).fullscreen) > 0
    } catch (e) {
      // hyprctl missing, or no focused window at all. Nothing to avoid
      // interrupting, so take the break.
      fullscreen = false
    }

    if (!root.amWriter()) return
    if (Model.isBreaking(root.state) || Model.isPaused(root.state)) return
    if (fullscreen) root.commit(Model.postpone(root.state, 60000))
    else root.startBreak()
  }

  function startBreak() {
    var host = root.bar && root.bar.shell ? root.bar.shell : null
    if (!host || typeof host.summon !== "function") {
      // Nothing to raise the overlay with. Start the cycle over rather than
      // recording anything: no break was ever offered, so charging the user a
      // skip would be blaming them for the shell's problem.
      root.commit(Model.startCycle(root.state, Date.now()))
      return
    }

    root.commit(Model.beginBreak(root.state, Date.now()))
    var raised = host.summon(root.moduleName, JSON.stringify({
      seconds: root.breakSeconds,
      strict: root.strictMode,
      statePath: root.statePath
    })) === true

    // The plugin was disabled between the tick and the summon, or the overlay
    // failed to load — both of which happen transiently during a plugin
    // hot-reload. Settle the break so the countdown is not left frozen, but
    // record nothing: an overlay the user never saw is not a skip, and
    // charging it to their adherence would make a shell hiccup look like a
    // bad habit.
    if (!raised) root.commit(Model.startCycle(root.state, Date.now()))
  }

  // ---- Actions. Shared by the panel, the mouse and the IPC target. Any
  //      instance may run them: they all end in one atomic write that every
  //      other instance picks up from the file.
  function togglePause() { root.commit(Model.togglePause(root.state, Date.now())) }
  function pauseTimer() { root.commit(Model.pause(root.state, Date.now(), "manual")) }
  function resumeTimer() { root.commit(Model.resume(root.state, Date.now(), "manual")) }
  function skipCycle() { root.commit(Model.recordBreak(root.state, "skipped", Date.now())) }
  function resetHistory() { root.commit(Model.clearHistory(root.state)) }

  function breakNow() {
    root.now = Date.now()
    root.startBreak()
  }

  function restartCycle() { root.commit(Model.startCycle(root.state, Date.now())) }

  // Applied locally first so the panel redraws on the keystroke itself; the
  // shell.json write comes back through the bar as the same value.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]

    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function setInterval(minutes) {
    var next = Model.intervalMinutes(minutes)
    if (next === root.intervalMinutes) return
    root.persistSettings({ intervalMinutes: next })
  }

  function setBreakLength(seconds) {
    var next = Model.breakSeconds(seconds)
    if (next === root.breakSeconds) return
    root.persistSettings({ breakSeconds: next })
  }

  function setFlag(key, value) {
    var values = ({})
    values[key] = value === true
    root.persistSettings(values)
  }

  function statusJson() {
    var at = Date.now()
    var left = Model.remainingMs(root.state, root.intervalMs, at)
    var stats = Model.statsFor(root.state.history, at, root.intervalMs)
    return JSON.stringify({
      status: Model.statusOf(root.state, root.intervalMs, at),
      // The work cycle keeps elapsing during a break — recordBreak is what
      // resets it — so this stays honest rather than freezing. A status line
      // that wants "time until I am back at work" reads the break field.
      remainingSeconds: Math.ceil(left / 1000),
      remainingText: Model.formatCountdown(left),
      breakRemainingSeconds: Model.isBreaking(root.state)
        ? Math.max(0, Math.ceil((root.breakMs - (at - root.state.breakStartedAt)) / 1000))
        : 0,
      progress: Math.round(Model.cycleProgress(root.state, root.intervalMs, at) * 1000) / 1000,
      intervalMinutes: root.intervalMinutes,
      breakSeconds: root.breakSeconds,
      paused: Model.isPaused(root.state),
      pausedBy: root.state.pausedBy,
      streak: stats.streak,
      today: {
        taken: stats.taken,
        skipped: stats.skipped,
        adherencePercent: stats.adherencePercent
      }
    })
  }

  // ---- Panel plumbing. Shape contract for shell.summon/hide/toggle routing:
  //      Bar.findPanelWidget requires open/close/opened on the bar-widget
  //      root, and the popout coordinator prefers closeForPopoutSwitch.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  // The countdown fills more slot than it paints a mark for. Horizontally the
  // dot takes the label width; vertically it takes one line, the same mark
  // every icon widget gets rather than a rule running the whole stack.
  readonly property real openPanelIndicatorWidth: button.labelWidth
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  // Turning idle pausing off while idle-paused would otherwise strand the
  // countdown with nothing left to resume it.
  onPauseWhenIdleChanged: {
    if (root.pauseWhenIdle) return
    if (!root.amWriter()) return
    if (root.state.pausedBy !== "idle") return
    root.commit(Model.resume(root.state, Date.now(), "idle"))
  }

  Component.onCompleted: ensureDirProc.running = true

  // Seconds precision because this is a countdown, not a clock. The cost is
  // one repaint per second per monitor; the alternative is a label that lies
  // for up to a minute at the exact moment it matters most.
  SystemClock {
    id: clock
    precision: SystemClock.Seconds
    onDateChanged: root.tick()
  }

  // The state directory is ours alone, so creating it is a one-shot at
  // startup rather than something every write has to check.
  Process {
    id: ensureDirProc
    command: ["mkdir", "-p", root.stateDir]
    onExited: Qt.callLater(function() { stateFile.reload() })
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: {
      root.stateLoaded = true
      root.adopt(stateFile.text())
    }
    onFileChanged: stateFile.reload()
    onLoadFailed: {
      // Already holding a good state: this is a transient fault (a write in
      // flight, a directory that vanished). Keep what we have — the watch
      // will bring the next good read.
      if (root.stateLoaded) return
      // First run. Start a cycle from now and let the first tick seed the
      // file, by which point the writer is known.
      root.state = Model.defaultState(Date.now())
      root.stateSeedNeeded = true
    }
  }

  IdleMonitor {
    id: idleMonitor
    // Enabled on every instance so the binding stays simple; the handler is
    // what defers to the writer.
    enabled: root.pauseWhenIdle
    timeout: root.idleGraceSeconds
    respectInhibitors: true
    onIsIdleChanged: {
      if (!root.amWriter() || !root.pauseWhenIdle) return
      var at = Date.now()
      root.now = at
      if (idleMonitor.isIdle) {
        // Going idle during a break is the break working. Leave it alone.
        if (Model.isBreaking(root.state)) return
        root.commit(Model.pause(root.state, at, "idle"))
      } else {
        // The interval, not the break length: only an absence as long as a
        // whole work cycle is evidence that a break actually happened.
        root.commit(Model.endIdle(root.state, at, root.intervalMs))
      }
    }
  }

  Process {
    id: fullscreenProbe
    command: ["hyprctl", "-j", "activewindow"]
    stdout: StdioCollector { id: fullscreenOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.applyFullscreenProbe(exitCode === 0 ? fullscreenOut.text : "")
    }
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // Every action ends in one atomic write that all instances read back, so
  // these route to whichever instance owns the target rather than being
  // broadcast to all of them — a skip fanned out per monitor would be
  // recorded once per screen.
  IpcHandler {
    target: "shilai_li.eye-break"

    function pause(): void { root.pauseTimer() }
    function resume(): void { root.resumeTimer() }
    function toggle(): void { root.togglePanel() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function togglePause(): void { root.togglePause() }
    function breakNow(): void { root.breakNow() }
    function skip(): void { root.skipCycle() }
    function reset(): void { root.restartCycle() }
    function status(): string { return root.statusJson() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.vertical ? "" : root.displayText
    foreground: root.glyphColor
    labelVisible: !root.vertical
    hasVisualContent: root.vertical ? root.verticalLines.length > 0 : text !== ""
    fixedHeight: root.vertical ? root.verticalLines.length * Style.bar.iconSlot : -1
    horizontalMargin: 8.75
    verticalPadding: 8.75
    tooltipText: Model.tooltipFor(root.status, root.remainingMs, root.intervalMinutes, root.breakSeconds)

    onPressed: function(b) {
      if (b === Qt.RightButton) root.togglePause()
      else if (b === Qt.MiddleButton) root.breakNow()
      else root.togglePanel()
    }

    Column {
      visible: root.vertical
      anchors.fill: parent

      Repeater {
        model: root.verticalLines

        OpticalGlyph {
          required property string modelData
          width: button.width
          height: Style.bar.iconSlot
          text: modelData
          fontFamily: button.fontFamily
          fontSize: button.fontSize
          color: root.glyphColor
        }
      }
    }
  }
}
