import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The options for one or more settings sections. The overlay's left menu
// usually hands this a single section; section titles can be hidden when the
// menu already names the page. Every row comes from Model.SETTINGS.
//
// Short choices stay as chips. Long ones (`picker: "search"`, or more than
// five options) use SearchableDropdown so a netselskab list does not become
// a wall. Rows with `when` hide until that setting matches.
Column {
  id: root

  property var sections: []
  property var values: ({})
  property var focusedField: null
  property bool popupOpen: false
  property bool showHeaders: true

  property color fg: Color.foreground
  property color muted: Qt.darker(Color.foreground, 1.5)
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  // True while a text field or a search dropdown owns the keyboard, so the
  // overlay can stop reading Escape as "close me".
  readonly property bool editing: popupOpen
    || (focusedField !== null && focusedField.activeFocus)

  signal changed(string key, var value)
  signal focusReleased()

  function commit(key, value) {
    root.changed(key, value)
  }

  function dropFocus() {
    root.focusedField = null
    root.focusReleased()
  }

  spacing: Style.space(22)

  Repeater {
    model: root.sections

    Column {
      id: section
      required property var modelData
      width: root.width
      spacing: Style.space(14)
      // A section with every row currently hidden (e.g. Prices with the chart
      // off leaves only the toggle — still show that). Empty sections stay.
      visible: true

      PanelSectionHeader {
        visible: root.showHeaders
        height: visible ? implicitHeight : 0
        text: String(section.modelData.title).toUpperCase()
        foreground: root.fg
        fontFamily: root.fontFamily
      }

      Column {
        width: parent.width
        spacing: Style.space(14)

        Repeater {
          model: section.modelData.rows

          Column {
            id: setting
            required property var modelData
            readonly property var row: modelData
            readonly property var value: Model.readSetting(root.values, row.key)
            readonly property bool overridden: !Model.isDefaultSetting(row, value)
            readonly property bool shown: Model.settingVisible(row, root.values)

            width: section.width
            spacing: Style.space(5)
            visible: shown
            height: shown ? implicitHeight : 0
            opacity: shown ? 1 : 0
            clip: true

            // Name, optional multi count, and a dot when no longer the default.
            Item {
              width: parent.width
              height: nameText.implicitHeight

              Text {
                id: nameText
                anchors.left: parent.left
                anchors.right: countText.visible ? countText.left : overrideDot.left
                anchors.rightMargin: Style.space(6)
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: setting.row.label
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              Text {
                id: countText
                anchors.right: overrideDot.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                visible: setting.row.kind === "multi"
                textFormat: Text.PlainText
                text: Model.multiSelectionLabel(setting.row, root.values
                  ? root.values[setting.row.key] : undefined)
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Rectangle {
                id: overrideDot
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(6)
                height: width
                radius: width / 2
                color: root.accent
                opacity: setting.overridden ? 0.9 : 0
              }
            }

            Text {
              visible: !!setting.row.hint
              width: parent.width
              wrapMode: Text.Wrap
              textFormat: Text.PlainText
              text: setting.row.hint || ""
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Loader {
              width: parent.width
              active: setting.shown
              sourceComponent: setting.row.kind === "toggle" ? toggleControl
                : setting.row.kind === "choice" && Model.choiceUsesSearch(setting.row) ? searchChoiceControl
                : setting.row.kind === "choice" ? choiceControl
                : setting.row.kind === "multi" && Model.multiUsesGrid(setting.row) ? multiGridControl
                : setting.row.kind === "multi" ? multiControl
                : setting.row.kind === "number" ? numberControl
                : textControl
            }

            Component {
              id: toggleControl

              Row {
                spacing: Style.space(10)

                ToggleSwitch {
                  checked: setting.value === true
                  foreground: root.fg
                  onToggled: root.commit(setting.row.key, !setting.value)
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: setting.value === true ? "on" : "off"
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }

            // Short lists: every option on screen as a chip.
            Component {
              id: choiceControl

              Flow {
                width: setting.width
                spacing: Style.space(6)

                Repeater {
                  model: setting.row.options

                  Button {
                    required property var modelData
                    bordered: true
                    selected: modelData.value === setting.value
                    text: modelData.label
                    fontSize: Style.font.bodySmall
                    foreground: root.fg
                    fontFamily: root.fontFamily
                    onClicked: root.commit(setting.row.key, modelData.value)
                  }
                }
              }
            }

            // Long lists (netselskab): one searchable field, not fifteen chips.
            Component {
              id: searchChoiceControl

              SearchableDropdown {
                width: setting.width
                showLabel: false
                value: String(setting.value)
                options: setting.row.options
                placeholderText: "Search…"
                foreground: root.fg
                accent: root.accent
                fontFamily: root.fontFamily
                onChanged: function(v) { root.commit(setting.row.key, v) }
                onPopupOpenChanged: root.popupOpen = popupOpen
              }
            }

            Component {
              id: multiControl

              Flow {
                width: setting.width
                spacing: Style.space(6)

                Repeater {
                  model: setting.row.options

                  Button {
                    required property var modelData
                    readonly property bool on: setting.value === null
                      || Model.choiceList(setting.value).indexOf(modelData.value) !== -1
                    bordered: true
                    selected: on
                    opacity: on ? 1 : 0.55
                    text: modelData.label
                    fontSize: Style.font.bodySmall
                    foreground: root.fg
                    fontFamily: root.fontFamily
                    onClicked: root.commit(setting.row.key,
                      Model.toggleChoice(setting.row, setting.value, modelData.value))
                  }
                }
              }
            }

            // Two columns of full-width rows — easier to scan than a chip wrap.
            Component {
              id: multiGridControl

              Grid {
                id: multiGrid
                width: setting.width
                columns: 2
                columnSpacing: Style.space(8)
                rowSpacing: Style.space(6)

                Repeater {
                  model: setting.row.options

                  Button {
                    required property var modelData
                    readonly property bool on: setting.value === null
                      || Model.choiceList(setting.value).indexOf(modelData.value) !== -1
                    width: (multiGrid.width - multiGrid.columnSpacing) / 2
                    bordered: true
                    selected: on
                    leftAlign: true
                    opacity: on ? 1 : 0.55
                    text: modelData.label
                    fontSize: Style.font.bodySmall
                    horizontalPadding: Style.space(10)
                    verticalPadding: Style.space(6)
                    foreground: root.fg
                    fontFamily: root.fontFamily
                    onClicked: root.commit(setting.row.key,
                      Model.toggleChoice(setting.row, setting.value, modelData.value))
                  }
                }
              }
            }

            Component {
              id: numberControl

              Row {
                spacing: Style.space(8)

                Button {
                  bordered: true
                  text: "−"
                  enabled: setting.value > setting.row.min
                  opacity: enabled ? 1 : 0.4
                  foreground: root.fg
                  fontFamily: root.fontFamily
                  onClicked: root.commit(setting.row.key, Math.max(setting.row.min, setting.value - 1))
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(40)
                  horizontalAlignment: Text.AlignHCenter
                  textFormat: Text.PlainText
                  text: String(setting.value)
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                Button {
                  bordered: true
                  text: "+"
                  enabled: setting.value < setting.row.max
                  opacity: enabled ? 1 : 0.4
                  foreground: root.fg
                  fontFamily: root.fontFamily
                  onClicked: root.commit(setting.row.key, Math.min(setting.row.max, setting.value + 1))
                }
              }
            }

            // Written on Enter or when the field is left, not on every
            // keystroke: a half-typed VIN in shell.json would send the widget
            // looking for a car that does not exist.
            Component {
              id: textControl

              TextField {
                width: setting.width
                text: setting.value
                password: setting.row.secret === true && !activeFocus && text !== ""
                placeholderText: setting.row.placeholder || ""
                foreground: root.fg
                font.family: root.fontFamily

                onActiveFocusChanged: {
                  if (activeFocus) root.focusedField = this
                  else if (root.focusedField === this) root.focusedField = null
                }
                onAccepted: {
                  root.commit(setting.row.key, text)
                  root.dropFocus()
                }
                onEditingFinished: root.commit(setting.row.key, text)
                Keys.onEscapePressed: {
                  text = setting.value
                  root.dropFocus()
                }
              }
            }
          }
        }
      }
    }
  }
}
