// Countdown for the Omarchy bar.
//
// The widget shows one countdown at a time; scrolling cycles through
// the configured ones and clicking opens the panel, which replaces the old
// bash TUI to add, edit, reorder and delete entries.
//
// Like Omarchy's Clock and Power, the bar button and popup are in the same
// file: the manifest only declares kind "bar-widget" and this file is its
// entryPoints.barWidget.

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "cristianocorsi.countdown"
  ipcTarget: "cristianocorsi.countdown"

  // ---- Settings -----------------------------------------------------------
  //
  // `barWidget.defaults` in the manifest only serves to initialize the settings
  // UI: the shell does not merge it into settings at runtime. The default
  // that matters is the fallback below, which must be kept aligned with the manifest.
  readonly property string displayFormat: String(setting("format", "days"))
  readonly property int maxLabel: Math.max(4, Number(setting("maxLabel", 16)))
  readonly property bool showProgress: setting("showProgress", true) === true
  readonly property int alertDays: Math.max(0, Number(setting("alertDays", 3)))

  // ---- State --------------------------------------------------------------

  property double nowMs: Date.now()

  readonly property var currentEntry: store.current
  readonly property string currentStatus: currentEntry ? Model.statusOf(currentEntry, nowMs) : "empty"
  readonly property real currentElapsed: currentEntry ? Model.elapsedPercent(currentEntry, nowMs) : 0
  readonly property bool urgent: {
    if (!currentEntry) return false
    if (currentStatus === "expired" || currentStatus === "invalid") return true
    return alertDays > 0 && Model.remainingDays(currentEntry, nowMs) <= alertDays
  }

  readonly property string barLabel: currentEntry
    ? Model.barText(currentEntry, nowMs, displayFormat, maxLabel)
    : "󰃭 No countdown"

  // ---- Panel form ---------------------------------------------------------
  //
  // editIndex: -1 no form open, -2 new entry, >= 0 editing that one.
  property int editIndex: -1
  property int confirmDeleteIndex: -1
  property string formError: ""
  property string draftLabel: ""
  property string draftStart: ""
  property string draftEnd: ""
  property string draftFormat: "days"

  readonly property bool formOpen: editIndex !== -1

  function openNew() {
    editIndex = -2
    confirmDeleteIndex = -1
    formError = ""
    draftLabel = ""
    draftStart = Model.formatDate(Model.today())
    draftEnd = ""
    draftFormat = "days"
  }

  function openEdit(index) {
    var entry = store.entries[index]
    if (!entry) return
    editIndex = index
    confirmDeleteIndex = -1
    formError = ""
    draftLabel = String(entry.label || "")
    draftStart = String(entry.start || "")
    draftEnd = String(entry.end || "")
    draftFormat = String(entry.format || "days")
  }

  function closeForm() {
    editIndex = -1
    formError = ""
  }

  function submitForm() {
    var entry = {
      label: draftLabel.trim(),
      start: draftStart.trim(),
      end: draftEnd.trim(),
      format: draftFormat
    }

    var problem = Model.validate(entry)
    if (problem !== "") {
      formError = problem
      return
    }

    // Dates are rewritten in canonical zero-padded form: the file accepts
    // "2026-10-3" for compatibility with old data, but does not produce it.
    entry.start = Model.formatDate(Model.parseDate(entry.start))
    entry.end = Model.formatDate(Model.parseDate(entry.end))

    var ok = editIndex === -2 ? store.addEntry(entry) : store.updateEntry(editIndex, entry)
    if (ok) closeForm()
    else formError = "Save failed"
  }

  function deleteEntry(index) {
    if (store.removeEntry(index)) {
      confirmDeleteIndex = -1
      if (editIndex === index) closeForm()
    }
  }

  onOpenedChanged: if (!opened) { closeForm(); confirmDeleteIndex = -1 }

  Store { id: store }

  // Minute precision: a countdown does not change faster than this,
  // even in the "auto" format which counts minutes in the last hour.
  SystemClock {
    precision: SystemClock.Minutes
    onDateChanged: root.nowMs = Date.now()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  IpcHandler {
    target: "cristianocorsi.countdown"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function next(): void { store.cycle(1) }
    function previous(): void { store.cycle(-1) }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barLabel
    active: root.urgent
    tooltipText: {
      if (store.count === 0) return "No countdown — click to add one"
      var lines = []
      for (var i = 0; i < store.entries.length; i++) {
        var d = Model.describe(store.entries[i], root.nowMs)
        lines.push((i === store.currentIndex ? "▸ " : "  ") + d.label + "  " + d.end + "  " + d.remaining)
      }
      return lines.join("\n")
    }

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) store.cycle(1)
      else root.toggle()
    }
    onWheelMoved: function(delta) { store.cycle(delta > 0 ? -1 : 1) }

    // Native progress. The old script calculated this percentage and
    // output it as `percentage`, but the bar's "command" module
    // ignored it: here it is finally visible.
    Rectangle {
      visible: root.showProgress && root.currentStatus === "active" && !root.vertical
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(3)
      // Progress grows from the left edge of the label, not the center
      // of the button: WidgetButton centers the text, so the starting
      // point must be calculated instead of anchored.
      x: Math.round((parent.width - button.labelWidth) / 2)
      width: Math.max(1, button.labelWidth * (root.currentElapsed / 100))
      height: Math.max(1, Style.space(2))
      radius: height / 2
      // Not Color.accent: the bar already uses a 2px accent line on the
      // inner edge of the module to say "this panel is open"
      // (Bar.qml, openPanelIndicator). Drawing the progress in the same
      // way made it read as that indicator instead of progress. Here it is
      // the text color, dimmed: it reads like a label underline, which is
      // what it is.
      color: root.urgent && root.bar ? root.bar.urgent
                                     : (root.bar ? root.bar.barForeground : Color.foreground)
      opacity: root.urgent ? 0.5 : 0.3

      Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
    }
  }

  KeyboardPanel {
    id: card
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: card.fittedContentWidth(Style.space(420))
    contentHeight: card.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.formOpen ? root.closeForm() : root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(10)

        PanelSectionHeader {
          width: parent.width
          text: "Countdown"
        }

        Text {
          width: parent.width
          visible: store.count === 0 && !root.formOpen
          text: "No countdown configured."
          color: root.barForeground
          opacity: 0.6
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        // ---- List ---------------------------------------------------------

        Repeater {
          model: root.formOpen ? [] : store.entries

          Item {
            id: row
            required property var modelData
            required property int index
            readonly property var info: Model.describe(modelData, root.nowMs)
            readonly property bool isCurrent: index === store.currentIndex
            readonly property bool confirming: root.confirmDeleteIndex === index

            width: column.width
            implicitHeight: rowBody.implicitHeight + Style.space(8)

            Column {
              id: rowBody
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(4)

              // Title + remaining time + actions
              Item {
                width: parent.width
                implicitHeight: Math.max(labelText.implicitHeight, actions.implicitHeight)

                Text {
                  id: labelText
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - actions.width - remainingText.width - Style.space(16)
                  elide: Text.ElideRight
                  text: (row.isCurrent ? "▸ " : "") + row.info.label
                  color: root.barForeground
                  opacity: row.isCurrent ? 1 : 0.75
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.body
                }

                Text {
                  id: remainingText
                  anchors.right: actions.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  text: row.info.remaining
                  color: row.info.status === "active" ? root.barForeground
                                                      : (root.bar ? root.bar.urgent : Color.urgent)
                  opacity: row.info.status === "active" ? 0.8 : 1
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }

                Row {
                  id: actions
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)
                  visible: !row.confirming

                  PanelActionButton {
                    iconText: "󰅃"
                    tooltipText: "Move up"
                    enabled: row.index > 0
                    opacity: enabled ? 1 : 0.3
                    onClicked: store.moveEntry(row.index, -1)
                  }

                  PanelActionButton {
                    iconText: "󰅀"
                    tooltipText: "Move down"
                    enabled: row.index < store.count - 1
                    opacity: enabled ? 1 : 0.3
                    onClicked: store.moveEntry(row.index, 1)
                  }

                  PanelActionButton {
                    iconText: "󰏫"
                    tooltipText: "Edit"
                    onClicked: root.openEdit(row.index)
                  }

                  PanelActionButton {
                    iconText: "󰆴"
                    tooltipText: "Delete"
                    onClicked: root.confirmDeleteIndex = row.index
                  }
                }

                // Inline confirmation: a single line, without opening a dialog
                // over a popup that closes at the first click outside.
                Row {
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(6)
                  visible: row.confirming

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Delete?"
                    color: root.bar ? root.bar.urgent : Color.urgent
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.bodySmall
                  }

                  Button {
                    text: "Yes"
                    onClicked: root.deleteEntry(row.index)
                  }

                  Button {
                    text: "No"
                    onClicked: root.confirmDeleteIndex = -1
                  }
                }
              }

              // End date + progress
              Item {
                width: parent.width
                implicitHeight: dateText.implicitHeight + Style.space(5)

                Text {
                  id: dateText
                  anchors.left: parent.left
                  text: row.info.end + (row.info.format === "days" ? "" : "  ·  " + row.info.format)
                  color: root.barForeground
                  opacity: 0.5
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                }

                Rectangle {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.bottom: parent.bottom
                  height: Math.max(1, Style.space(2))
                  radius: height / 2
                  color: root.barForeground
                  opacity: 0.15

                  Rectangle {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: parent.width * (row.info.elapsed / 100)
                    radius: parent.radius
                    color: row.info.status === "active" ? Color.accent
                                                        : (root.bar ? root.bar.urgent : Color.urgent)
                  }
                }
              }
            }

            MouseArea {
              anchors.fill: parent
              acceptedButtons: Qt.LeftButton
              // Clicking the row selects which countdown is shown in the bar.
              // Actions on the right take precedence because they are on top.
              onClicked: store.setIndex(row.index)
              z: -1
            }
          }
        }

        // ---- Form ---------------------------------------------------------

        Column {
          width: parent.width
          visible: root.formOpen
          spacing: Style.space(6)

          Text {
            text: root.editIndex === -2 ? "New countdown" : "Edit countdown"
            color: root.barForeground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
          }

          TextField {
            width: parent.width
            placeholderText: "Label"
            text: root.draftLabel
            onTextChanged: root.draftLabel = text
            onAccepted: root.submitForm()
          }

          Row {
            width: parent.width
            spacing: Style.space(6)

            TextField {
              width: (parent.width - Style.space(6)) / 2
              placeholderText: "Start (YYYY-MM-DD)"
              text: root.draftStart
              onTextChanged: root.draftStart = text
              onAccepted: root.submitForm()
            }

            TextField {
              width: (parent.width - Style.space(6)) / 2
              placeholderText: "End (YYYY-MM-DD)"
              text: root.draftEnd
              onTextChanged: root.draftEnd = text
              onAccepted: root.submitForm()
            }
          }

          Dropdown {
            width: parent.width
            label: "Format"
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            options: [
              { value: "days", label: "Days" },
              { value: "percentage", label: "Remaining percentage" },
              { value: "auto", label: "Auto (days, then hours and minutes)" }
            ]
            value: root.draftFormat
            onChanged: function(v) { root.draftFormat = v }
          }

          Text {
            width: parent.width
            visible: root.formError !== ""
            text: root.formError
            wrapMode: Text.WordWrap
            color: root.bar ? root.bar.urgent : Color.urgent
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }

          Row {
            spacing: Style.space(6)

            Button {
              text: "Save"
              onClicked: root.submitForm()
            }

            Button {
              text: "Cancel"
              onClicked: root.closeForm()
            }
          }
        }

        PanelSeparator {
          width: parent.width
          visible: !root.formOpen && store.count > 0
        }

        Button {
          visible: !root.formOpen
          text: "＋ Add countdown"
          onClicked: root.openNew()
        }
      }
    }
  }
}
