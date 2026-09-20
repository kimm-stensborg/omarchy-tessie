import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// One column of the settings overlay: the sections it is given, a row per
// option. Every row comes from Model.SETTINGS, so adding an option is a line
// there and nothing here. A change is announced through `changed` the moment
// it is made — there is no Save — and the overlay writes it straight out.
//
// Choices and numbers are stepped with buttons instead of a dropdown or a
// spin box: the overlay owns the keyboard, and a control that takes focus
// away from it has to hand it back. Only the text fields do that, and they
// say so through `editing`.
Column {
  id: root

  property var sections: []
  property var values: ({})
  property var focusedField: null

  property color fg: Color.foreground
  property color muted: Qt.darker(Color.foreground, 1.5)
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  // True while a text field holds the keyboard, so the overlay can stop
  // reading Escape as "close me".
  readonly property bool editing: focusedField !== null && focusedField.activeFocus

  signal changed(string key, var value)
  signal focusReleased()

  function commit(key, value) {
    root.changed(key, value)
  }

  function dropFocus() {
    root.focusedField = null
    root.focusReleased()
  }

  spacing: Style.space(20)

  Repeater {
    model: root.sections

    Column {
      id: section
      required property var modelData
      width: root.width
      spacing: Style.space(10)

      PanelSectionHeader {
        text: String(section.modelData.title).toUpperCase()
        foreground: root.fg
        fontFamily: root.fontFamily
      }

      Repeater {
        model: section.modelData.rows

        Column {
          id: setting
          required property var modelData
          readonly property var row: modelData
          readonly property var value: Model.readSetting(root.values, row.key)
          readonly property bool overridden: !Model.isDefaultSetting(row, value)

          width: section.width
          spacing: Style.space(6)

          // Name, hint, and a dot for a row that is no longer the default —
          // the page has to be readable as "what did I change?", not only as
          // "what is it set to?".
          Item {
            width: parent.width
            height: nameText.implicitHeight

            Text {
              id: nameText
              anchors.left: parent.left
              anchors.right: overrideDot.left
              anchors.rightMargin: Style.space(6)
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: setting.row.label
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
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

          // One control per kind. The components are declared in here rather
          // than at the top of the file so they can still see `setting`.
          Loader {
            width: parent.width
            sourceComponent: setting.row.kind === "toggle" ? toggleControl
              : setting.row.kind === "choice" ? choiceControl
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

          // Segmented: every option is on screen, so picking one is a click
          // and never a popup that has to take the keyboard.
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
