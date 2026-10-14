import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// The eye-break dashboard, drawn the way the Studio Effects panel is: a header
// with the status, one large card for the thing being watched (here the
// countdown), the service as a pair of tiles, the amounts as filling capsules.
// The timer tile says whether the timer is on; while it is off the panel
// shrinks to the countdown card, the two tiles and a note, because nothing
// else does anything then.
//
// This panel owns no state. BarWidget.qml holds the schedule and does every
// write; everything here reads off `hostWidget` and calls back into it, so
// two monitors showing this panel at once cannot disagree.
//
// One highlight on screen at a time: rows paint from CursorSurface's
// `hasCursor`, never from `containsMouse`, and the mouse moves the same cursor
// the arrow keys do.
Panel {
  id: root
  moduleName: "shilai_li.eye-break"
  ipcTarget: "shilai_li.eye-break"
  manageIpc: false

  property var anchorItem: null

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel. Everything the bar identifies a panel by has to be that
  // widget: the popout coordinator (and with it the open-panel dot under the
  // pill) compares against `slot.activeItem`.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root
  readonly property var host: hostWidget

  // ---- Everything below is a read-out of the host. Guarded throughout: the
  //      bar-widget contract instantiates this bare, before injection.
  readonly property real now: host ? host.now : Date.now()
  readonly property var state: host ? host.state : Model.defaultState(Date.now())
  readonly property real intervalMs: host ? host.intervalMs : 20 * Model.MS_PER_MINUTE
  readonly property int intervalMinutes: host ? host.intervalMinutes : 20
  readonly property int breakSeconds: host ? host.breakSeconds : 20
  readonly property real breakMs: breakSeconds * 1000
  readonly property bool pauseWhenIdle: host ? host.pauseWhenIdle : true
  readonly property int idleGraceSeconds: host ? host.idleGraceSeconds : 300
  readonly property bool pauseInFullscreen: host ? host.pauseInFullscreen : false
  readonly property bool strictMode: host ? host.strictMode : false

  readonly property string status: Model.statusOf(state, intervalMs, now)
  readonly property bool running: status === "running" || status === "due"
  // Paused by hand or away. The timer is off, so the panel is only the card
  // that says so and the way back on.
  readonly property bool collapsed: status === "paused" || status === "idle"
  readonly property real remainingMs: Model.remainingMs(state, intervalMs, now)
  readonly property real progress: Model.cycleProgress(state, intervalMs, now)
  readonly property real breakRemainingMs: Math.max(0, breakMs - (now - state.breakStartedAt))
  readonly property real breakProgress: Model.clamp01((now - state.breakStartedAt) / Math.max(1, breakMs))
  readonly property real shownProgress: status === "break" ? breakProgress : progress

  readonly property var stats: Model.statsFor(state.history, now, intervalMs)
  readonly property var graph: Model.hourlyCounts(state.history, now, 16)
  readonly property int graphPeak: Math.max.apply(null, graph.counts)

  // ---- Theme. Nothing here names a color; the palette does.
  readonly property color contentForeground: bar ? bar.foreground : Commons.Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color surface: Commons.Color.popups.background
  readonly property color muted: Commons.Color.muted
  readonly property color accentColor: Style.selectedStateColor(contentForeground, Commons.Color.accent)
  readonly property color hoverFill: Style.hoverFillFor(contentForeground, Commons.Color.accent)

  // Cards are a tint of the text color laid over the panel, so they sit on any
  // theme without a color of their own. Something switched on is filled with
  // the accent and carries its glyph in the panel's own color, cut out of it.
  readonly property color cardFill: Util.alpha(contentForeground, 0.06)
  readonly property color quietFill: Util.alpha(contentForeground, 0.12)
  readonly property color insetFill: Util.alpha(surface, 0.5)
  readonly property color onFill: Commons.Color.accent

  // The theme decides whether anything is round. Square corners stay square;
  // rounded ones grow a step, because the cards here are larger than a row.
  readonly property bool rounded: Style.cornerRadius > 0
  readonly property int cardRadius: rounded ? Math.max(Style.cornerRadius * 2, Style.space(12)) : 0
  readonly property int rowHeight: Math.max(Style.space(30), Style.font.body + Style.space(16))

  // ---- Copy. One place for every word the countdown card shows, per status.
  readonly property string heroLabel: status === "break" ? "LOOK AWAY" : "NEXT BREAK"
  readonly property string heroText: Model.formatCountdown(status === "break" ? breakRemainingMs : remainingMs)
  readonly property string heroCaption: status === "break"
    ? "20 feet away · " + breakSeconds + " seconds · blink"
    : "then look 20 feet away for " + breakSeconds + " seconds"
  readonly property string pausedTitle: status === "idle" ? "You stepped away" : "Timer paused"
  readonly property string pausedCaption: Model.formatCountdown(remainingMs) + " left in this cycle"
  readonly property string pausedNote: status === "idle"
    ? "The clock stopped when you went idle. It starts again on its own when you come back."
    : "Nothing counts while it is paused, and coming back to the keyboard will not resume it."

  readonly property string timerStatus: {
    if (status === "break") return "On break"
    if (status === "idle") return "Away"
    if (status === "paused") return "Paused"
    return "Running"
  }
  readonly property string idleStatus: {
    if (!pauseWhenIdle) return "Off"
    var s = idleGraceSeconds
    return "After " + (s % 60 === 0 ? (s / 60) + " min" : s + " s")
  }

  readonly property var keyHints: collapsed
    ? [["p", "resume"], ["i", "idle pause"], ["esc", "close"]]
    : [["↑↓", "move"], ["←→", "adjust"], ["p", "pause"], ["b", "break now"], ["r", "clear"], ["esc", "close"]]

  // ---- Keyboard cursor. Up and down walk the rows on screen, in the order
  //      they are drawn; enter and space act on the one under the cursor.
  //      Hidden rows are not in the list, so the cursor cannot land on a
  //      control that is not there.
  property int cursor: 0
  readonly property var cursorRows: {
    var rows = ["timer", "idle"]
    if (root.collapsed) return rows
    rows.push("interval", "breakLength", "fullscreen", "strict", "breakNow")
    if (!root.strictMode) rows.push("skip")
    rows.push("clear")
    return rows
  }
  readonly property string cursorRow: cursorRows[Math.min(cursor, cursorRows.length - 1)]

  function moveCursor(dy) {
    var last = root.cursorRows.length - 1
    root.cursor = Math.max(0, Math.min(last, Math.min(root.cursor, last) + dy))
  }

  // The mouse moves the same cursor the keys do.
  function cursorTo(row) {
    var index = root.cursorRows.indexOf(row)
    if (index >= 0) root.cursor = index
  }

  // ---- Lifecycle. Mirrors the clock's: the popout coordinator is handed
  //      over on show, so the hover-reveal flag is set after, not before.
  function open() {
    root.cursor = 0
    root.controller.show()
    Qt.callLater(function() {
      if (root.opened) root.setCenterHoverRevealSuppressed(true)
    })
  }

  // The hide goes first. Everything after it is cosmetic, and this panel is
  // a full-screen layer-shell surface holding keyboard focus: a call that
  // throws before the hide lands leaves the user with no way out of it and a
  // bar that no longer answers. Nothing decorative gets to stand in front of
  // the one line that releases the screen.
  function close() {
    root.controller.hide()
    root.setCenterHoverRevealSuppressed(false)
  }

  function toggle() { root.opened ? root.close() : root.open() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // Summoning by hotkey moves no pointer, so a hover the bar was still
  // holding must not keep the center indicators revealed behind the panel.
  //
  // The setter is the supported route: the `bar` a plugin is handed is a
  // PluginBarApi facade, where this flag is readonly and backed by a scoped
  // callback. Assigning to it throws rather than failing quietly, which is
  // why the direct write is only the fallback for a host that predates the
  // setter — and why it is now second.
  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // ---- Actions, all delegated. The panel never touches the state file.
  function act(name, arg) {
    if (!root.host || typeof root.host[name] !== "function") return
    if (arg === undefined) root.host[name]()
    else root.host[name](arg)
  }

  function stepInterval(deltaMinutes) { root.act("setInterval", root.intervalMinutes + deltaMinutes) }
  function stepBreak(deltaSeconds) { root.act("setBreakLength", root.breakSeconds + deltaSeconds) }
  function flipFlag(key, current) { if (root.host) root.host.setFlag(key, !current) }

  // Enter and space both land here, on whichever row the cursor is on.
  function activateRow() {
    var row = root.cursorRow
    if (row === "timer") root.act("togglePause")
    else if (row === "idle") root.flipFlag("pauseWhenIdle", root.pauseWhenIdle)
    else if (row === "fullscreen") root.flipFlag("pauseInFullscreen", root.pauseInFullscreen)
    else if (row === "strict") root.flipFlag("strictMode", root.strictMode)
    else if (row === "breakNow") root.breakNow()
    else if (row === "skip") root.act("skipCycle")
    else if (row === "clear") root.act("resetHistory")
  }

  // Taking a break from the panel closes it, so the overlay has the screen.
  function breakNow() {
    root.act("breakNow")
    root.close()
  }

  // Strict mode removes the skip key from the break screen. Skipping from
  // here would undo that, so the panel's skip is removed in strict mode too.
  function handleTextKey(text) {
    var key = String(text).toLowerCase()
    if (key === "p") root.act("togglePause")
    else if (key === "s") { if (!root.strictMode) root.act("skipCycle") }
    else if (key === "b") root.breakNow()
    else if (key === "r") root.act("resetHistory")
    else if (key === "i") root.flipFlag("pauseWhenIdle", root.pauseWhenIdle)
    else if (key === "f") root.flipFlag("pauseInFullscreen", root.pauseInFullscreen)
    else if (key === "m") root.flipFlag("strictMode", root.strictMode)
    else if (key === "+" || key === "=") root.stepInterval(5)
    else if (key === "-" || key === "_") root.stepInterval(-5)
    else if (key === "]") root.stepBreak(5)
    else if (key === "[") root.stepBreak(-5)
  }

  // ---- Pieces.

  component Label: Text {
    textFormat: Text.PlainText
    color: root.contentForeground
    font.family: root.contentFontFamily
    font.pixelSize: Style.font.body
  }

  component Card: Rectangle {
    width: parent ? parent.width : 0
    radius: root.cardRadius
    color: root.cardFill
  }

  // A round button face: the accent when on, a quiet tint when off. Square on a
  // theme with square corners.
  component Disc: Rectangle {
    id: disc
    property bool on: false
    property string glyph: ""
    property real size: Style.space(38)
    width: size
    height: size
    radius: root.rounded ? size / 2 : 0
    color: disc.on ? root.onFill : root.quietFill

    Behavior on color { ColorAnimation { duration: Style.duration(120) } }

    Label {
      anchors.centerIn: parent
      text: disc.glyph
      color: disc.on ? root.surface : root.contentForeground
      font.pixelSize: Math.round(disc.size * 0.46)
    }
  }

  // A small label in the header, beside the status.
  component Pill: Rectangle {
    property alias text: pillText.text
    width: pillText.implicitWidth + Style.space(14)
    height: pillText.implicitHeight + Style.space(6)
    radius: root.rounded ? height / 2 : 0
    color: root.quietFill

    Label {
      id: pillText
      anchors.centerIn: parent
      color: root.muted
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }

  // The timer and its idle pause: the two things that decide whether the clock
  // runs. Peers of each other, so they sit side by side.
  component PowerTile: CursorSurface {
    id: tile
    property string rowName: ""
    property string label: ""
    property string status: ""
    property string glyph: ""
    property bool on: false
    signal activated()

    height: Style.space(12) * 2 + Style.space(38)
    radius: root.cardRadius
    hasCursor: root.cursorRow === tile.rowName
    color: tile.hasCursor ? root.hoverFill : root.cardFill
    foreground: root.contentForeground
    accent: Commons.Color.accent

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) root.cursorTo(tile.rowName)
      onClicked: {
        root.cursorTo(tile.rowName)
        tile.activated()
      }
    }

    Row {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(12)
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(10)

      Disc {
        on: tile.on
        glyph: tile.glyph
      }
      Column {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - Style.space(38) - Style.space(22)
        spacing: Style.space(1)

        Label {
          width: parent.width
          text: tile.label
          font.bold: true
          elide: Text.ElideRight
        }
        Label {
          width: parent.width
          text: tile.status
          color: root.muted
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
      }
    }
  }

  // A button in the row of actions: a glyph and a word, or the glyph alone.
  component ActionButton: CursorSurface {
    id: action
    property string rowName: ""
    property string glyph: ""
    property string text: ""
    signal activated()

    height: root.rowHeight + Style.space(6)
    radius: root.cardRadius
    hasCursor: root.cursorRow === action.rowName
    color: action.hasCursor ? root.hoverFill : root.cardFill
    foreground: root.contentForeground
    accent: Commons.Color.accent

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) root.cursorTo(action.rowName)
      onClicked: {
        root.cursorTo(action.rowName)
        action.activated()
      }
    }

    Row {
      anchors.centerIn: parent
      spacing: Style.space(7)

      Label {
        anchors.verticalCenter: parent.verticalCenter
        text: action.glyph
        color: root.muted
        font.pixelSize: Style.font.icon
      }
      Label {
        anchors.verticalCenter: parent.verticalCenter
        visible: action.text.length > 0
        text: action.text
        font.bold: true
      }
    }
  }

  // A filling capsule: the part up to the value is solid, with the setting's
  // glyph cut into its left end. Dragging draws where the pointer is and
  // writes once, on release: a write goes to shell.json, and a file written
  // on every step of a drag would reload the plugin under the pointer. The
  // value stays where it was dropped until the host reports it back.
  component Capsule: Item {
    id: capsule
    property real minimum: 0
    property real maximum: 1
    property real step: 1
    property real value: 0
    property string glyph: ""
    property real live: 0
    property bool dragging: false
    property bool holding: false
    readonly property real shown: (capsule.dragging || capsule.holding) ? capsule.live : capsule.value
    readonly property real progress: Math.max(0, Math.min(1,
      (capsule.shown - capsule.minimum) / Math.max(1, capsule.maximum - capsule.minimum)))

    signal released(real next)

    width: parent ? parent.width : 0
    height: Style.space(30)

    onValueChanged: if (capsule.holding && capsule.value === capsule.live) capsule.holding = false

    function snap(v) {
      var s = Math.max(1, capsule.step)
      var n = Math.round((v - capsule.minimum) / s) * s + capsule.minimum
      return Math.max(capsule.minimum, Math.min(capsule.maximum, n))
    }

    // A write the host never echoes back would pin the capsule to a stale
    // value; let go of it after a moment either way.
    Timer {
      id: holdTimer
      interval: 1200
      onTriggered: capsule.holding = false
    }

    Rectangle {
      id: capsuleTrack
      anchors.fill: parent
      radius: root.rounded ? height / 2 : 0
      color: root.quietFill
    }
    Rectangle {
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: capsule.height + (capsule.width - capsule.height) * capsule.progress
      radius: capsuleTrack.radius
      color: root.contentForeground

      Behavior on width {
        enabled: !capsule.dragging
        NumberAnimation { duration: Style.duration(140); easing.type: Easing.OutCubic }
      }
    }
    Label {
      x: Math.round((capsule.height - width) / 2)
      anchors.verticalCenter: parent.verticalCenter
      text: capsule.glyph
      color: root.surface
      font.pixelSize: Style.font.body
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor

      function valueAt(x) {
        var span = Math.max(1, capsule.width - capsule.height)
        var p = Math.max(0, Math.min(1, (x - capsule.height / 2) / span))
        return capsule.snap(capsule.minimum + p * (capsule.maximum - capsule.minimum))
      }

      onPressed: function (mouse) {
        capsule.live = capsule.snap(valueAt(mouse.x))
        capsule.dragging = true
      }
      onPositionChanged: function (mouse) {
        if (capsule.dragging) capsule.live = valueAt(mouse.x)
      }
      onReleased: {
        if (!capsule.dragging) return
        capsule.dragging = false
        if (capsule.live === capsule.value) return
        capsule.holding = true
        holdTimer.restart()
        capsule.released(capsule.live)
      }
      onCanceled: capsule.dragging = false
      onWheel: function (wheel) {
        var next = capsule.snap(capsule.value + (wheel.angleDelta.y > 0 ? 1 : -1) * capsule.step)
        if (next === capsule.value) return
        capsule.live = next
        capsule.holding = true
        holdTimer.restart()
        capsule.released(next)
      }
    }
  }

  // A setting: its name and value over the control that changes it.
  component SliderBlock: CursorSurface {
    id: block
    property string rowName: ""
    property string label: ""
    property string unit: ""
    property string glyph: ""
    property alias minimum: capsule.minimum
    property alias maximum: capsule.maximum
    property alias step: capsule.step
    property alias value: capsule.value

    signal released(real next)

    width: parent ? parent.width : 0
    height: blockColumn.implicitHeight + Style.space(14)
    radius: Math.max(0, root.cardRadius - Style.space(2))
    hasCursor: root.cursorRow === block.rowName
    foreground: root.contentForeground
    accent: Commons.Color.accent
    fill: root.hoverFill

    HoverHandler {
      onHoveredChanged: if (hovered) root.cursorTo(block.rowName)
    }

    Column {
      id: blockColumn
      x: Style.space(6)
      y: Style.space(7)
      width: parent.width - Style.space(12)
      spacing: Style.space(6)

      Item {
        width: parent.width
        height: blockName.implicitHeight

        Label {
          id: blockName
          x: Style.space(4)
          text: block.label
          color: root.muted
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }
        // Arrows on the row under the cursor, so it is discoverable that it
        // is adjusted rather than chosen.
        Label {
          anchors.right: parent.right
          anchors.rightMargin: Style.space(4)
          text: {
            var v = Math.round(capsule.shown) + " " + block.unit
            return block.hasCursor ? "‹ " + v + " ›" : v
          }
          color: block.hasCursor ? root.accentColor : root.muted
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }
      }

      Capsule {
        id: capsule
        glyph: block.glyph
        onReleased: function (next) { block.released(next) }
      }
    }
  }

  component KeyHint: Row {
    id: keyHint
    required property var modelData
    spacing: Style.space(4)

    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      width: keyText.implicitWidth + Style.space(8)
      height: keyText.implicitHeight + Style.space(2)
      radius: root.rounded ? Style.space(4) : 0
      color: root.quietFill

      Label {
        id: keyText
        anchors.centerIn: parent
        text: keyHint.modelData[0]
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }
    Label {
      anchors.verticalCenter: parent.verticalCenter
      text: keyHint.modelData[1]
      color: root.muted
      font.pixelSize: Style.font.caption
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    // Follow the widget as the bar layout changes; KeyboardPanel keeps the
    // card within the screen edges on horizontal and vertical bars.
    centerOnBar: false
    focusTarget: keyCatcher
    // The width the shell's own settings panels use (audio, bluetooth,
    // network, power), so this one sits at the same width beside them.
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onCloseRequested: root.close()
      onActivateRequested: root.activateRow()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { root.handleTextKey(t) }
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveCursor(dy)
        // Left and right step whichever slider the cursor is on.
        if (dx !== 0 && root.cursorRow === "interval") root.stepInterval(dx * 5)
        else if (dx !== 0 && root.cursorRow === "breakLength") root.stepBreak(dx * 5)
      }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: column.width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: column
          width: scroll.width
          spacing: Style.space(10)

          // ---- Title, and what the timer is doing. Facts only: nothing here
          //      is a control.
          Item {
            width: parent.width
            height: Math.max(titleRow.implicitHeight, statusPill.height)

            Row {
              id: titleRow
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(7)

              Label {
                anchors.verticalCenter: parent.verticalCenter
                text: "\u{F0208}"
                color: root.status === "break" ? Commons.Color.urgent
                  : root.collapsed ? root.muted : Commons.Color.accent
                font.pixelSize: Style.font.icon
              }
              Label {
                anchors.verticalCenter: parent.verticalCenter
                text: "Eye Break"
                font.bold: true
                font.pixelSize: Style.font.subtitle
              }
            }

            // The schedule is the one fact nothing else on the panel says: the
            // sliders below set it, but only while the timer is on.
            Pill {
              anchors.right: statusPill.visible ? statusPill.left : parent.right
              anchors.rightMargin: statusPill.visible ? Style.space(6) : 0
              anchors.verticalCenter: parent.verticalCenter
              visible: !root.collapsed
              text: root.intervalMinutes + " min · " + root.breakSeconds + " s"
            }

            // A red badge while a break is on screen: the state that captures
            // the display gets the one red thing in the header.
            Rectangle {
              id: statusPill
              visible: root.status === "break" || root.collapsed
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: statusRow.implicitWidth + Style.space(14)
              height: statusText.implicitHeight + Style.space(6)
              radius: root.rounded ? height / 2 : 0
              color: root.status === "break" ? Util.alpha(Commons.Color.urgent, 0.16) : root.quietFill

              Row {
                id: statusRow
                anchors.centerIn: parent
                spacing: Style.space(5)

                Rectangle {
                  visible: root.status === "break"
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(6)
                  height: width
                  radius: width / 2
                  color: Commons.Color.urgent
                }
                Label {
                  id: statusText
                  text: root.status === "break" ? "BREAK" : root.status === "idle" ? "AWAY" : "PAUSED"
                  color: root.status === "break" ? Commons.Color.urgent : root.muted
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: 1
                }
              }
            }
          }

          // ---- The countdown. Nothing is drawn over it but its own words.
          Card {
            id: hero
            height: Math.round(width * 9 / 16)

            Column {
              visible: !root.collapsed
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.verticalCenterOffset: -Style.space(8)
              spacing: Style.space(6)

              Label {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: root.heroLabel
                color: root.status === "break" ? Commons.Color.urgent : root.muted
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.5
              }
              Label {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: root.heroText
                color: root.status === "break" ? Commons.Color.urgent : root.contentForeground
                // Deliberately outside the Style.font.* scale: this is the one
                // number the panel exists to show. It rides the theme's base
                // size, so a larger font makes it larger too.
                font.pixelSize: Style.fontPx(3.6)
                font.bold: true
              }
              Label {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: root.heroCaption
                color: root.muted
                font.pixelSize: Style.font.bodySmall
              }
            }

            // Cycle progress, or break progress during a break. It fills left
            // to right, the same as a capsule.
            Rectangle {
              visible: !root.collapsed
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              anchors.leftMargin: Style.space(20)
              anchors.rightMargin: Style.space(20)
              anchors.bottomMargin: Style.space(18)
              height: Style.space(6)
              radius: height / 2
              color: root.quietFill

              Rectangle {
                height: parent.height
                width: parent.width * root.shownProgress
                radius: parent.radius
                color: root.status === "break" ? Commons.Color.urgent : Commons.Color.accent
              }
            }

            // Off. Said as status, not as a caution, with the way back on.
            Column {
              visible: root.collapsed
              anchors.centerIn: parent
              width: parent.width - Style.space(40)
              spacing: Style.space(10)

              Disc {
                anchors.horizontalCenter: parent.horizontalCenter
                size: Style.space(52)
                glyph: root.status === "idle" ? "\u{F0594}" : "\u{F040A}"

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.act("togglePause")
                }
              }
              Label {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: root.pausedTitle
                font.bold: true
                font.pixelSize: Style.font.subtitle
              }
              Label {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: root.pausedCaption
                color: root.muted
                font.pixelSize: Style.font.bodySmall
              }
            }
          }

          // ---- The timer and its idle pause. Off is not "reminders
          //      disabled" but "the clock is stopped": the cycle keeps what
          //      it had and carries on from there.
          Row {
            width: parent.width
            spacing: Style.space(10)

            PowerTile {
              width: (parent.width - parent.spacing) / 2
              rowName: "timer"
              label: "Timer"
              glyph: "\u{F051B}"
              on: !root.collapsed
              status: root.timerStatus
              onActivated: root.act("togglePause")
            }
            PowerTile {
              width: (parent.width - parent.spacing) / 2
              rowName: "idle"
              label: "Idle pause"
              glyph: "\u{F0594}"
              on: root.pauseWhenIdle
              status: root.idleStatus
              onActivated: root.flipFlag("pauseWhenIdle", root.pauseWhenIdle)
            }
          }

          // ---- Why the rest is gone. Under the tiles rather than in them: it
          //      is a sentence and does not fit in one.
          Card {
            visible: root.collapsed
            height: noteRow.implicitHeight + Style.space(24)

            Row {
              id: noteRow
              x: Style.space(14)
              y: Style.space(12)
              width: parent.width - Style.space(28)
              spacing: Style.space(10)

              Label {
                text: "\u{F02FD}"
                color: Commons.Color.accent
                font.pixelSize: Style.font.icon
              }
              Label {
                width: parent.width - Style.space(28)
                text: root.pausedNote
                color: root.muted
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }
            }
          }

          // ---- Today: the hourly columns and the day's numbers. Hidden until
          //      there is a break to show, so an empty chart cannot pass for a
          //      working one.
          Card {
            visible: !root.collapsed && (root.stats.total > 0 || root.graphPeak > 0)
            height: todayColumn.implicitHeight + Style.space(28)

            Column {
              id: todayColumn
              x: Style.space(14)
              y: Style.space(14)
              width: parent.width - Style.space(28)
              spacing: Style.space(10)

              Item {
                width: parent.width
                height: todayName.implicitHeight

                Label {
                  id: todayName
                  text: "Today"
                  color: root.muted
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                }
                Label {
                  anchors.right: parent.right
                  text: "last break " + Model.formatAgo(root.stats.sinceLastMs)
                  color: root.muted
                  font.pixelSize: Style.font.caption
                }
              }

              Item {
                id: chartArea
                width: parent.width
                height: Style.space(44)
                readonly property real step: width / Math.max(1, root.graph.span)
                readonly property real barWidth: Math.max(2, step - Style.space(4))

                Repeater {
                  model: root.graph.counts

                  Rectangle {
                    required property var modelData
                    required property int index
                    x: Math.round(index * chartArea.step)
                    width: chartArea.barWidth
                    anchors.bottom: parent.bottom
                    // An empty hour keeps a stub, so the span reads as a span.
                    height: modelData > 0
                      ? Math.max(Style.space(4), Math.round(chartArea.height * modelData / Math.max(1, root.graphPeak)))
                      : Style.space(3)
                    radius: Math.min(Style.cornerRadius, width / 2)
                    // The current hour is the solid one; earlier hours recede.
                    color: index === root.graph.span - 1 ? root.contentForeground
                      : modelData > 0 ? Util.alpha(root.contentForeground, 0.4)
                      : root.quietFill
                  }
                }
              }

              Item {
                width: parent.width
                height: Style.font.caption + Style.space(2)

                Repeater {
                  model: Model.hourAxis(root.graph.startHour, root.graph.span, 4)

                  Label {
                    required property var modelData
                    x: Math.round(modelData.index * chartArea.step)
                    text: modelData.label
                    color: root.muted
                    font.pixelSize: Style.font.caption
                  }
                }
              }

              Row {
                id: statRow
                width: parent.width
                spacing: Style.space(8)

                Repeater {
                  model: [
                    { value: String(root.stats.taken), label: "taken" },
                    { value: String(root.stats.skipped), label: "skipped" },
                    { value: String(root.stats.streak), label: "streak" },
                    { value: root.stats.total > 0 ? root.stats.adherencePercent + "%" : "—", label: "kept" }
                  ]

                  Rectangle {
                    required property var modelData
                    width: (statRow.width - statRow.spacing * 3) / 4
                    height: statColumn.implicitHeight + Style.space(16)
                    radius: Math.max(0, root.cardRadius - Style.space(6))
                    color: root.insetFill

                    Column {
                      id: statColumn
                      anchors.centerIn: parent
                      width: parent.width - Style.space(12)
                      spacing: Style.space(1)

                      Label {
                        width: parent.width
                        text: modelData.value
                        font.bold: true
                        font.pixelSize: Style.font.subtitle
                        elide: Text.ElideRight
                      }
                      Label {
                        width: parent.width
                        text: modelData.label
                        color: root.muted
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }
                    }
                  }
                }
              }
            }
          }

          // ---- The schedule. Amounts, so capsules that fill. Each is hidden
          //      with the rest while the timer is off.
          Column {
            width: parent.width
            visible: !root.collapsed
            spacing: Style.space(2)

            SliderBlock {
              rowName: "interval"
              label: "Every"
              unit: "min"
              glyph: "\u{F051B}"
              minimum: 5
              maximum: 120
              step: 5
              value: root.intervalMinutes
              onReleased: function (next) { root.act("setInterval", next) }
            }
            SliderBlock {
              rowName: "breakLength"
              label: "Look away for"
              unit: "sec"
              glyph: "\u{F0208}"
              minimum: 5
              maximum: 120
              step: 5
              value: root.breakSeconds
              onReleased: function (next) { root.act("setBreakLength", next) }
            }
          }

          // ---- The other two things that decide when a break may interrupt.
          Row {
            width: parent.width
            visible: !root.collapsed
            spacing: Style.space(10)

            PowerTile {
              width: (parent.width - parent.spacing) / 2
              rowName: "fullscreen"
              label: "Fullscreen"
              glyph: "\u{F0293}"
              on: root.pauseInFullscreen
              status: root.pauseInFullscreen ? "Waits for it" : "Interrupts"
              onActivated: root.flipFlag("pauseInFullscreen", root.pauseInFullscreen)
            }
            PowerTile {
              width: (parent.width - parent.spacing) / 2
              rowName: "strict"
              label: "Strict"
              glyph: "\u{F033E}"
              on: root.strictMode
              status: root.strictMode ? "No skipping" : "Off"
              onActivated: root.flipFlag("strictMode", root.strictMode)
            }
          }

          // ---- Actions. Skip drops out in strict mode, so the row divides by
          //      one fewer then.
          Row {
            id: actionRow
            width: parent.width
            visible: !root.collapsed
            spacing: Style.space(8)

            readonly property int wide: root.strictMode ? 1 : 2
            readonly property real iconWidth: root.rowHeight + Style.space(6)
            readonly property real wideWidth: (width - iconWidth - spacing * wide) / wide

            ActionButton {
              width: actionRow.wideWidth
              rowName: "breakNow"
              glyph: "\u{F0208}"
              text: "Break now"
              onActivated: root.breakNow()
            }
            ActionButton {
              width: actionRow.wideWidth
              visible: !root.strictMode
              rowName: "skip"
              glyph: "\u{F04AD}"
              text: "Skip"
              onActivated: root.act("skipCycle")
            }
            ActionButton {
              width: actionRow.iconWidth
              rowName: "clear"
              glyph: "\u{F09E7}"
              onActivated: root.act("resetHistory")
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.contentForeground
            strength: 0.08
          }

          Flow {
            width: parent.width
            spacing: Style.space(10)

            Repeater {
              model: root.keyHints
              delegate: KeyHint {}
            }
          }
        }
      }
    }
  }
}
