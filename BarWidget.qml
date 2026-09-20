import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

// The bar button: a Tesla "T" that opens the panel. Left click toggles the
// panel, middle click refreshes, right click opens the car in a maps app.
// The panel lives in a Loader, as the built-in weather widget does, so it
// keeps polling while closed and the tooltip always has fresh numbers.
BarWidget {
  id: root
  moduleName: "io.github.kimm-stensborg.tessie"

  // Injected for third-party entry points that declare them.
  property var shell: null
  property var manifest: null

  readonly property string pluginDir: root.manifest && root.manifest.__sourceDir
    ? String(root.manifest.__sourceDir)
    : Quickshell.env("HOME") + "/.config/omarchy/plugins/io.github.kimm-stensborg.tessie"

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    target.bar = root.bar
    target.settings = root.settings
    target.anchorItem = button
    target.hostWidget = root
    target.pluginDir = root.pluginDir
  }

  // Shape contract for shell.summon/hide/toggle routing: the bar looks for
  // open/close/opened on the widget in its slot, not on the nested panel.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function refresh() { if (panelLoader.item) panelLoader.item.refresh() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  // ---- Which copy answers the keybinding.
  //
  // Every monitor's bar has its own copy of this widget, and an IPC target
  // belongs to whichever copy registered it first — so without this the panel
  // opens on whatever screen happened to come up first, not the one you are
  // looking at. Only the copy on the focused screen holds the target.
  //
  // `omarchy-shell shell toggle` cannot do this: the shell sends a plugin's
  // own id to its overlay, which is the settings. The panel is reached as an
  // IPC target instead, which is what this owns.
  readonly property string screenName: {
    var window = root.QsWindow ? root.QsWindow.window : null
    var screen = window && window.screen ? window.screen : null
    if (!screen) return ""
    if (typeof Hyprland.monitorFor === "function") {
      var hypr = Hyprland.monitorFor(screen)
      if (hypr && hypr.name) return String(hypr.name)
    }
    return String(screen.name || "")
  }
  readonly property bool focusedHere: root.screenName !== "" && !!Hyprland.focusedMonitor
    && root.screenName === String(Hyprland.focusedMonitor.name || "")
  property bool ipcOwner: false

  onFocusedHereChanged: {
    if (!root.focusedHere) root.ipcOwner = false
    else ipcClaim.restart()
  }

  // The claim waits a beat, so the copy giving the target up has let go first.
  Timer {
    id: ipcClaim
    interval: 150
    repeat: false
    onTriggered: root.ipcOwner = root.focusedHere
  }

  Component.onCompleted: if (root.focusedHere) ipcClaim.restart()

  IpcHandler {
    enabled: root.ipcOwner
    target: root.moduleName

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    // Every copy refreshes: one bar's panel going stale would leave the
    // tooltip on that screen showing an older car than the one next to it.
    function refresh(): void { root.broadcast("refresh") }
  }

  // What rides next to the T, from the "Next to the T" setting. A vertical
  // bar has no room for it, so there it stays off whatever the setting says.
  readonly property string labelText: panelLoader.item && !root.vertical
    ? String(panelLoader.item.barLabelText || "") : ""

  function press(b) {
    if (!panelLoader.item) return
    if (b === Qt.MiddleButton) panelLoader.item.refresh()
    else if (b === Qt.RightButton) panelLoader.item.openMaps()
    else root.toggle()
  }

  implicitWidth: row.implicitWidth
  implicitHeight: row.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()
  onPluginDirChanged: injectPanel()

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

  // The mark and its label are two items rather than one button: the kit's
  // bar button paints either a glyph or a label, and the T is neither — it is
  // a canvas. The label carries the same clicks so the pair behaves as one.
  //
  // The spacing is what makes the pair sit in the bar's rhythm. A status slot
  // is 21 wide around a 16 icon canvas, so the T's own slot leaves only about
  // 2px before the label — too tight to read as a pair — and the bar's gap
  // between neighbours is around 15. So the label takes a leading gap of its
  // own and carries a trailing margin the size the kit gives every other
  // widget, which puts the next icon back on the same spacing as the rest.
  readonly property int labelGap: Style.space(5)
  readonly property real labelMargin: Style.spaceReal(8.5)

  Row {
    id: row
    spacing: 0

    BarIconButton {
      id: button
      bar: root.bar
      slotSize: Style.bar.statusSlot
      tooltipText: root.opened || !panelLoader.item ? "" : panelLoader.item.summary
      iconComponent: teslaLogo

      onPressed: function(b) { root.press(b) }
    }

    Item {
      visible: root.labelText !== ""
      width: visible ? root.labelGap + label.implicitWidth + root.labelMargin : 0
      height: button.implicitHeight

      Text {
        id: label
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        anchors.leftMargin: root.labelGap
        textFormat: Text.PlainText
        text: root.labelText
        color: button.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        renderType: Text.NativeRendering
      }

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
        hoverEnabled: true
        onEntered: if (root.bar && !root.opened && panelLoader.item)
          root.bar.showTooltip(button, panelLoader.item.summary)
        onExited: if (root.bar) root.bar.hideTooltip(button)
        onPressed: function(mouse) { root.press(mouse.button) }
      }
    }
  }

  // No icon font carries the Tesla mark, so it is drawn: the arched cap and
  // the tapering stem, on a 24-unit grid scaled to the icon canvas.
  Component {
    id: teslaLogo

    Canvas {
      id: logo
      property color ink: button.foreground
      onInkChanged: requestPaint()
      onWidthChanged: requestPaint()
      onHeightChanged: requestPaint()

      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        var s = Math.min(width, height) / 24
        ctx.translate((width - 24 * s) / 2, (height - 24 * s) / 2)
        ctx.scale(s, s)
        ctx.fillStyle = logo.ink

        ctx.beginPath()
        ctx.moveTo(1.5, 5.2)
        ctx.quadraticCurveTo(12, 0.6, 22.5, 5.2)
        ctx.lineTo(21.6, 7.3)
        ctx.quadraticCurveTo(12, 3.6, 2.4, 7.3)
        ctx.closePath()
        ctx.fill()

        ctx.beginPath()
        ctx.moveTo(8.4, 6.4)
        ctx.quadraticCurveTo(12, 5.3, 15.6, 6.4)
        ctx.lineTo(13.3, 8.6)
        ctx.lineTo(12, 23)
        ctx.lineTo(10.7, 8.6)
        ctx.closePath()
        ctx.fill()
      }
    }
  }
}
