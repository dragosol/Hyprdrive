import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.hyprdrive
pragma ComponentBehavior: Bound

/**
 * Monitors. The only pane whose rows are not in the schema, because its rows are
 * the outputs `hyprctl monitors -j` reports right now -- the schema carries the
 * FIELDS (monitor_fields) and the compositor carries the objects.
 *
 * And the only pane where applying is not the last step. A wrong mode can take
 * away the screen you would use to undo it, so every change here goes on a
 * fifteen-second leash: the previous fragment is fsynced to disk BEFORE the new
 * one is written, and it is put back unless somebody says keep. The countdown
 * banner below is the visible half; the half that matters is that killing this
 * window does not cancel it (scripts/hdmon.py).
 */
ContentPage {
    id: root
    baseWidth: 760
    forceWidth: true

    Component.onCompleted: Hd.refreshMonitors()

    // ---------------------------------------------------------- the leash --
    Rectangle {
        Layout.fillWidth: true
        visible: Hd.pendingSeconds >= 0
        implicitHeight: 64
        radius: Appearance.rounding.normal
        color: Appearance.colors.colSecondaryContainer

        RowLayout {
            anchors.fill: parent
            anchors.margins: 12
            spacing: 12
            MaterialSymbol { text: "timer"; iconSize: 24 }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0
                StyledText {
                    text: "Keep these settings?"
                    font.weight: Font.Medium
                    color: Appearance.colors.colOnSecondaryContainer
                }
                StyledText {
                    text: `Reverting in ${Math.max(0, Math.ceil(Hd.pendingSeconds))}s. `
                          + "This happens even if the app is gone."
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.m3colors.m3outline
                }
            }
            RippleButton {
                implicitHeight: 34
                onClicked: Hd.monitorRevert()
                contentItem: StyledText { text: "Revert now"; anchors.centerIn: parent }
            }
            RippleButton {
                implicitHeight: 34
                colBackground: Appearance.colors.colPrimary
                onClicked: Hd.monitorConfirm()
                contentItem: StyledText {
                    text: "Keep"; anchors.centerIn: parent; color: Appearance.m3colors.m3onPrimary
                }
            }
        }
    }

    Repeater {
        model: Hd.monitors
        ContentSection {
            id: mon
            required property var modelData
            title: `${modelData.name} -- ${modelData.description}`
            icon: "monitor"

            property string wantMode: modelData.mode
            property real wantScale: modelData.scale
            property string wantPosition: modelData.position

            ConfigRow {
                StyledText {
                    Layout.preferredWidth: 120
                    text: "Mode"
                    color: Appearance.colors.colOnSecondaryContainer
                }
                ComboBox {
                    Layout.fillWidth: true
                    model: [mon.modelData.mode].concat(
                        (mon.modelData.availableModes ?? []).filter(m => m !== mon.modelData.mode))
                    onActivated: mon.wantMode = currentValue
                }
            }

            ConfigSlider {
                text: "Scale"
                from: 0.5
                to: 3.0
                value: mon.modelData.scale
                usePercentTooltip: false
                onValueChanged: mon.wantScale = value
            }

            ConfigRow {
                StyledText {
                    Layout.preferredWidth: 120
                    text: "Position"
                    color: Appearance.colors.colOnSecondaryContainer
                }
                MaterialTextField {
                    Layout.fillWidth: true
                    text: mon.modelData.position
                    onTextChanged: mon.wantPosition = text
                }
            }

            StyledText {
                Layout.fillWidth: true
                text: "Hyprland refuses a scale that does not divide the mode into whole pixels, and "
                      + "says which one it would have taken. If the screen goes dark, wait: the "
                      + "countdown is on disk, not in this window."
                wrapMode: Text.WordWrap
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: Appearance.m3colors.m3outline
            }

            RowLayout {
                Layout.fillWidth: true
                Item { Layout.fillWidth: true }
                RippleButton {
                    enabled: Hd.pendingSeconds < 0
                    implicitHeight: 34
                    colBackground: Appearance.colors.colPrimary
                    onClicked: Hd.monitorApply(mon.modelData.name, {
                        "mode": mon.wantMode,
                        "scale": mon.wantScale.toFixed(2),
                        "position": mon.wantPosition
                    })
                    contentItem: StyledText {
                        text: "Apply for 15 seconds"
                        anchors.centerIn: parent
                        color: Appearance.m3colors.m3onPrimary
                    }
                }
            }
        }
    }

    ContentSection {
        title: ""
        RawEditor {
            pane: "monitors"
            fragment: "45-monitors.lua"
            fanout: "every output; hl.monitor lines here are applied at parse time like any other"
        }
    }
}
