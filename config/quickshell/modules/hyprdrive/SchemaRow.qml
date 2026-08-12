import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.hyprdrive
pragma ComponentBehavior: Bound

/**
 * One schema entry, drawn. This is the whole reason the schema is data: there is
 * exactly one of these, and which widget it becomes is a string in json.
 *
 * Three states a row can be in, and the app has to be honest about all three:
 *
 *   OWNED      this pane's fragment carries the key. The value is durable and,
 *              for a theme-derived key, it is a PIN -- the fragment sorts after
 *              05-theme-derived.lua, so it wins by load order (Phase 10).
 *   INHERITED  a derived key nobody has pinned. It follows the wallpaper. The
 *              pin toggle is what moves a row from here to OWNED, and unsetting
 *              is what moves it back -- there is no third mechanism.
 *   LOCKED     the schema says this one is not a casual control. The row shows
 *              the value and the reason and refuses to write; the raw-snippet
 *              editor at the bottom of the pane is the deliberate way past it.
 */
ColumnLayout {
    id: root
    required property var entry
    Layout.fillWidth: true
    spacing: 2

    readonly property bool owned: entry.owned === true
    readonly property bool derived: entry.derived === true
    readonly property bool locked: entry.locked !== undefined
    readonly property var live: entry.current !== undefined && entry.current !== null
                                ? entry.current : entry.default

    function commit(v) {
        if (root.locked) return;
        Hd.commit(root.entry.key, v);
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 8

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 0
            StyledText {
                Layout.fillWidth: true
                text: root.entry.key
                font.pixelSize: Appearance.font.pixelSize.small
                font.family: Appearance.font.family.monospace
                color: root.locked ? Appearance.m3colors.m3outline : Appearance.colors.colOnSecondaryContainer
                elide: Text.ElideMiddle
            }
            StyledText {
                Layout.fillWidth: true
                visible: text.length > 0
                text: root.entry.description ?? ""
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: Appearance.m3colors.m3outline
                wrapMode: Text.WordWrap
            }
        }

        // The state badge. It is a label and not a decoration: "inherited" is a
        // claim about where the value comes from, and it is the claim z10 grades.
        Rectangle {
            id: badge
            visible: root.derived || root.owned || root.locked
            readonly property string label: root.locked ? "locked"
                : (root.owned ? (root.derived ? "pinned" : "set") : "inherited")
            implicitWidth: badgeText.implicitWidth + 14
            implicitHeight: badgeText.implicitHeight + 6
            radius: Appearance.rounding.full
            color: root.locked ? Appearance.colors.colSecondaryContainer
                 : root.owned ? Appearance.colors.colPrimaryContainer
                 : "transparent"
            border.width: root.owned || root.locked ? 0 : 1
            border.color: Appearance.m3colors.m3outline
            StyledText {
                id: badgeText
                anchors.centerIn: parent
                text: badge.label
                font.pixelSize: Appearance.font.pixelSize.smallest
                color: Appearance.colors.colOnSecondaryContainer
            }
        }

        Loader {
            id: control
            Layout.preferredWidth: 260
            sourceComponent: root.locked ? lockedC
                : root.entry.widget === "switch" ? switchC
                : root.entry.widget === "slider" ? sliderC
                : root.entry.widget === "choice" ? choiceC
                : textC
        }

        // Unset: stop owning the key. For a derived key that is "go back to
        // following the wallpaper"; for anything else it is "go back to the
        // plugin default". Same button, because it is the same operation.
        RippleButton {
            visible: root.owned
            implicitWidth: 32; implicitHeight: 32
            buttonRadius: Appearance.rounding.full
            onClicked: Hd.unset(root.entry.key)
            contentItem: MaterialSymbol { anchors.centerIn: parent; text: "restart_alt"; iconSize: 18 }
            StyledToolTip { text: root.derived ? "Unpin -- follow the theme again" : "Back to the default" }
        }
    }

    StyledText {
        Layout.fillWidth: true
        visible: root.locked || (root.entry.note !== undefined)
        text: root.locked ? root.entry.locked : (root.entry.note ?? "")
        font.pixelSize: Appearance.font.pixelSize.smaller
        color: Appearance.m3colors.m3tertiary
        wrapMode: Text.WordWrap
    }

    StyledText {
        Layout.fillWidth: true
        visible: root.entry.follows !== undefined
        text: `-1 follows ${root.entry.follows ?? ""} -- that inheritance is the frost, so leaving it at -1 is the setting`
        font.pixelSize: Appearance.font.pixelSize.smaller
        color: Appearance.m3colors.m3outline
        wrapMode: Text.WordWrap
    }

    // ------------------------------------------------------------- widgets --
    Component {
        id: switchC
        StyledSwitch {
            checked: root.live === true || root.live === 1 || String(root.live) === "true"
            onToggled: root.commit(checked ? "true" : "false")
        }
    }

    Component {
        id: sliderC
        RowLayout {
            spacing: 6
            StyledSlider {
                id: sl
                Layout.fillWidth: true
                from: root.entry.min !== undefined ? root.entry.min : 0
                to: root.entry.max !== undefined ? root.entry.max : 100
                stepSize: root.entry.type === "int" ? 1 : 0.01
                value: Number(root.live)
                // The slider IS the preview: dragging writes live and nothing
                // else, releasing writes the fragment. Two verbs, one control.
                onMoved: Hd.preview(root.entry.key, root.entry.type === "int"
                                    ? Math.round(value) : value.toFixed(2))
                onPressedChanged: if (!pressed) root.commit(root.entry.type === "int"
                                    ? Math.round(value) : value.toFixed(2))
            }
            StyledText {
                Layout.preferredWidth: 46
                horizontalAlignment: Text.AlignRight
                text: root.entry.type === "int" ? Math.round(sl.value) : sl.value.toFixed(2)
                font.family: Appearance.font.family.monospace
                font.pixelSize: Appearance.font.pixelSize.smaller
            }
        }
    }

    Component {
        id: choiceC
        ComboBox {
            model: root.entry.choices ?? []
            currentIndex: Math.max(0, (root.entry.choices ?? []).indexOf(String(root.live)))
            onActivated: root.commit(currentValue)
        }
    }

    Component {
        id: textC
        MaterialTextField {
            text: String(root.live ?? "")
            onEditingFinished: if (text !== String(root.live)) root.commit(text)
        }
    }

    Component {
        id: lockedC
        RowLayout {
            spacing: 6
            MaterialSymbol { text: "lock"; iconSize: 16; color: Appearance.m3colors.m3outline }
            StyledText {
                text: String(root.live)
                font.family: Appearance.font.family.monospace
                color: Appearance.m3colors.m3outline
            }
        }
    }
}
