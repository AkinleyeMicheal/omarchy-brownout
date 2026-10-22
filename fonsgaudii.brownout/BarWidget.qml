import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Brownout indicator: a leaf in the bar that lights up while the emergency
// battery profile is engaged. Left click opens the control popup — mode
// switch (Auto/On/Off), live status, and the pause chooser backed by the
// usage sampler (`brownout top`).
BarWidget {
  id: root
  moduleName: "fonsgaudii.brownout"

  property var st: Model.parseState("")
  property var candidates: []
  property bool popupOpen: false
  property int pendingThreshold: -1

  readonly property bool engaged: st.engaged === true
  readonly property string mode: st.mode || "auto"
  readonly property bool candidatesLoading: topProc.running
  readonly property int autoThreshold: pendingThreshold > 0
    ? pendingThreshold : Number(st.engage_threshold || 20)
  readonly property int releaseThreshold: Number(st.release_threshold || 25)
  readonly property color leafColor: engaged
    ? (root.bar ? root.bar.urgent : Color.urgent)
    : (root.bar ? root.bar.foreground : Color.foreground)

  implicitWidth: Style.bar.iconSlot
  implicitHeight: barSize

  // Panel contract used by shell.summon/hide/toggle (and therefore by the
  // SUPER+ALT+B binding): Bar.findPanelWidget requires open(), close() and
  // `opened` on the bar-widget root.
  readonly property bool opened: popupOpen

  function open() { popupOpen = true }

  function close() { popupOpen = false }

  function refreshState() { stateFile.reload() }

  function refreshCandidates() {
    if (!topProc.running) topProc.running = true
  }

  function refreshAll() {
    refreshState()
    refreshCandidates()
    refresher.restart()
  }

  function adjustThreshold(delta) {
    var next = Math.max(5, Math.min(50, root.autoThreshold + delta))
    if (next === root.autoThreshold) return
    root.pendingThreshold = next
    pendingGuard.restart()
    if (root.bar) root.bar.run("brownout threshold " + next)
    refresher.restart()
  }

  // State file written atomically by the watcher/CLI.
  FileView {
    id: stateFile
    path: Quickshell.env("HOME") + "/.local/state/brownout/state.json"
    watchChanges: true
    printErrors: false
    onLoaded: {
      root.st = Model.parseState(text())
      if (root.pendingThreshold > 0 &&
          Number(root.st.engage_threshold) === root.pendingThreshold) {
        root.pendingThreshold = -1
      }
    }
    onLoadFailed: root.st = Model.parseState("")
    onFileChanged: reload()
  }

  Timer {
    id: pendingGuard
    interval: 4000
    repeat: false
    onTriggered: root.pendingThreshold = -1
  }

  Timer {
    interval: Math.max(2, Number(root.setting("refreshIntervalSec", 5))) * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: stateFile.reload()
  }

  // Follow-up refresh after a popup action (bar.run is fire-and-forget).
  Timer {
    id: refresher
    interval: 700
    repeat: false
    onTriggered: { stateFile.reload(); root.refreshCandidates() }
  }

  // No --live here: a 2 s CPU sample would leave the popup empty for four
  // seconds on every open. The popup only needs the historical metrics.
  Process {
    id: topProc
    command: ["brownout", "top", "--json", "--limit", String(root.setting("topLimit", 8))]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.candidates = Model.parseTop(text)
    }
  }

  onPopupOpenChanged: {
    if (popupOpen) {
      flick.contentY = 0
      refreshCandidates()
    }
  }

  Text {
    id: glyph
    anchors.centerIn: parent
    textFormat: Text.PlainText
    text: "\uF06C" // nf-fa-leaf — verified present in JetBrainsMono Nerd Font
    color: root.leafColor
    opacity: root.engaged ? 1.0 : 0.35
    font.family: root.bar ? root.bar.fontFamily : "monospace"
    font.pixelSize: Style.font.icon
    renderType: Text.NativeRendering
    Behavior on color {
      enabled: !root.bar || root.bar.foregroundAnimationEnabled
      ColorAnimation { duration: 160 }
    }
    Behavior on opacity { NumberAnimation { duration: 160 } }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.popupOpen = !root.popupOpen
    onEntered: if (root.bar) root.bar.showTooltip(root, "Brownout — " + Model.statusText(root.st) + " (" + Model.modeLabel(root.mode) + ")")
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(420))
    // Header stays pinned; only the service list scrolls. The card is capped at
    // ~560 px so a long list never makes the popup grow to the screen edge.
    contentHeight: popup.fittedContentHeight(
      headerColumn.implicitHeight + Style.space(10) + bodyColumn.implicitHeight,
      Style.space(560))

    // PopupCard paints Color.popups.background, which can differ from the bar
    // surface; derive popup text from the popup palette so contrast holds in
    // every theme. Secondary text is an explicit alpha of the primary colour
    // instead of Color.muted (tuned for the bar, not the popup).
    readonly property color fg: Color.popups.text
    readonly property color fgDim: Util.alpha(Color.popups.text, 0.76)
    readonly property color fgFaint: Util.alpha(Color.popups.text, 0.5)

    // Fixed header: title, mode switch, live status/metrics and threshold
    // controls remain visible while the candidate list scrolls below.
    Column {
      id: headerColumn
      width: parent.width
      spacing: Style.space(10)

      // ---- header: title + mode segmented control ------------------------
        Row {
          id: headerRow
          width: parent.width
          spacing: Style.space(8)

          Text {
            id: titleText
            text: "\uF06C Brownout"
            color: root.engaged ? Color.urgent : popup.fg
            font.family: root.bar ? root.bar.fontFamily : "monospace"
            font.pixelSize: Style.font.subtitle
            font.bold: true
            anchors.verticalCenter: parent.verticalCenter
          }
          Item {
            width: Math.max(0, headerRow.width - titleText.implicitWidth - modeRow.implicitWidth - headerRow.spacing)
            height: 1
          }

          Row {
            id: modeRow
            spacing: Style.space(4)
            Repeater {
              model: ["auto", "on", "off"]
              delegate: Button {
                required property string modelData
                text: Model.modeLabel(modelData)
                selected: root.mode === modelData
                bordered: !selected
                foreground: popup.fg
                fontSize: Style.font.caption
                fontFamily: root.bar ? root.bar.fontFamily : "monospace"
                horizontalPadding: Style.space(9)
                verticalPadding: Style.space(3)
                onClicked: {
                  if (root.bar) root.bar.run("brownout " + modelData)
                  refresher.restart()
                }
              }
            }
          }
        }

        // ---- status --------------------------------------------------------
        Text {
          width: parent.width
          text: Model.statusText(root.st)
          color: root.engaged ? Color.urgent : popup.fg
          font.family: root.bar ? root.bar.fontFamily : "monospace"
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }
        Text {
          width: parent.width
          text: Model.powerText(root.st) + "  ·  " + Model.profileSummary(root.st)
          color: popup.fgDim
          font.family: root.bar ? root.bar.fontFamily : "monospace"
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Rectangle { width: parent.width; height: 1; color: Color.popups.border }

        // ---- auto trigger threshold ----------------------------------------
        Row {
          id: thresholdRow
          width: parent.width
          spacing: Style.space(5)

          Text {
            id: thresholdLabel
            text: "Auto-engage"
            color: popup.fgDim
            font.family: root.bar ? root.bar.fontFamily : "monospace"
            font.pixelSize: Style.font.body
            anchors.verticalCenter: parent.verticalCenter
          }
          Item {
            width: Math.max(0, thresholdRow.width - thresholdLabel.implicitWidth -
              minusBtn.implicitWidth - thresholdValue.width - plusBtn.implicitWidth -
              4 * thresholdRow.spacing)
            height: 1
          }
          Button {
            id: minusBtn
            text: "−5"
            bordered: true
            foreground: popup.fg
            fontSize: Style.font.caption
            horizontalPadding: Style.space(7)
            verticalPadding: Style.space(2)
            enabled: root.autoThreshold > 5
            opacity: enabled ? 1 : 0.35
            onClicked: root.adjustThreshold(-5)
          }
          Text {
            id: thresholdValue
            width: Style.space(38)
            text: root.autoThreshold + "%"
            color: popup.fg
            font.family: root.bar ? root.bar.fontFamily : "monospace"
            font.pixelSize: Style.font.body
            font.bold: true
            horizontalAlignment: Text.AlignHCenter
            anchors.verticalCenter: parent.verticalCenter
          }
          Button {
            id: plusBtn
            text: "+5"
            bordered: true
            foreground: popup.fg
            fontSize: Style.font.caption
            horizontalPadding: Style.space(7)
            verticalPadding: Style.space(2)
            enabled: root.autoThreshold < 50
            opacity: enabled ? 1 : 0.35
            onClicked: root.adjustThreshold(5)
          }
        }
        Text {
          width: parent.width
          text: "On battery only · recovery releases at " + root.releaseThreshold +
            "% · AC return always releases"
          color: popup.fgFaint
          font.family: root.bar ? root.bar.fontFamily : "monospace"
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Rectangle { width: parent.width; height: 1; color: Color.popups.border }
    }

    // Scrollable body. Only this area moves; header/metrics/controls stay put.
    Flickable {
      id: flick
      anchors.top: headerColumn.bottom
      anchors.topMargin: Style.space(10)
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      contentWidth: width
      contentHeight: bodyColumn.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.VerticalFlick
      onContentHeightChanged: contentY = Math.min(contentY, Math.max(0, contentHeight - height))
      onHeightChanged: contentY = Math.min(contentY, Math.max(0, contentHeight - height))

      Column {
        id: bodyColumn
        width: flick.width - Style.space(12)
        spacing: Style.space(10)

        // ---- pause chooser -------------------------------------------------
        Text {
          text: "Pause during brownout"
          color: popup.fg
          font.family: root.bar ? root.bar.fontFamily : "monospace"
          font.pixelSize: Style.font.body
          font.bold: true
        }
        Text {
          width: parent.width
          text: root.st.paused_config.length === 0
            ? "Nothing pauses yet — pick services below (ranked by battery cost)."
            : "Click a row to add or remove it from the pause list."
          color: popup.fgDim
          font.family: root.bar ? root.bar.fontFamily : "monospace"
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Text {
          width: parent.width
          visible: root.candidates.length === 0
          text: root.candidatesLoading
            ? "Reading usage history…"
            : "No usage samples yet — the watcher records one per minute. You can also use `brownout pause-add <unit>`."
          color: popup.fgDim
          font.family: root.bar ? root.bar.fontFamily : "monospace"
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Column {
          id: rows
          width: parent.width
          spacing: Style.space(3)
          Repeater {
            model: root.candidates
            delegate: Rectangle {
              required property var modelData
              readonly property bool selected: modelData.selected === true
              width: rows.width
              height: rowTexts.implicitHeight + Style.space(12)
              radius: Style.space(6)
              color: rowMouse.containsMouse
                ? Style.hoverFillFor(popup.fg, Color.accent)
                : "transparent"

              Text {
                id: checkText
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Style.space(6)
                textFormat: Text.PlainText
                text: selected ? String.fromCodePoint(0xF0132) : String.fromCodePoint(0xF0131)
                color: selected ? Color.accent : popup.fgFaint
                font.family: root.bar ? root.bar.fontFamily : "monospace"
                font.pixelSize: Style.font.icon
              }
              Column {
                id: rowTexts
                anchors.left: parent.left
                anchors.right: checkText.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Style.space(6)
                spacing: 2
                Text {
                  width: rowTexts.width
                  text: modelData.name
                  color: popup.fg
                  font.family: root.bar ? root.bar.fontFamily : "monospace"
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }
                Text {
                  width: rowTexts.width
                  text: Model.fmtMetrics(modelData)
                  color: popup.fgDim
                  font.family: root.bar ? root.bar.fontFamily : "monospace"
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }
              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  if (root.bar) root.bar.run("brownout pause-toggle " + root.bar.shellQuote(modelData.id))
                  refresher.restart()
                }
              }
            }
          }
        }

        Text {
          width: parent.width
          text: "Sampled every minute · 14-day history · click a row to toggle"
          color: popup.fgFaint
          font.family: root.bar ? root.bar.fontFamily : "monospace"
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }

    // Interactive scrollbar: click the track to jump, drag the thumb to scroll.
    // It only appears when the capped card actually clips content.
    Item {
      id: scrollbar
      visible: flick.contentHeight > flick.height + 1
      width: Style.space(8)
      anchors.top: flick.top
      anchors.bottom: flick.bottom
      anchors.right: flick.right
      anchors.topMargin: Style.space(2)
      anchors.bottomMargin: Style.space(2)
      z: 2

      Rectangle {
        id: scrollTrack
        anchors.fill: parent
        radius: width / 2
        color: Util.alpha(popup.fg, 0.12)
      }

      Rectangle {
        id: scrollThumb
        width: parent.width
        height: Math.max(Style.space(24), scrollbar.height * flick.visibleArea.heightRatio)
        radius: width / 2
        color: scrollMouse.pressed ? popup.fg
          : (scrollMouse.containsMouse ? popup.fgDim : popup.fgFaint)
        y: (scrollbar.height - height) *
          Math.max(0, Math.min(1, flick.visibleArea.yPosition))
      }

      MouseArea {
        id: scrollMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        property real grabOffset: 0

        function jumpTo(mouseY) {
          var travel = scrollbar.height - scrollThumb.height
          if (travel <= 0) return
          var ratio = Math.max(0, Math.min(1, (mouseY - grabOffset) / travel))
          flick.contentY = ratio * Math.max(0, flick.contentHeight - flick.height)
        }

        onPressed: function(mouse) {
          var thumbTop = scrollThumb.y
          if (mouse.y >= thumbTop && mouse.y <= thumbTop + scrollThumb.height) {
            grabOffset = mouse.y - thumbTop
          } else {
            grabOffset = scrollThumb.height / 2
            jumpTo(mouse.y)
          }
        }
        onPositionChanged: function(mouse) {
          if (pressed) jumpTo(mouse.y)
        }
        onWheel: function(wheel) {
          var step = wheel.pixelDelta.y !== 0
            ? wheel.pixelDelta.y
            : (wheel.angleDelta.y / 120) * Style.space(42)
          flick.contentY = Math.max(0,
            Math.min(flick.contentHeight - flick.height, flick.contentY - step))
          wheel.accepted = true
        }
      }
    }
  }
}
