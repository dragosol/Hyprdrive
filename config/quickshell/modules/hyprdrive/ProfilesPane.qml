import QtQuick
import QtQuick.Layouts
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.hyprdrive
pragma ComponentBehavior: Bound

/**
 * Profiles -- the undo button, and the shelf you put states on.
 *
 * The pane is deliberately thin, because everything difficult about profiles is
 * in scripts/hdprof.py and none of it should be re-decided here. What the UI
 * owes the user is three honest statements:
 *
 *   WHAT IS THERE TO UNDO. `dirty` is the difference between the files on disk
 *   and the last recorded state, and the Revert button is enabled exactly when
 *   that list is non-empty. A greyed-out Revert is the app saying "nothing has
 *   changed since you last said this was fine", which is information.
 *
 *   WHAT THE SNAPSHOTS ARE. Every entry in the log was taken BEFORE something --
 *   an import, a bulk apply, a monitor change -- so the reason column reads as
 *   what was about to happen, and restoring one means "as it was before that".
 *
 *   THAT REVERTING IS A REAL APPLY. It reloads the compositor, and it restarts
 *   quickshell when the shell's own config moved. The button says so; a revert
 *   that needed a manual reload afterwards would be a revert that half worked.
 */
ContentPage {
    id: root
    baseWidth: 760
    forceWidth: true

    property string newName: ""
    property string importPath: ""

    Component.onCompleted: Hd.refreshProfiles()

    // ------------------------------------------------------------ now --
    ContentSection {
        title: "Profiles"
        icon: "history"

        StyledText {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            color: Appearance.m3colors.m3outline
            font.pixelSize: Appearance.font.pixelSize.smaller
            text: "A git repository over every file the settings app can write: the fragments, "
                + "what this app owns, and illogical-impulse's config.json -- which is where the "
                + "wallpaper lives, so a profile restores the picture the accents were derived from. "
                + "Snapshots are taken automatically before an import, a bulk apply or a monitor change."
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Rectangle {
                implicitWidth: dirtyText.implicitWidth + 18
                implicitHeight: dirtyText.implicitHeight + 8
                radius: Appearance.rounding.full
                color: Hd.profDirty.length > 0 ? Appearance.colors.colPrimaryContainer : "transparent"
                border.width: Hd.profDirty.length > 0 ? 0 : 1
                border.color: Appearance.m3colors.m3outline
                StyledText {
                    id: dirtyText
                    anchors.centerIn: parent
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.colors.colOnSecondaryContainer
                    text: Hd.profDirty.length > 0
                          ? `${Hd.profDirty.length} file${Hd.profDirty.length === 1 ? "" : "s"} changed since the last snapshot`
                          : "unchanged since the last snapshot"
                }
            }

            Item { Layout.fillWidth: true }

            RippleButton {
                implicitHeight: 34
                onClicked: Hd.profSnapshot("manual snapshot")
                contentItem: StyledText { anchors.centerIn: parent; text: "Snapshot now" }
                StyledToolTip { text: "Record the current state. After this there is nothing to revert." }
            }

            RippleButton {
                implicitHeight: 34
                enabled: Hd.profDirty.length > 0
                colBackground: Appearance.colors.colPrimary
                onClicked: Hd.profRevert("")
                contentItem: StyledText {
                    anchors.centerIn: parent
                    text: "Revert"
                    // ii's RippleButton drops a disabled button's fill entirely
                    // and dims it to 0.4, so on-primary white over the frosted
                    // surface reads as nothing at all. A Revert that is greyed
                    // out is telling the user something -- it has to be legible
                    // while it does.
                    color: parent.enabled ? Appearance.m3colors.m3onPrimary
                                          : Appearance.m3colors.m3outline
                }
                StyledToolTip { text: "Put every file back to the last snapshot, reload the compositor, and restart the shell if its own config moved." }
            }
        }

        StyledText {
            Layout.fillWidth: true
            visible: Hd.profDirty.length > 0
            text: "  " + Hd.profDirty.join("\n  ")
            font.family: Appearance.font.family.monospace
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.m3colors.m3outline
        }
    }

    // ---------------------------------------------------------- saved --
    ContentSection {
        title: "Saved profiles"
        icon: "bookmark"

        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            MaterialTextField {
                Layout.fillWidth: true
                placeholderText: "Name this state — e.g. 'before the nord import'"
                onTextChanged: root.newName = text
            }
            RippleButton {
                implicitHeight: 34
                enabled: root.newName.trim().length > 0
                onClicked: Hd.profSave(root.newName.trim())
                contentItem: StyledText { anchors.centerIn: parent; text: "Save" }
            }
        }

        StyledText {
            Layout.fillWidth: true
            visible: Hd.profiles.length === 0
            text: "No saved profiles yet. A profile is a name on a snapshot — nothing is copied and nothing is uploaded."
            color: Appearance.m3colors.m3outline
            font.pixelSize: Appearance.font.pixelSize.smaller
            wrapMode: Text.WordWrap
        }

        Repeater {
            model: Hd.profiles
            RowLayout {
                required property var modelData
                Layout.fillWidth: true
                spacing: 8
                MaterialSymbol { text: "bookmark"; iconSize: 18 }
                StyledText {
                    Layout.fillWidth: true
                    text: modelData.name
                    font.weight: Font.Medium
                }
                StyledText {
                    text: modelData.ref
                    font.family: Appearance.font.family.monospace
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.m3colors.m3outline
                }
                RippleButton {
                    implicitHeight: 30
                    onClicked: Hd.profApply(modelData.name)
                    contentItem: StyledText { anchors.centerIn: parent; text: "Apply" }
                }
            }
        }
    }

    // -------------------------------------------------------- import --
    // The diff preview is the whole safety story of the importer, so it is not
    // hidden behind a dialog: the pane shows what would change, key by key, old
    // to new, and lists the lines it could not map BEFORE the Apply button is
    // reachable. Apply is disabled until a preview has been read, which is not
    // paternalism -- it is that "apply a file I have not looked at" is the one
    // thing this feature must not make easy.
    ContentSection {
        title: "Import a theme"
        icon: "download"

        StyledText {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            color: Appearance.m3colors.m3outline
            font.pixelSize: Appearance.font.pixelSize.smaller
            text: "A hyprland.conf-style file. Keys this schema knows become settings; everything "
                + "else — binds, exec-once, window rules, keys from another Hyprland version — is "
                + "kept exactly as written in the Hyprland pane's raw snippet. A snapshot is taken "
                + "first, always, so the whole import is one Revert away from never having happened."
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            MaterialTextField {
                Layout.fillWidth: true
                placeholderText: "~/themes/nord.conf"
                onTextChanged: root.importPath = text
            }
            RippleButton {
                implicitHeight: 34
                enabled: root.importPath.trim().length > 0
                onClicked: Hd.profImportPreview(root.importPath.trim())
                contentItem: StyledText { anchors.centerIn: parent; text: "Preview" }
            }
            RippleButton {
                implicitHeight: 34
                enabled: Hd.importReport !== null && (Hd.importReport.mapped?.length > 0
                                                      || Hd.importReport.verbatim?.length > 0)
                colBackground: Appearance.colors.colPrimary
                onClicked: Hd.profImportApply(root.importPath.trim())
                contentItem: StyledText {
                    anchors.centerIn: parent
                    text: "Import"
                    color: parent.enabled ? Appearance.m3colors.m3onPrimary
                                          : Appearance.m3colors.m3outline
                }
            }
        }

        StyledText {
            Layout.fillWidth: true
            visible: Hd.importReport !== null
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colOnSecondaryContainer
            text: Hd.importReport
                  ? `${Hd.importReport.counts.mapped} to change, `
                    + `${Hd.importReport.counts.unchanged} already that value, `
                    + `${Hd.importReport.counts.verbatim} kept verbatim`
                  : ""
        }

        Repeater {
            model: Hd.importReport ? Hd.importReport.mapped : []
            RowLayout {
                required property var modelData
                Layout.fillWidth: true
                spacing: 8
                StyledText {
                    Layout.fillWidth: true
                    text: modelData.key
                    font.family: Appearance.font.family.monospace
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    elide: Text.ElideMiddle
                    color: modelData.locked ? Appearance.m3colors.m3outline
                                            : Appearance.colors.colOnSecondaryContainer
                }
                StyledText {
                    text: String(modelData.old)
                    font.family: Appearance.font.family.monospace
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.m3colors.m3outline
                }
                MaterialSymbol { text: "arrow_forward"; iconSize: 14 }
                StyledText {
                    text: modelData.locked ? "refused — locked" : String(modelData.new)
                    font.family: Appearance.font.family.monospace
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: modelData.locked ? Appearance.m3colors.m3tertiary
                                            : Appearance.colors.colPrimary
                }
            }
        }

        StyledText {
            Layout.fillWidth: true
            visible: Hd.importReport !== null && Hd.importReport.verbatim?.length > 0
            wrapMode: Text.WordWrap
            font.family: Appearance.font.family.monospace
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.m3colors.m3outline
            text: Hd.importReport
                  ? "verbatim:\n  " + Hd.importReport.verbatim.map(v => v.text.trim()).join("\n  ")
                  : ""
        }
    }

    // -------------------------------------------------------- history --
    ContentSection {
        title: "History"
        icon: "schedule"

        Repeater {
            model: Hd.snapshots
            RowLayout {
                required property var modelData
                Layout.fillWidth: true
                spacing: 8
                StyledText {
                    text: modelData.ref
                    font.family: Appearance.font.family.monospace
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.colors.colOnSecondaryContainer
                }
                StyledText {
                    Layout.fillWidth: true
                    text: modelData.reason
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    elide: Text.ElideRight
                }
                RippleButton {
                    implicitHeight: 30
                    onClicked: Hd.profRevert(modelData.ref)
                    contentItem: StyledText { anchors.centerIn: parent; text: "Restore" }
                    StyledToolTip { text: "Put the surface back to how it was before: " + modelData.reason }
                }
            }
        }
    }
}
