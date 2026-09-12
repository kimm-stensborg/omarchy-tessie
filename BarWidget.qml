import QtQuick
import Quickshell
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
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

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

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    slotSize: Style.bar.statusSlot
    tooltipText: root.opened || !panelLoader.item ? "" : panelLoader.item.summary
    iconComponent: teslaLogo

    onPressed: function(b) {
      if (!panelLoader.item) return
      if (b === Qt.MiddleButton) panelLoader.item.refresh()
      else if (b === Qt.RightButton) panelLoader.item.openMaps()
      else root.toggle()
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
