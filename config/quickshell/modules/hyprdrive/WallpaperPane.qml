import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import qs.modules.hyprdrive
pragma ComponentBehavior: Bound

/**
 * Wallpaper -- repositories, a grid, and three rows.
 *
 * The rows at the bottom are ordinary SchemaRows off docs/schema.json, exactly
 * like every other pane's, and that is the point: slideshow mode, interval and
 * "the theme follows the wallpaper" are settings, so they are schema rows and
 * this file does not know their names. What this pane adds above them is the
 * part that is NOT a setting -- the list of places wallpapers come from, and the
 * pictures themselves.
 *
 * A REPOSITORY IS A DIRECTORY, and a remote one is a directory git put there.
 * Add a path, or add a URL and it is cloned. Pull is offered only for the cloned
 * ones because pulling a folder is not a thing. There is no push, no login and
 * no token anywhere in this feature.
 *
 * CLICKING A PICTURE TAKES THE THEME PATH. hyprwall-rotate's default is
 * palette-neutral on purpose -- the timer must not move the goalposts of the
 * gate suite -- but a swap a person just asked for is exactly the case where the
 * accents SHOULD follow, so the pane's swaps go through the THEME=1 side of the
 * same script. The wallpaper.theme row turns that off for people who want the
 * picture to change and the colours to stay.
 */
ContentPage {
    id: root
    baseWidth: 760
    forceWidth: true

    property string newRepoName: ""
    property string newRepoSource: ""

    readonly property var rows: Hd.entriesFor("wallpaper")
        .filter(e => e.key !== "wallpaper.path" && e.key !== "wallpaper.repo")

    Component.onCompleted: Hd.wallRefresh()

    // ------------------------------------------------------- repositories --
    ContentSection {
        title: "Wallpaper"
        icon: "wallpaper"

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            StyledText { text: "Repository" }

            ComboBox {
                id: repoBox
                Layout.preferredWidth: 220
                model: Hd.wallRepos.map(r => r.name)
                currentIndex: Math.max(0, Hd.wallRepos.findIndex(r => r.active))
                onActivated: Hd.commit("wallpaper.repo", currentValue)
            }

            StyledText {
                Layout.fillWidth: true
                elide: Text.ElideMiddle
                color: Appearance.m3colors.m3outline
                font.pixelSize: Appearance.font.pixelSize.smaller
                font.family: Appearance.font.family.monospace
                text: {
                    const r = Hd.wallRepos.find(x => x.active);
                    return r ? `${r.path}   ${r.count} wallpapers` : "no repository configured";
                }
            }

            RippleButton {
                implicitHeight: 32
                visible: (Hd.wallRepos.find(x => x.active)?.kind ?? "") === "git"
                onClicked: Hd.wallRepoPull(Hd.wallRepos.find(x => x.active).name)
                contentItem: StyledText { anchors.centerIn: parent; text: "Pull" }
                StyledToolTip { text: "git pull --ff-only. Clone and pull only — this never pushes and never asks for credentials." }
            }

            RippleButton {
                implicitHeight: 32
                enabled: Hd.wallRepos.length > 1
                onClicked: Hd.wallRepoRemove(Hd.wallRepos.find(x => x.active).name)
                contentItem: MaterialSymbol { anchors.centerIn: parent; text: "delete"; iconSize: 18 }
                StyledToolTip { text: "Forget this repository. The files are left where they are." }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            MaterialTextField {
                Layout.preferredWidth: 160
                placeholderText: "name"
                onTextChanged: root.newRepoName = text
            }
            MaterialTextField {
                Layout.fillWidth: true
                placeholderText: "a folder, or a git URL to clone"
                onTextChanged: root.newRepoSource = text
            }
            RippleButton {
                implicitHeight: 32
                enabled: root.newRepoName.trim().length > 0 && root.newRepoSource.trim().length > 0
                onClicked: Hd.wallRepoAdd(root.newRepoName.trim(), root.newRepoSource.trim())
                contentItem: StyledText { anchors.centerIn: parent; text: "Add" }
            }
        }
    }

    // ------------------------------------------------------------- the grid --
    ContentSection {
        title: ""

        StyledText {
            Layout.fillWidth: true
            visible: Hd.wallList.length === 0
            text: "Nothing in this repository yet."
            color: Appearance.m3colors.m3outline
        }

        GridLayout {
            Layout.fillWidth: true
            columns: 4
            columnSpacing: 8
            rowSpacing: 8

            Repeater {
                model: Hd.wallList
                Rectangle {
                    id: cell
                    required property var modelData
                    readonly property bool isCurrent: modelData.path === Hd.wallCurrent
                    Layout.fillWidth: true
                    Layout.preferredHeight: 96
                    radius: Appearance.rounding.small
                    color: "transparent"
                    border.width: cell.isCurrent ? 2 : 0
                    border.color: Appearance.colors.colPrimary
                    clip: true

                    // A video has no thumbnail without decoding it, and decoding
                    // a video to draw a settings grid is a lot of machinery for
                    // a picture of itself. The tile says what it is instead.
                    Image {
                        anchors.fill: parent
                        anchors.margins: 2
                        visible: !cell.modelData.video
                        source: cell.modelData.video ? "" : "file://" + cell.modelData.path
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        cache: false
                        sourceSize.width: 320
                    }

                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: 2
                        visible: cell.modelData.video
                        // Not colLayer2: in this shell that one is close enough
                        // to transparent that the tile reads as a rendering
                        // failure rather than as a video.
                        color: ColorUtils.transparentize(Appearance.m3colors.m3surfaceContainerHighest, 0.15)
                        radius: Appearance.rounding.small
                        ColumnLayout {
                            anchors.centerIn: parent
                            spacing: 2
                            MaterialSymbol {
                                Layout.alignment: Qt.AlignHCenter
                                text: "movie"
                                iconSize: 24
                            }
                            StyledText {
                                Layout.alignment: Qt.AlignHCenter
                                text: "video"
                                font.pixelSize: Appearance.font.pixelSize.smallest
                                color: Appearance.m3colors.m3outline
                            }
                        }
                    }

                    StyledText {
                        anchors.bottom: parent.bottom
                        anchors.left: parent.left
                        anchors.margins: 4
                        text: cell.modelData.path.split("/").pop()
                        font.pixelSize: Appearance.font.pixelSize.smallest
                        color: "white"
                        style: Text.Outline
                        styleColor: "black"
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Hd.wallSet(cell.modelData.path)
                    }
                }
            }
        }
    }

    // ------------------------------------------------------------ the rows --
    ContentSection {
        title: "Slideshow"
        icon: "slideshow"

        StyledText {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            color: Appearance.m3colors.m3outline
            font.pixelSize: Appearance.font.pixelSize.smaller
            text: "The timer wakes once a minute and reads these, so a change takes effect "
                + "immediately and nothing has to be restarted. Every swap it makes re-derives the "
                + "palette if the theme row is on — the whole desktop follows the slideshow."
        }

        Repeater {
            model: root.rows
            SchemaRow {
                required property var modelData
                entry: modelData
            }
        }
    }
}
