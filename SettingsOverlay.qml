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
// buttons and wrong for a page of options. So the gear summons this instead:
// a card with a left menu (Car, Prices, Panel, Advanced) and one section at
// a time on the right. Long lists (netselskab) stay a searchable dropdown.
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
  property int sectionIndex: 0
  // Survives close so reopening lands on the page you left.
  property int lastSectionIndex: 0

  // This widget's entry, as shell.json currently has it. A write sets it here
  // first so the control redraws on the click itself, and the file watcher
  // confirms it a moment later with whatever was actually stored.
  property var settings: ({ id: root.pluginId })
  readonly property bool customised: Model.hasCustomSettings(root.settings)
  readonly property var sections: Model.SETTINGS
  readonly property var currentSection: sections[Math.max(0, Math.min(sectionIndex, sections.length - 1))] || null

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

  readonly property int navWidth: Style.space(220)
  readonly property int pageWidth: Style.space(420)
  readonly property int navGap: Style.space(28)
  readonly property int cardWidth: Math.min(
    root.navWidth + root.navGap + root.pageWidth + root.contentMargin * 2,
    panel.width - Style.gapsOut * 2)
  readonly property int ruleGap: Style.space(14)
  readonly property int bodyGap: Style.space(16)
  // Fixed height so switching pages does not resize the card.
  readonly property int cardHeight: Math.min(Style.space(720), panel.height - Style.gapsOut * 2)

  // A text field or search dropdown owns the keyboard while it has it.
  property bool editing: false

  function open(payloadJson) {
    root.opened = true
    root.sectionIndex = Math.max(0, Math.min(root.lastSectionIndex, root.sections.length - 1))
    root.editing = false
    configFile.reload()
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.lastSectionIndex = root.sectionIndex
    root.opened = false
  }

  function toggle() { root.opened ? root.close() : root.open("{}") }

  function goSection(delta) {
    if (root.editing || root.sections.length === 0) return
    var next = root.sectionIndex + delta
    if (next < 0 || next >= root.sections.length) return
    root.sectionIndex = next
  }

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
          } else if (event.key === Qt.Key_Up || event.key === Qt.Key_K) {
            root.goSection(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Down || event.key === Qt.Key_J) {
            root.goSection(1)
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
              text: "Tessie settings"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
            }

            Text {
              width: parent.width
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: root.customised
                ? "Changed from the defaults · saved as you go"
                : "All at their defaults · saved as you go"
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

        // ---- Left menu + one section.
        Item {
          id: body
          anchors.top: headerRule.bottom
          anchors.topMargin: root.bodyGap
          anchors.bottom: footerRule.top
          anchors.bottomMargin: root.ruleGap
          anchors.left: parent.left
          anchors.right: parent.right

          Column {
            id: nav
            width: root.navWidth
            anchors.left: parent.left
            anchors.top: parent.top
            spacing: Style.space(4)

            Repeater {
              model: root.sections

              Button {
                required property var modelData
                required property int index
                width: nav.width
                leftAlign: true
                bordered: false
                selected: index === root.sectionIndex
                text: modelData.title
                fontSize: Style.font.body
                foreground: root.foreground
                fontFamily: root.fontFamily
                horizontalPadding: Style.space(16)
                verticalPadding: Style.space(14)
                onClicked: root.sectionIndex = index

                Rectangle {
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(14)
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(7)
                  height: width
                  radius: width / 2
                  color: root.accent
                  opacity: Model.sectionHasCustom(modelData, root.settings) ? 0.9 : 0
                }
              }
            }
          }

          Rectangle {
            id: navRule
            width: Math.max(1, Style.space(1))
            anchors.left: nav.right
            anchors.leftMargin: root.navGap / 2 - width / 2
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            color: Util.alpha(root.foreground, 0.12)
          }

          Item {
            id: page
            anchors.left: nav.right
            anchors.leftMargin: root.navGap
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom

            Column {
              id: pageHeader
              anchors.top: parent.top
              anchors.left: parent.left
              anchors.right: parent.right
              spacing: Style.space(4)

              Text {
                id: pageTitle
                width: parent.width
                textFormat: Text.PlainText
                text: root.currentSection ? root.currentSection.title : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }

              Text {
                id: pageBlurb
                visible: !!(root.currentSection && root.currentSection.blurb)
                width: parent.width
                wrapMode: Text.Wrap
                textFormat: Text.PlainText
                text: root.currentSection && root.currentSection.blurb
                  ? root.currentSection.blurb : ""
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Flickable {
              id: pageScroll
              anchors.top: pageHeader.bottom
              anchors.topMargin: Style.space(14)
              anchors.bottom: parent.bottom
              anchors.left: parent.left
              anchors.right: parent.right
              contentWidth: width
              contentHeight: pageColumn.implicitHeight
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              interactive: contentHeight > height

              SettingsColumn {
                id: pageColumn
                width: pageScroll.width
                sections: root.currentSection ? [root.currentSection] : []
                values: root.settings
                showHeaders: false
                fg: root.foreground
                muted: root.muted
                accent: root.accent
                fontFamily: root.fontFamily

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
            text: "↑↓ switch page · Esc closes · a dot marks a change"
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
