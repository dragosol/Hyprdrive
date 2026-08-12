import QtQuick
import QtQuick.Layouts
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.hyprdrive
pragma ComponentBehavior: Bound

/**
 * The raw-snippet editor: a text area over EXACTLY one fragment's raw block.
 *
 * Not an "advanced mode" and not a second config format -- it is the same block
 * a person editing the file by hand types into, which is why the machine half is
 * regenerated wholesale and this half is never touched. It sits LAST in the
 * fragment, and fragments are Lua, so the last assignment wins: a line typed
 * here overrides the generated one above it. That is the only ordering under
 * which "your edits survive" also means "your edits take effect".
 *
 * THE FAN-OUT NOTE is the point of putting one on the Blur pane. The dock's
 * blur_* keys all default to -1 = follow decoration:blur:*, so a line typed here
 * reaches the dock pill, the strip cells and every other frosted surface without
 * naming any of them. The note says which, because a user typing into a text box
 * deserves to know how far it goes.
 */
ColumnLayout {
    id: root
    required property string pane
    required property string fragment
    property string fanout: ""
    property string draft: ""
    property bool loaded: false

    Layout.fillWidth: true
    spacing: 6

    function load() {
        Hd.readRaw(root.pane);
    }

    Connections {
        target: Hd
        function onRawTextChanged() {
            if (Hd.rawPane !== root.pane) return;
            root.draft = Hd.rawText;
            area.text = Hd.rawText;
            root.loaded = true;
        }
    }

    Component.onCompleted: root.load()

    RowLayout {
        Layout.fillWidth: true
        MaterialSymbol { text: "code"; iconSize: 20 }
        StyledText {
            text: "Raw snippet"
            font.pixelSize: Appearance.font.pixelSize.larger
            font.weight: Font.Medium
            color: Appearance.colors.colOnSecondaryContainer
        }
        Item { Layout.fillWidth: true }
        StyledText {
            text: `~/.config/hypr/hyprdrive/${root.fragment}`
            font.family: Appearance.font.family.monospace
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.m3colors.m3outline
        }
    }

    StyledText {
        Layout.fillWidth: true
        text: "Lua, appended below everything this pane generates -- so a line here wins. "
              + "It survives every regeneration, including theme-sync rewriting the derived fragment."
              + (root.fanout ? "\nFans out to: " + root.fanout : "")
        font.pixelSize: Appearance.font.pixelSize.smaller
        color: Appearance.m3colors.m3outline
        wrapMode: Text.WordWrap
    }

    MaterialTextArea {
        id: area
        Layout.fillWidth: true
        Layout.preferredHeight: 160
        font.family: Appearance.font.family.monospace
        font.pixelSize: Appearance.font.pixelSize.smaller
        placeholderText: "-- nothing here yet. Anything you type applies after Save."
        onTextChanged: root.draft = text
    }

    RowLayout {
        Layout.fillWidth: true
        Item { Layout.fillWidth: true }
        RippleButton {
            enabled: root.loaded && root.draft !== Hd.rawText
            implicitHeight: 34
            onClicked: { area.text = Hd.rawText; root.draft = Hd.rawText; }
            contentItem: StyledText { text: "Discard"; anchors.centerIn: parent }
        }
        RippleButton {
            enabled: root.loaded && root.draft !== Hd.rawText
            implicitHeight: 34
            colBackground: Appearance.colors.colPrimary
            onClicked: Hd.rawWrite(root.pane, root.draft)
            contentItem: StyledText {
                text: "Save and reload"
                anchors.centerIn: parent
                color: Appearance.m3colors.m3onPrimary
            }
        }
    }
}
