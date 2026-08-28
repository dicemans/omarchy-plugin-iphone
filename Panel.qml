import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Your iPhone on the bar: presence and battery at a glance, guided pairing,
// and the camera roll one click away in the file manager.
//
// All device work goes through bin/iphone-ctl. Keeping the shell out of
// libimobiledevice's output formats means a broken assumption is fixed in a
// script you can run in a terminal, not in a QML file that only misbehaves
// once the bar is up.
Panel {
  id: root
  moduleName: "io.github.dicemans.iphone"
  ipcTarget: "io.github.dicemans.iphone"
  manageIpc: false

  // ---------------------------------------------------------------- settings
  // Deliberately slow: every status poll briefly wakes the phone.
  readonly property int refreshIntervalSec: Math.max(5, Number(setting("refreshIntervalSec", 15)))
  readonly property bool showBattery: setting("showBattery", true) === true
  readonly property string preferredUdid: String(setting("preferredUdid", ""))
  readonly property string importFolder: String(setting("importFolder", "~/Pictures/iPhone"))


  // ------------------------------------------------------------------- state
  property var rows: []
  property string listError: ""
  property var brokenDeps: []
  property string actionError: ""

  property string busyUdid: ""
  property string busyAction: ""
  property bool fixBusy: false
  // Import can copy gigabytes and gets its own slot: ejecting another
  // device must not queue behind it.
  property string importUdid: ""
  property string actionNotice: ""

  property int selectedIndex: 0
  property int actionIndex: -1
  property bool cursorActive: false

  // The helper ships inside the plugin, so its path is derived from this
  // file's own location rather than assumed to be on PATH.
  readonly property string helperPath: {
    var url = String(Qt.resolvedUrl("bin/iphone-ctl"))
    return url.indexOf("file://") === 0 ? url.substring(7) : url
  }

  readonly property int attentionCount: Model.attentionCount(root.rows)
  readonly property int barBattery: Model.barBattery(root.rows)
  readonly property bool depsBroken: root.brokenDeps.length > 0
  readonly property bool barUrgent: root.attentionCount > 0
  readonly property bool battInBar: root.showBattery && root.barBattery >= 0
  readonly property bool lifecycleBusy: root.busyUdid !== ""

  readonly property string stateMessage: {
    if (root.listError !== "") return Model.errorText(root.listError)
    if (root.rows.length === 0) return "Plug in your iPhone with a USB cable"
    return ""
  }

  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "transparent"

  readonly property real openPanelIndicatorWidth: root.battInBar && !button.vertical ? button.glyphPaintedWidth : 0

  // --------------------------------------------------------------- behaviour
  function rowAt(index) {
    return index >= 0 && index < rows.length ? rows[index] : null
  }

  function actionsAt(index) {
    return Model.rowActions(rowAt(index))
  }

  function rowBusyAction(row) {
    if (!row) return ""
    if (root.busyUdid === row.udid) return root.busyAction
    if (root.importUdid === row.udid) return "import"
    return ""
  }

  function refresh() {
    if (!depsProc.running) depsProc.running = true
    if (!listProc.running) listProc.running = true
  }

  function applyStatus(raw) {
    rows = Model.parseStatus(raw)
    selectedIndex = Model.clampIndex(selectedIndex, rows.length)
    var actions = actionsAt(selectedIndex)
    if (actionIndex >= actions.length) actionIndex = actions.length - 1
  }

  function moveCursor(dx, dy) {
    if (!cursorActive) { cursorActive = true; return }
    if (dy !== 0) {
      selectedIndex = Model.clampIndex(selectedIndex + dy, rows.length)
      actionIndex = -1
      return
    }
    if (dx !== 0) {
      var count = actionsAt(selectedIndex).length
      actionIndex = Math.max(-1, Math.min(count - 1, actionIndex + dx))
    }
  }

  function activateCursor() {
    // With the deps broken the list is empty and there is exactly one thing
    // Enter can mean, so it works before the cursor is revealed.
    if (depsBroken) { fixDeps(); return }
    if (!cursorActive) { cursorActive = true; return }
    var row = rowAt(selectedIndex)
    if (!row) return
    var actions = actionsAt(selectedIndex)
    if (actionIndex >= 0 && actionIndex < actions.length) activate(row, actions[actionIndex].id)
    else if (actions.length > 0) activate(row, actions[0].id)
  }

  function activate(row, action) {
    if (!row || !action) return "no action"
    // "Check again" is just a refresh wearing the row's clothes: the state
    // it waits on lives on the phone, not here.
    if (action === "retry") { refresh(); return "ok" }
    if (action === "import") return runImport(row.udid)
    return run(row.udid, action)
  }

  function run(udid, action) {
    if (!udid || !action) return "no action"
    if (actionProc.running) return "busy"
    actionError = ""
    busyUdid = udid
    busyAction = action
    actionProc.command = [root.helperPath, action, udid]
    actionProc.running = true
    return "ok"

  }

  function runImport(udid) {
    if (!udid) return "no action"
    if (importProc.running) return "busy"
    actionError = ""
    actionNotice = ""
    importUdid = udid
    importProc.command = [root.helperPath, "import", udid, root.importFolder]
    importProc.running = true
    return "ok"
  }

  // The setup repair goes through polkit, so the click may be answered by a
  // password dialog rather than a result. Its own busy slot: it must not
  // block, or be blocked by, device actions.
  function fixDeps() {
    if (fixProc.running) return "busy"
    actionError = ""
    fixBusy = true
    fixProc.command = [root.helperPath, "fix-deps"]
    fixProc.running = true
    return "ok"
  }

  function focusRow(index, action) {
    cursorActive = true
    selectedIndex = index
    actionIndex = action
  }

  IpcHandler {
    target: "io.github.dicemans.iphone"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }

    // Opens the camera roll of the first paired device — bindable to a key.
    function openPhotos(): string {
      for (var i = 0; i < root.rows.length; i++)
        if (root.rows[i].paired)
          return root.run(root.rows[i].udid, "photos")
      return "no paired device"
    }
  }

  // ---------------------------------------------------------------- processes
  Process {
    id: listProc
    command: [root.helperPath, "status", root.preferredUdid]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyStatus(text) }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: root.listError = Model.clipDiag(text) }
  }

  Process {
    id: depsProc
    command: [root.helperPath, "deps"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.brokenDeps = Model.parseDeps(text) }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: {} }
  }

  Process {
    id: actionProc
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: root.actionError = Model.clipDiag(text) }
    onExited: {
      root.busyUdid = ""
      root.busyAction = ""
      root.refresh()
    }
  }

  Process {
    id: importProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.actionNotice = Model.importNotice(Model.parseImport(text))
    }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: root.actionError = Model.clipDiag(text) }
    onExited: {
      root.importUdid = ""
      root.refresh()
    }
  }

  Process {
    id: fixProc
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: root.actionError = Model.clipDiag(text) }
    onExited: {
      root.fixBusy = false
      root.refresh()
    }
  }

  // One timer for both states: fresh rows every few seconds while the panel
  // is open, a slow heartbeat while it is closed — polling wakes the phone.
  Timer {
    interval: (root.opened ? root.refreshIntervalSec : Math.max(root.refreshIntervalSec, 60)) * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: 8000
    running: root.actionError !== ""
    repeat: false
    onTriggered: root.actionError = ""
  }

  Timer {
    interval: 10000
    running: root.actionNotice !== ""
    repeat: false
    onTriggered: root.actionNotice = ""
  }

  onOpenedChanged: {
    if (!opened) return
    refresh()
    cursorActive = false
    selectedIndex = Model.clampIndex(selectedIndex, rows.length)
    actionIndex = -1
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.battInBar && !vertical
      ? root.barBattery + "% " + Model.GLYPH.phone
      : Model.GLYPH.phone
    slotSize: Style.bar.iconSlot * (root.battInBar && !vertical ? 2 : 1)
    // WidgetButton paints `active` in the bar's URGENT colour by default —
    // a battery percentage in red reads as "battery low", which it is not.
    // Red is reserved for a pairing conversation waiting on the phone;
    // ordinary presence wears the ordinary foreground.
    active: root.barUrgent
    tooltipText: root.listError !== ""
      ? Model.errorText(root.listError)
      : (root.attentionCount > 0
        ? Model.summary(root.rows) + " · waiting on the phone"
        : Model.summary(root.rows))
    onPressed: function (mouseButton) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function (dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTextKey: function (key) {
        if (key === "r") { root.refresh(); return }
        var row = root.rowAt(root.selectedIndex)
        if (!row || !root.cursorActive) return
        if (key === "p" && row.paired) root.activate(row, "photos")
      }
      onTabRequested: function (direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        // ---------- Hero: phone · title/summary ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

          Text {
            id: heroIcon
            text: Model.GLYPH.phone
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "iPhone"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              text: (root.listError !== "" ? Model.errorText(root.listError) : Model.summary(root.rows)).toUpperCase()
              color: root.listError !== "" ? root.bar.urgent : Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }
        }

        PanelSeparator { foreground: root.bar.foreground }

        // ---------- Setup: offer the fix, not just the diagnosis ----------
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.depsBroken

          Text {
            width: parent.width
            text: Model.depsText(root.brokenDeps)
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          BorderSurface {
            id: fixButton
            readonly property color tone: root.fixBusy ? Util.alpha(root.bar.foreground, 0.38) : Color.accent

            width: Math.min(parent.width, Style.space(240))
            height: Style.space(38)
            anchors.horizontalCenter: parent.horizontalCenter
            radius: Style.cornerRadius
            color: fixMouse.containsMouse && !root.fixBusy ? Util.alpha(Color.accent, 0.12) : "transparent"
            borderSpec: Border.flat(fixButton.tone, Style.normalBorderWidth)

            Row {
              anchors.centerIn: parent
              spacing: Style.space(8)

              Text {
                text: Model.GLYPH.fix
                color: fixButton.tone
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.heading
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                text: root.fixBusy ? "Setting up…" : "Set up iPhone support"
                color: root.fixBusy ? Qt.darker(root.bar.foreground, 1.4) : root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            MouseArea {
              id: fixMouse
              anchors.fill: parent
              hoverEnabled: true
              enabled: !root.fixBusy
              cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
              onClicked: root.fixDeps()
            }

            // Installing packages is a real system change: the tooltip says
            // exactly what the click will do with root before it is clicked.
            PanelToolTip {
              visible: fixMouse.containsMouse
              text: root.fixBusy
                ? "Installing and activating"
                : Model.depsText(root.brokenDeps)
                  + " Installs from the official repos and restarts usbmuxd (asks for authorization)  ·  key: Enter"
              fontFamily: root.bar.fontFamily
            }
          }
        }

        // ---------- Empty / error state ----------
        Text {
          visible: !root.depsBroken && root.stateMessage !== ""
          width: parent.width
          text: root.stateMessage
          color: root.listError !== "" ? root.bar.urgent : Qt.darker(root.bar.foreground, 1.5)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.body
          wrapMode: Text.WordWrap
        }

        // ---------- Device rows ----------
        Repeater {
          model: root.rows

          DeviceRow {
            required property var modelData
            required property int index
            width: column.width
            row: modelData
            rowIndex: index
          }
        }

        // ---------- Last action failure ----------
        Text {
          visible: root.actionError !== ""
          width: parent.width
          text: Model.errorText(root.actionError)
          color: root.bar.urgent
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        // ---------- Good news (import result) ----------
        Text {
          visible: root.actionNotice !== ""
          width: parent.width
          text: root.actionNotice
          color: Color.accent
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }

  // One device. Visuals come from CursorSurface state, never containsMouse,
  // so the keyboard cursor and the mouse can never paint two highlights.
  component DeviceRow: CursorSurface {
    id: rowItem

    required property var row
    required property int rowIndex

    readonly property var actions: Model.rowActions(rowItem.row)
    readonly property string busy: root.rowBusyAction(rowItem.row)
    readonly property bool rowSelected: root.cursorActive && root.selectedIndex === rowItem.rowIndex
    readonly property bool attention: rowItem.row
      && (rowItem.row.state === "trust-pending" || rowItem.row.state === "denied" || rowItem.row.state === "locked")

    hasCursor: rowSelected && root.actionIndex < 0
    current: rowItem.row && rowItem.row.paired
    foreground: root.bar.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill

    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      onContainsMouseChanged: if (containsMouse) root.focusRow(rowItem.rowIndex, -1)
    }

    Item {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      implicitHeight: Math.max(rowIcon.implicitHeight, rowInfo.implicitHeight, rowActions.implicitHeight)

      Text {
        id: rowIcon
        text: Model.GLYPH.phone
        color: rowItem.attention
          ? root.bar.urgent
          : (rowItem.row && rowItem.row.paired
            ? root.bar.foreground
            : Qt.darker(root.bar.foreground, 1.6))
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.heading
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      Column {
        id: rowInfo
        spacing: Style.space(1)
        anchors.left: rowIcon.right
        anchors.leftMargin: Style.space(10)
        anchors.right: rowActions.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter

        Text {
          text: rowItem.row ? rowItem.row.name : ""
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
          width: parent.width
        }

        Text {
          text: rowItem.busy !== "" ? Model.busyLabel(rowItem.busy) : Model.stateText(rowItem.row)
          color: rowItem.busy !== ""
            ? root.bar.foreground
            : (rowItem.attention ? root.bar.urgent : Qt.darker(root.bar.foreground, 1.5))
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          width: parent.width
        }
      }

      Row {
        id: rowActions
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Repeater {
          model: rowItem.actions

          PanelActionButton {
            required property var modelData
            required property int index

            iconText: modelData.icon
            tooltipText: modelData.tooltip
            foreground: root.bar.foreground
            hoverColor: modelData.urgent ? root.bar.urgent : root.bar.foreground
            fontFamily: root.bar.fontFamily
            enabled: !root.lifecycleBusy
            hasCursor: rowItem.rowSelected && root.actionIndex === index
            onHovered: function (isHovered) {
              if (isHovered) root.focusRow(rowItem.rowIndex, index)
              else if (rowMouse.containsMouse) root.focusRow(rowItem.rowIndex, -1)
            }
            onClicked: root.activate(rowItem.row, modelData.id)
          }
        }
      }
    }
  }
}
