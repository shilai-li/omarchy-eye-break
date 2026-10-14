import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// The break screen: a fullscreen layer-shell surface on every output, holding
// a countdown and nothing else.
//
// It is a separate plugin kind from the bar widget so it can be a real
// fullscreen surface rather than a popup pinned to the bar. The shell routes
// `summon` here — a plugin that declares both bar-widget and overlay is owned
// by the panel loader, not by the bar.
//
// Every monitor shows the same thing on purpose. A break you can sit out by
// looking at the other screen is not a break.
Item {
  id: root

  // Injected by the shell's panel loader.
  property var shell: null
  property var manifest: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  property bool opened: false
  property int breakSeconds: 20
  property bool strict: false

  // Handed over in the summon payload so the overlay writes to the same file
  // the bar widget reads. Defaulted so `omarchy-shell shell summon
  // shilai_li.eye-break '{}'` from a terminal still does the right thing.
  property string statePath: Quickshell.env("HOME") + "/.local/state/omarchy/eye-break/state.json"

  property real startedAt: 0
  property real now: 0

  // Space adds time to the break in flight without touching the setting. It
  // is the one control that makes a break longer rather than shorter, which
  // is the direction worth making easy.
  property real extraMs: 0

  readonly property real totalMs: Math.max(1, breakSeconds * 1000 + extraMs)
  readonly property real elapsedMs: Math.max(0, now - startedAt)
  readonly property real remainingMs: Math.max(0, totalMs - elapsedMs)
  readonly property real progress: Model.clamp01(elapsedMs / totalMs)

  readonly property string fontFamily: Style.font.family
  readonly property color foreground: Commons.Color.foreground
  readonly property color muted: Commons.Color.muted
  // Urgent means "this is taking over your screen", the same as the BREAK
  // badge on the dashboard. It is the only color on the surface.
  readonly property color urgent: Commons.Color.urgent
  // Denser than the menu scrim: the point of the surface is that there is
  // nothing left to read behind it.
  readonly property color scrim: Util.alpha(Commons.Color.background, 0.94)
  readonly property color quietFill: Util.alpha(foreground, 0.12)
  readonly property color cardFill: Util.alpha(foreground, 0.08)

  // The theme decides whether anything is round, as on the dashboard.
  readonly property bool rounded: Style.cornerRadius > 0

  // A fixed width: the bar is centered on an empty screen, so it has no
  // column to line up with and nothing to fit inside.
  readonly property int barWidth: Style.space(420)

  // One button in the row under the bar: the key, then what it does. The
  // surface still swallows every stray click; these two are the exceptions,
  // because pressing a labelled button is not a stray click.
  component KeyButton: Rectangle {
    id: button
    property string key: ""
    property string text: ""
    signal activated()

    width: buttonRow.implicitWidth + Style.space(28)
    height: Style.space(38)
    radius: root.rounded ? height / 2 : 0
    color: root.cardFill

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: button.activated()
    }

    Row {
      id: buttonRow
      anchors.centerIn: parent
      spacing: Style.space(10)

      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: keyText.implicitWidth + Style.space(12)
        height: keyText.implicitHeight + Style.space(4)
        radius: root.rounded ? Style.space(5) : 0
        color: root.quietFill

        Text {
          id: keyText
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: button.key
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: button.text
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
      }
    }
  }

  function open(payloadJson) {
    // The shell delivers queued payloads one at a time. A second delivery for
    // a break already on screen must extend nothing and restart nothing.
    if (root.opened) return

    var payload = ({})
    try {
      payload = JSON.parse(payloadJson || "{}")
    } catch (e) {
      // Summoned by hand with something that is not JSON. The defaults are a
      // perfectly good 20-second break.
      payload = ({})
    }

    root.breakSeconds = Model.breakSeconds(payload.seconds)
    root.strict = payload.strict === true
    if (payload.statePath) root.statePath = String(payload.statePath)

    root.extraMs = 0
    root.startedAt = Date.now()
    root.now = root.startedAt
    root.opened = true
    stateFile.reload()
  }

  // Called by the shell on hide, including the hide dismiss() asks for. Only
  // a close arriving from outside still has a break to settle.
  function close() {
    if (root.opened) root.finish("skipped")
  }

  function skip() {
    if (root.strict) return
    root.finish("skipped")
  }

  function extend() {
    if (!root.opened) return
    root.extraMs += 20000
  }

  function finish(outcome) {
    if (!root.opened) return
    root.opened = false
    root.recordOutcome(outcome)
    root.dismiss()
  }

  // The overlay, not the widget, is what knows how the break actually ended,
  // so it owns the write. recordBreak also starts the next cycle, which is
  // why the bar's countdown restarts the moment this surface comes down.
  function recordOutcome(outcome) {
    var at = Date.now()
    var current = Model.parseState(stateFile.text(), at)
    stateFile.setText(Model.serializeState(Model.recordBreak(current, outcome, at)))
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "shilai_li.eye-break")
  }

  function handleKey(event) {
    if (event.key === Qt.Key_Escape) {
      root.skip()
      event.accepted = true
    } else if (event.key === Qt.Key_Space) {
      root.extend()
      event.accepted = true
    }
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    atomicWrites: true
    printErrors: false
  }

  // 250ms rather than a second: the countdown only needs whole seconds, but
  // the bar beside it is hundreds of pixels wide and would step in visible
  // jumps.
  Timer {
    interval: 250
    repeat: true
    running: root.opened
    onTriggered: {
      root.now = Date.now()
      if (root.remainingMs <= 0) root.finish("taken")
    }
  }

  Variants {
    model: Quickshell.screens

    delegate: Component {
      PanelWindow {
        id: window
        required property var modelData

        screen: modelData
        visible: root.opened
        color: "transparent"
        anchors { top: true; bottom: true; left: true; right: true }
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "omarchy-eye-break"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

        Rectangle {
          anchors.fill: parent
          color: root.scrim
        }

        // Swallows every click. The break is dismissed with a key or a
        // labelled button, never a stray click on a surface that just covered
        // your work, which should not count as "done looking away".
        MouseArea {
          anchors.fill: parent
          acceptedButtons: Qt.AllButtons
          onClicked: {}
        }

        Item {
          id: keyCatcher
          anchors.fill: parent
          focus: true
          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function(event) { root.handleKey(event) }

          Component.onCompleted: keyCatcher.forceActiveFocus()
        }

        Connections {
          target: root
          function onOpenedChanged() {
            if (root.opened) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
          }
        }

        Column {
          anchors.centerIn: parent
          spacing: Style.space(28)

          // The badge the dashboard shows while a break is on, at screen size.
          Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            width: badgeRow.implicitWidth + Style.space(32)
            height: badgeRow.implicitHeight + Style.space(14)
            radius: root.rounded ? height / 2 : 0
            color: Util.alpha(root.urgent, 0.16)

            Row {
              id: badgeRow
              anchors.centerIn: parent
              spacing: Style.space(8)

              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(8)
                height: width
                radius: width / 2
                color: root.urgent
              }
              Text {
                textFormat: Text.PlainText
                text: "LOOK AWAY"
                color: root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.letterSpacing: 2
                font.bold: true
              }
            }
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            text: Model.formatCountdown(root.remainingMs)
            color: root.foreground
            font.family: root.fontFamily
            // Deliberately outside the Style.font.* scale, and the largest
            // thing on the screen: it is the only reason the screen is there.
            font.pixelSize: Style.fontPx(7)
            font.bold: true
          }

          // Fills left to right, the same as the capsules on the dashboard.
          Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            width: root.barWidth
            height: Style.space(12)
            radius: root.rounded ? height / 2 : 0
            color: root.quietFill

            Rectangle {
              height: parent.height
              width: parent.width * root.progress
              radius: parent.radius
              color: root.urgent
            }
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            text: "20 feet away · " + root.breakSeconds + " seconds · blink"
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
          }

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(12)

            KeyButton {
              visible: !root.strict
              key: "esc"
              text: "Skip"
              onActivated: root.skip()
            }

            // Strict mode takes the skip away and says so. Space still adds
            // time: the one control that makes a break longer.
            Rectangle {
              visible: root.strict
              width: strictRow.implicitWidth + Style.space(28)
              height: Style.space(38)
              radius: root.rounded ? height / 2 : 0
              color: root.cardFill

              Row {
                id: strictRow
                anchors.centerIn: parent
                spacing: Style.space(8)

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: "\u{F033E}"
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.icon
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: "Strict mode — sit tight"
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
              }
            }

            KeyButton {
              key: "space"
              text: "+20 s"
              onActivated: root.extend()
            }
          }
        }
      }
    }
  }
}
