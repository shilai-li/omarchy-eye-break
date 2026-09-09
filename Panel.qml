import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The eye-break dashboard: three boxed sections stacked the way btop stacks
// its meters — section name cut into the top border, dense monospace
// readouts, block-glyph graphs, and a key rail along the bottom.
//
// The boxes are Rectangles and the graphs are text. Column alignment between
// rows comes from the QML layout; only the glyphs *inside* one meter string
// rely on the shell font being monospace, which it is by default.
//
// This panel owns no state. BarWidget.qml holds the schedule and does every
// write; everything here reads off `hostWidget` and calls back into it, so
// two monitors showing this panel at once cannot disagree.
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
  readonly property bool pauseWhenIdle: host ? host.pauseWhenIdle : true
  readonly property bool pauseInFullscreen: host ? host.pauseInFullscreen : false
  readonly property bool strictMode: host ? host.strictMode : false

  readonly property string status: Model.statusOf(state, intervalMs, now)
  readonly property real remainingMs: Model.remainingMs(state, intervalMs, now)
  readonly property real progress: Model.cycleProgress(state, intervalMs, now)
  readonly property real urgency: status === "paused" || status === "idle" || status === "break"
    ? 0 : Model.urgency(progress)
  readonly property int progressPercent: Math.round(progress * 100)

  readonly property var stats: Model.statsFor(state.history, now, intervalMs)
  readonly property var graph: Model.hourlyCounts(state.history, now, graphColumns)

  readonly property string heroText: status === "break" ? "BREAK" : Model.formatCountdown(remainingMs)
  readonly property string captionText: {
    if (status === "break") return "look 20 feet away"
    if (status === "paused") return "paused — space to resume"
    if (status === "idle") return "paused while you are away"
    return "cycle " + (stats.total + 1) + " today · look 20 feet away for " + breakSeconds + "s"
  }

  // ---- Theme. Nothing here names a color; the palette does.
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(contentForeground, 1.5)
  readonly property color dimmer: Qt.darker(contentForeground, 2.0)
  readonly property color frameColor: Style.normalBorderFor(contentForeground, Color.accent)
  readonly property color accentColor: Style.selectedStateColor(contentForeground, Color.accent)
  readonly property color hotColor: {
    if (root.urgency <= 0) return root.accentColor
    var hot = Color.urgent
    return Qt.tint(root.accentColor, Qt.rgba(hot.r, hot.g, hot.b, root.urgency))
  }

  readonly property int sectionPaddingX: Style.space(14)
  readonly property int sectionPaddingTop: Style.space(16)
  readonly property int sectionPaddingBottom: Style.space(12)

  // One monospace cell. Every meter, graph and axis label is placed off this,
  // which is what keeps the columns lined up when the theme changes font size.
  // Named innerWidth rather than contentWidth so it cannot be confused with
  // KeyboardPanel's property of that name a few lines down.
  readonly property real cellWidth: Math.max(1, cellMetrics.advanceWidth)
  readonly property real innerWidth: Math.max(Style.space(120), column.width - sectionPaddingX * 2)
  readonly property int graphColumns: Math.max(8, Math.min(24, Math.floor(innerWidth / cellWidth)))

  // The meter stops short of the panel edge to leave room for the percentage
  // sitting at the end of the same row.
  readonly property int meterCells: Math.max(8, Math.floor((innerWidth - Style.space(46)) / cellWidth))
  readonly property int meterFilled: Model.meterFilledCells(progress, meterCells)

  // ---- Lifecycle. Mirrors the clock's: the popout coordinator is handed
  //      over on show, so the hover-reveal flag is set after, not before.
  function open() {
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

  function handleTextKey(text) {
    var key = String(text).toLowerCase()
    if (key === "s") root.act("skipCycle")
    else if (key === "b") { root.act("breakNow"); root.close() }
    else if (key === "r") root.act("resetHistory")
    else if (key === "i") root.flipFlag("pauseWhenIdle", root.pauseWhenIdle)
    else if (key === "f") root.flipFlag("pauseInFullscreen", root.pauseInFullscreen)
    else if (key === "+" || key === "=") root.stepInterval(5)
    else if (key === "-" || key === "_") root.stepInterval(-5)
    else if (key === "]") root.stepBreak(5)
    else if (key === "[") root.stepBreak(-5)
  }

  TextMetrics {
    id: cellMetrics
    font.family: root.contentFontFamily
    font.pixelSize: Style.font.body
    text: "█"
  }

  // ---- A btop box: hairline frame, name cut into the top border, optional
  //      badge cut into the same border on the right.
  component Section: Item {
    id: section

    property string title: ""
    property string badge: ""
    default property alias sectionData: body.data

    implicitHeight: frame.height

    Rectangle {
      id: frame
      anchors.left: parent.left
      anchors.right: parent.right
      height: body.implicitHeight + root.sectionPaddingTop + root.sectionPaddingBottom
      color: "transparent"
      radius: Style.cornerRadius
      border.width: Style.spacing.hairline
      border.color: root.frameColor

      Column {
        id: body
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.leftMargin: root.sectionPaddingX
        anchors.rightMargin: root.sectionPaddingX
        anchors.topMargin: root.sectionPaddingTop
        spacing: Style.space(7)
      }
    }

    // The chip paints the panel's own background so the border appears cut
    // rather than crossed out.
    Rectangle {
      x: root.sectionPaddingX
      y: -Math.round(height / 2)
      width: titleText.implicitWidth + Style.space(10)
      height: titleText.implicitHeight
      color: Color.popups.background

      Text {
        id: titleText
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: section.title
        color: root.dim
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
        font.letterSpacing: 1
        font.bold: true
      }
    }

    Rectangle {
      visible: section.badge !== ""
      x: frame.width - width - root.sectionPaddingX
      y: -Math.round(height / 2)
      width: badgeText.implicitWidth + Style.space(10)
      height: badgeText.implicitHeight
      color: Color.popups.background

      Text {
        id: badgeText
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: section.badge
        color: root.dimmer
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.caption
        font.letterSpacing: 1
      }
    }
  }

  // ---- One stat cell: tiny all-caps label over the number it names.
  component Stat: Column {
    id: stat

    property string label: ""
    property string value: ""

    spacing: Style.space(2)

    Text {
      textFormat: Text.PlainText
      text: stat.label
      color: root.dimmer
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      font.letterSpacing: 1
    }

    Text {
      textFormat: Text.PlainText
      text: stat.value
      color: root.contentForeground
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.subtitle
    }
  }

  // ---- A schedule row: name on the left, control on the right.
  component Field: Item {
    id: field

    property string label: ""
    default property alias fieldData: holder.data

    implicitHeight: Math.max(fieldLabel.implicitHeight, holder.implicitHeight)

    Text {
      id: fieldLabel
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: field.label
      color: root.dim
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      font.letterSpacing: 1
    }

    Row {
      id: holder
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(10)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    // The same 560 the clock panel uses, so the two line up when Tab walks
    // between them.
    contentWidth: panel.fittedContentWidth(Style.space(560))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onCloseRequested: root.close()
      onActivateRequested: root.act("togglePause")
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { root.handleTextKey(t) }
      onMoveRequested: function(dx, dy) {
        // Up/down walk the interval, left/right the break length — the same
        // axes the two sliders below sit on. Down is +1, so the sign flips.
        if (dy !== 0) root.stepInterval(-dy * 5)
        if (dx !== 0) root.stepBreak(dx * 5)
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
          spacing: Style.space(18)

          // The first section's name chip pokes above its frame; without this
          // it would be clipped by the panel edge.
          Item { width: 1; height: Style.space(4) }

          // ------------------------------------------------ next break
          Section {
            width: column.width
            title: "next break"
            badge: root.intervalMinutes + "m · " + root.breakSeconds + "s"

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              textFormat: Text.PlainText
              text: root.heroText
              color: root.status === "paused" || root.status === "idle"
                ? root.dim
                : root.contentForeground
              font.family: root.contentFontFamily
              // Deliberately outside the Style.font.* scale — this is the one
              // number the panel exists to show. It still rides the theme's
              // base size, so a larger font makes it larger too.
              font.pixelSize: Style.fontPx(3.6)
              font.bold: true
            }

            Item {
              width: parent.width
              height: meterRow.implicitHeight

              Row {
                id: meterRow
                spacing: 0

                // Two runs rather than one string: the filled half carries
                // the urgency color while the track stays quiet behind it.
                Text {
                  textFormat: Text.PlainText
                  text: Model.repeat("█", root.meterFilled)
                  color: root.hotColor
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                }

                Text {
                  textFormat: Text.PlainText
                  text: Model.repeat("░", root.meterCells - root.meterFilled)
                  color: root.dimmer
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                }
              }

              Text {
                anchors.right: parent.right
                anchors.verticalCenter: meterRow.verticalCenter
                textFormat: Text.PlainText
                text: root.progressPercent + "%"
                color: root.dim
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.captionText
              color: root.dim
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          // ---------------------------------------------------- today
          Section {
            width: column.width
            title: "today"

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: Model.sparkline(root.graph.counts, Model.SPARK_LEVELS)
              color: root.accentColor
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
            }

            // Hour labels placed off the same cell width the graph is drawn
            // in, so each one sits under the column it names.
            Item {
              width: parent.width
              height: Style.font.caption + Style.space(2)

              Repeater {
                model: Model.hourAxis(root.graph.startHour, root.graph.span, 4)

                Text {
                  required property var modelData
                  x: Math.round(modelData.index * root.cellWidth)
                  textFormat: Text.PlainText
                  text: modelData.label
                  color: root.dimmer
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }

            Item { width: 1; height: Style.space(2) }

            // Flow, not Row: at a large theme font size six stats no longer
            // fit on one line, and wrapping beats clipping the last of them.
            Flow {
              width: parent.width
              spacing: Style.space(22)

              Stat { label: "TAKEN"; value: String(root.stats.taken) }
              Stat { label: "SKIPPED"; value: String(root.stats.skipped) }
              Stat { label: "STREAK"; value: String(root.stats.streak) }
              Stat { label: "SCREEN"; value: Model.formatDuration(root.stats.screenMs) }
              Stat {
                label: "ADHERENCE"
                value: root.stats.total > 0 ? root.stats.adherencePercent + "%" : "—"
              }
              Stat { label: "LAST"; value: Model.formatAgo(root.stats.sinceLastMs) }
            }
          }

          // ------------------------------------------------- schedule
          Section {
            width: column.width
            title: "schedule"

            Field {
              width: parent.width
              label: "INTERVAL"

              PanelSlider {
                id: intervalSlider
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(220)
                bar: root.bar
                minimum: 5
                maximum: 120
                step: 5
                integer: true
                value: root.intervalMinutes
                onReleased: function(v) { root.act("setInterval", v) }
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(56)
                horizontalAlignment: Text.AlignRight
                textFormat: Text.PlainText
                text: Math.round(intervalSlider.liveValue) + " min"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }

            Field {
              width: parent.width
              label: "BREAK"

              PanelSlider {
                id: breakSlider
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(220)
                bar: root.bar
                minimum: 5
                maximum: 120
                step: 5
                integer: true
                value: root.breakSeconds
                onReleased: function(v) { root.act("setBreakLength", v) }
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(56)
                horizontalAlignment: Text.AlignRight
                textFormat: Text.PlainText
                text: Math.round(breakSlider.liveValue) + " sec"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }

            PanelSeparator {
              width: parent.width
              foreground: root.contentForeground
            }

            Field {
              width: parent.width
              label: "PAUSE WHEN IDLE"

              ToggleSwitch {
                anchors.verticalCenter: parent.verticalCenter
                checked: root.pauseWhenIdle
                foreground: root.contentForeground
                onToggled: root.flipFlag("pauseWhenIdle", root.pauseWhenIdle)
              }
            }

            Field {
              width: parent.width
              label: "PAUSE IN FULLSCREEN"

              ToggleSwitch {
                anchors.verticalCenter: parent.verticalCenter
                checked: root.pauseInFullscreen
                foreground: root.contentForeground
                onToggled: root.flipFlag("pauseInFullscreen", root.pauseInFullscreen)
              }
            }

            Field {
              width: parent.width
              label: "STRICT MODE (NO SKIP)"

              ToggleSwitch {
                anchors.verticalCenter: parent.verticalCenter
                checked: root.strictMode
                foreground: root.contentForeground
                onToggled: root.flipFlag("strictMode", root.strictMode)
              }
            }
          }

          // ---- The key rail. It is the plugin's promise that this thing is
          //      keyboard-driven, so it stays even when space is tight.
          Text {
            width: column.width
            textFormat: Text.PlainText
            text: "space pause   s skip   b break now   ↑↓ interval   ←→ length   i idle   f fullscreen   r reset   esc close"
            color: root.dimmer
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Item { width: 1; height: Style.space(2) }
        }
      }
    }
  }
}
