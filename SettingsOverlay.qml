import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Tessie's settings, in a window of their own.
//
// The panel is a bar popup and stays narrow, which is right for a map and six
// buttons and wrong for fourteen options. So the gear summons this instead: a
// card wide enough to lay every option out at once, in columns Model levels
// so none of them runs long. Nothing here is behind a tab or a scroll.
//
// It writes each change through updateEntryInline, the same path
// `omarchy bar set` takes. There is no Save: a change is live in the bar
// before the click finishes, and the panel behind redraws with it.
//
// It reads shell.json itself rather than the bar config the shell hands a
// plugin: that one is a snapshot taken when the plugin's API was built and is
// only refreshed when the plugin registry changes, so a page drawn from it
// would still be showing the settings as they were at the last shell start.
// The file is watched, so `omarchy bar set` in a terminal moves the controls
// here while the card is open.
Item {
  id: root

  // Injected by omarchy-shell when this plugin is summoned.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  readonly property string pluginId: "io.github.kimm-stensborg.tessie"
  readonly property string configPath: Quickshell.env("HOME") + "/.config/omarchy/shell.json"

  property bool opened: false

  // This widget's entry, as shell.json currently has it. A write sets it here
  // first so the control redraws on the click itself, and the file watcher
  // confirms it a moment later with whatever was actually stored.
  property var settings: ({ id: root.pluginId })
  readonly property bool customised: Model.hasCustomSettings(root.settings)

  function takeConfig(text) {
    var parsed = null
    try { parsed = JSON.parse(String(text || "")) } catch (e) {}
    // An unreadable config is not worth wiping the page over: keep what is on
    // screen rather than redrawing every option as a default it may not have.
    if (parsed) root.settings = Model.entryFor(parsed.bar, root.pluginId)
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    // text() is stale inside the change signal, so both paths go through
    // reload → onLoaded and parse fresh content.
    onFileChanged: reload()
    onLoaded: root.takeConfig(text())
  }

  // Theme: the menu surface, as the other full-screen plugin overlays use.
  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color muted: Qt.darker(foreground, 1.5)
  readonly property color borderColor: Color.menu.border
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", borderColor, Math.max(1, Style.space(2)))
  readonly property color scrim: Color.menu.scrim
  readonly property color accent: Color.accent
  readonly property int cornerRadius: Style.cornerRadius
  readonly property string fontFamily: Style.font.menuFamily
  readonly property int contentMargin: Style.spacing.panelPadding

  // Three columns at a desktop width, two when the card is squeezed, one on
  // something small. The card follows the content rather than the other way
  // round, so a narrow screen gets a narrow card and not a cramped one.
  readonly property int columnCount: panel.width >= Style.space(1120) ? 3
    : panel.width >= Style.space(780) ? 2 : 1
  readonly property int columnWidth: Style.space(300)
  readonly property var columns: Model.settingsColumns(root.columnCount)

  readonly property int columnGap: Style.space(28)
  readonly property int cardWidth: Math.min(
    root.columnWidth * root.columnCount + root.columnGap * (root.columnCount - 1) + root.contentMargin * 2,
    panel.width - Style.gapsOut * 2)

  // The gaps around the two rules, named because the card's height is the
  // options plus exactly this much and nothing else: get it wrong and the
  // last row of the tallest column is quietly clipped.
  readonly property int ruleGap: Style.space(14)
  readonly property int bodyGap: Style.space(16)
  readonly property int chromeHeight: root.contentMargin * 2
    + header.height + footer.height
    + headerRule.height + footerRule.height
    + root.ruleGap * 3 + root.bodyGap

  // The card is as tall as the options need, and no taller, until the screen
  // runs out — then the columns scroll.
  readonly property int cardHeight: Math.min(root.chromeHeight + columnsRow.implicitHeight,
    panel.height - Style.gapsOut * 2)

  // A text field in any column owns the keyboard while it has it.
  property bool editing: false

  function open(payloadJson) {
    root.opened = true
    configFile.reload()
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function toggle() { root.opened ? root.close() : root.open("{}") }

  // One option, written to this widget's entry in shell.json. Model.nextEntry
  // carries every other key across — updateEntryInline replaces the entry
  // rather than merging into it — and drops a value that is back at its
  // default instead of writing it out.
  function persist(key, value) {
    var entry = Model.nextEntry(root.settings, root.pluginId, key === null ? null : ({ [key]: value }))
    root.settings = entry
    if (root.shell && typeof root.shell.updateEntryInline === "function")
      root.shell.updateEntryInline(root.pluginId, entry)
  }

  function resetAll() {
    root.persist(null, null)
  }

  IpcHandler {
    target: root.pluginId + ".settings"

    function open(): void { root.open("{}") }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-tessie-settings"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec

      // Swallows the click so the scrim behind does not take it as "dismiss".
      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        anchors.margins: root.contentMargin
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          // A focused field answers for itself; Escape there clears the field
          // rather than the window.
          if (root.editing) return
          if (event.key === Qt.Key_Escape) {
            root.close()
            event.accepted = true
          }
        }

        // ---- Header: what this is, and the way back to the defaults.
        Item {
          id: header
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          height: Math.max(titleColumn.implicitHeight, resetButton.implicitHeight)

          Column {
            id: titleColumn
            anchors.left: parent.left
            anchors.right: resetButton.left
            anchors.rightMargin: Style.space(16)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(3)

            Text {
              textFormat: Text.PlainText
              text: "Tessie"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
            }

            Text {
              width: parent.width
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: root.customised
                ? "Changed from the defaults · saved as you go, in ~/.config/omarchy/shell.json"
                : "Every option is at its default · saved as you go, in ~/.config/omarchy/shell.json"
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Button {
            id: resetButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            bordered: true
            enabled: root.customised
            opacity: enabled ? 1 : 0.45
            iconText: ""
            text: "Reset"
            tooltipText: "Put every option back to its default"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.resetAll()
          }
        }

        PanelSeparator {
          id: headerRule
          anchors.top: header.bottom
          anchors.topMargin: root.ruleGap
          anchors.left: parent.left
          anchors.right: parent.right
          foreground: root.foreground
        }

        // ---- The options. Every one of them, at once.
        Flickable {
          id: body
          anchors.top: headerRule.bottom
          anchors.topMargin: root.bodyGap
          anchors.bottom: footerRule.top
          anchors.bottomMargin: root.ruleGap
          anchors.left: parent.left
          anchors.right: parent.right
          contentWidth: width
          contentHeight: columnsRow.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          Row {
            id: columnsRow
            width: body.width
            spacing: root.columnGap

            Repeater {
              model: root.columns

              SettingsColumn {
                required property var modelData
                width: (columnsRow.width - root.columnGap * (root.columnCount - 1)) / root.columnCount
                sections: modelData
                values: root.settings
                fg: root.foreground
                muted: root.muted
                accent: root.accent
                fontFamily: root.fontFamily

                // One field at a time across the whole card: a column only
                // knows about its own, so the card tracks whether any of them
                // has the keyboard.
                onEditingChanged: root.editing = editing
                onChanged: function(key, value) { root.persist(key, value) }
                onFocusReleased: {
                  root.editing = false
                  keyCatcher.forceActiveFocus()
                }
              }
            }
          }
        }

        PanelSeparator {
          id: footerRule
          anchors.bottom: footer.top
          anchors.bottomMargin: root.ruleGap
          anchors.left: parent.left
          anchors.right: parent.right
          foreground: root.foreground
        }

        // ---- Footer: what the keys do, and the way out.
        Item {
          id: footer
          anchors.bottom: parent.bottom
          anchors.left: parent.left
          anchors.right: parent.right
          height: doneButton.implicitHeight

          Text {
            anchors.left: parent.left
            anchors.right: doneButton.left
            anchors.rightMargin: Style.space(16)
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: "Esc closes · a dot marks an option that is no longer the default"
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Button {
            id: doneButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            bordered: true
            text: "Done"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.close()
          }
        }
      }
    }
  }
}
