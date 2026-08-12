//@ pragma UseQApplication
//@ pragma Env QS_NO_RELOAD_POPUP=1
//@ pragma Env QT_QUICK_CONTROLS_STYLE=Basic
//@ pragma Env QT_QUICK_FLICKABLE_WHEEL_DECELERATION=10000
//@ pragma Env QT_SCALE_FACTOR=1
//@ pragma Env QT_WAYLAND_DISABLE_WINDOWDECORATION=1

// Hyprdrive Settings -- one app for the overview, the dock, the compositor and
// the shell, hosted in Quickshell alongside illogical-impulse's own settings
// window and built from the same widget vocabulary.
//
// IN QUICKSHELL AND NOT IN THE PLUGIN, on purpose: a settings crash must never
// be able to take the session with it. The compositor learns about a change the
// same way it learns about a hand-edited config -- somebody wrote a fragment and
// asked for a reload.
//
// IT OBEYS THE PRODUCT LAWS ITSELF. Two of them are visible in this file:
//
//   FROST. The window is transparent and paints its own translucent surface, so
//   the compositor blurs the desktop behind it. `color: "transparent"` is what
//   stops Qt declaring an opaque region -- an app that fills its own background
//   defeats compositor blur no matter what decoration:blur says, which is the
//   same trap the gates' kitty-only fixture rule exists for.
//
//   MOTION. Entrances decelerate, exits accelerate and finish 23% sooner, both
//   inside the 200-400ms band, no bounce anywhere. The numbers are in
//   modules/hyprdrive/Motion.qml so the grading gate and the app read the same
//   constants.

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import qs.modules.hyprdrive

ApplicationWindow {
    id: root

    property real contentPadding: 8
    property int currentPage: 0
    // What the nav says vs what the pane is showing. They differ for exactly the
    // length of the exit animation: the swap happens at the invisible point in
    // the middle, so a pane switch is never a flash of the wrong pane. (Same
    // reason the overview never shows a double image.)
    property int activePage: 0
    property bool closing: false

    // The panes come from the schema, so a pane added in curated.json appears
    // here without this file changing.
    readonly property var pages: Hd.schema?.panes ?? []

    visible: true
    title: "Hyprdrive Settings"
    minimumWidth: 900
    minimumHeight: 560
    width: 1180
    height: 780

    // Transparent window + our own translucent surface = a backdrop for the
    // compositor to blur. Filling this with an opaque colour would be an app
    // that says it is frosted and is not.
    color: "transparent"

    // ------------------------------------------------------------- lifecycle --
    Component.onCompleted: {
        MaterialThemeLoader.reapplyTheme();
        openAnim.start();
    }

    // The close is an animation with a quit on the end of it, not a quit. An exit
    // that skips its own motion is the exit nobody graded.
    onClosing: close => {
        if (root.closing) return;
        close.accepted = false;
        root.closing = true;
        closeAnim.start();
    }

    NumberAnimation {
        id: openAnim
        target: surface
        properties: "opacity"
        from: 0; to: 1
        duration: Motion.enterMs
        easing.type: Motion.enterEasing
    }

    SequentialAnimation {
        id: closeAnim
        NumberAnimation {
            target: surface
            properties: "opacity"
            from: 1; to: 0
            duration: Motion.exitMs
            easing.type: Motion.exitEasing
        }
        ScriptAction { script: Qt.quit() }
    }

    NumberAnimation {
        id: riseAnim
        target: surface
        properties: "anchors.topMargin"
        from: Motion.riseFrom; to: 0
        duration: Motion.enterMs
        easing.type: Motion.enterEasing
        running: true
    }

    // --------------------------------------------------------------- surface --
    Rectangle {
        id: surface
        anchors.fill: parent
        opacity: 0
        radius: Appearance.rounding.windowRounding
        // The frost. Alpha well under 1 so there is something to blur through;
        // the palette's own surface colour so the app belongs to the theme it
        // edits.
        color: ColorUtils.transparentize(Appearance.m3colors.m3surfaceContainerLow, 0.30)
        border.width: 1
        border.color: ColorUtils.transparentize(Appearance.m3colors.m3outline, 0.7)

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: root.contentPadding

            Item {   // titlebar
                Layout.fillWidth: true
                implicitHeight: 40
                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left
                    anchors.leftMargin: 12
                    color: Appearance.colors.colOnLayer0
                    text: "Hyprdrive"
                    font {
                        family: Appearance.font.family.title
                        pixelSize: Appearance.font.pixelSize.title
                        variableAxes: Appearance.font.variableAxes.title
                    }
                }
                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: Hd.status
                    color: Appearance.m3colors.m3outline
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    elide: Text.ElideMiddle
                    width: parent.width * 0.4
                    horizontalAlignment: Text.AlignHCenter
                }
                RippleButton {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.right: parent.right
                    buttonRadius: Appearance.rounding.full
                    implicitWidth: 35; implicitHeight: 35
                    onClicked: root.close()
                    contentItem: MaterialSymbol {
                        anchors.centerIn: parent
                        text: "close"
                        iconSize: 20
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: root.contentPadding

                Item {
                    id: navRailWrapper
                    Layout.fillHeight: true
                    Layout.margins: 5
                    implicitWidth: navRail.expanded ? 160 : 60

                    NavigationRail {
                        id: navRail
                        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                        spacing: 10
                        expanded: root.width > 980

                        NavigationRailExpandButton { focus: root.visible }

                        NavigationRailTabArray {
                            currentIndex: root.currentPage
                            expanded: navRail.expanded
                            Repeater {
                                model: root.pages
                                NavigationRailButton {
                                    required property var index
                                    required property var modelData
                                    toggled: root.currentPage === index
                                    onPressed: root.currentPage = index
                                    expanded: navRail.expanded
                                    buttonIcon: modelData.icon
                                    buttonText: modelData.title
                                    showToggledHighlight: false
                                }
                            }
                        }
                        Item { Layout.fillHeight: true }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    // Slightly more opaque than the window: the content layer is
                    // where text lives and text over a moving wallpaper is text
                    // nobody can read. Still translucent -- still frosted.
                    color: ColorUtils.transparentize(Appearance.m3colors.m3surfaceContainer, 0.18)
                    radius: Appearance.rounding.windowRounding - root.contentPadding

                    Loader {
                        id: pageLoader
                        anchors.fill: parent
                        anchors.margins: 14
                        active: Hd.ready

                        sourceComponent: {
                            const p = root.pages[root.activePage];
                            if (!p) return null;
                            return p.id === "monitors" ? monitorsC : schemaC;
                        }

                        // Pane switching obeys the same two curves as the window:
                        // out fast and accelerating, in slower and settling.
                        Connections {
                            target: root
                            function onCurrentPageChanged() {
                                switchAnim.complete();
                                switchAnim.start();
                            }
                        }

                        SequentialAnimation {
                            id: switchAnim
                            NumberAnimation {
                                target: pageLoader
                                properties: "opacity"
                                from: 1; to: 0
                                duration: Motion.exitMs
                                easing.type: Motion.exitEasing
                            }
                            PropertyAction { target: root; property: "activePage"; value: root.currentPage }
                            PropertyAction { target: pageLoader; property: "anchors.topMargin"; value: 14 + Motion.riseFrom }
                            ParallelAnimation {
                                NumberAnimation {
                                    target: pageLoader
                                    properties: "opacity"
                                    from: 0; to: 1
                                    duration: Motion.enterMs
                                    easing.type: Motion.enterEasing
                                }
                                NumberAnimation {
                                    target: pageLoader
                                    properties: "anchors.topMargin"
                                    to: 14
                                    duration: Motion.enterMs
                                    easing.type: Motion.enterEasing
                                }
                            }
                        }
                    }

                    Component {
                        id: schemaC
                        SchemaPane { pane: root.pages[root.activePage]?.id ?? "hyprland" }
                    }
                    Component { id: monitorsC; MonitorsPane {} }

                    StyledText {
                        anchors.centerIn: parent
                        visible: !Hd.ready
                        text: Hd.repo ? "Reading the schema…" : "Finding the repository…"
                        color: Appearance.m3colors.m3outline
                    }
                }
            }
        }
    }
}
