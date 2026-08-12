import QtQuick
import QtQuick.Layouts
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.hyprdrive
pragma ComponentBehavior: Bound

/**
 * THE pane. There is one of these and the panes differ only by a string.
 *
 * Hyprland, Blur, Dock, Overview and Quickshell are all this file with a
 * different `pane` -- their rows, their widgets, their apply-strategies and
 * their fragment all come out of docs/schema.json. Adding an option to the
 * product is a row in curated.json or a key in Config.cpp; it is never a new
 * QML file, and that contract is what Phase 12 builds its importer on top of.
 *
 * The filter box exists because "Hyprland: everything configurable" is 337 rows
 * and a pane you cannot search is a pane nobody reads.
 */
ContentPage {
    id: root
    required property string pane
    property string filter: ""
    baseWidth: 760
    forceWidth: true

    readonly property var paneDef: (Hd.schema?.panes ?? []).find(p => p.id === root.pane) ?? null
    readonly property var rows: {
        const all = Hd.entriesFor(root.pane);
        if (!root.filter) return all;
        const f = root.filter.toLowerCase();
        return all.filter(e => e.key.toLowerCase().includes(f)
                            || (e.description ?? "").toLowerCase().includes(f));
    }

    ContentSection {
        title: root.paneDef?.title ?? root.pane
        icon: root.paneDef?.icon ?? ""

        StyledText {
            Layout.fillWidth: true
            text: root.paneDef?.blurb ?? ""
            wrapMode: Text.WordWrap
            color: Appearance.m3colors.m3outline
            font.pixelSize: Appearance.font.pixelSize.smaller
        }

        MaterialTextField {
            Layout.fillWidth: true
            visible: Hd.entriesFor(root.pane).length > 12
            placeholderText: `Filter ${Hd.entriesFor(root.pane).length} options`
            onTextChanged: root.filter = text
        }

        StyledText {
            Layout.fillWidth: true
            visible: root.rows.length === 0
            text: "Nothing matches."
            color: Appearance.m3colors.m3outline
        }

        Repeater {
            model: root.rows
            SchemaRow {
                required property var modelData
                entry: modelData
            }
        }
    }

    // Every fragment-backed pane gets one. The Blur pane is not special here --
    // it is special in what its fan-out note says.
    ContentSection {
        visible: root.paneDef?.fragment !== null && root.paneDef?.fragment !== undefined
        title: ""
        RawEditor {
            pane: root.pane
            fragment: root.paneDef?.fragment ?? ""
            fanout: root.pane === "blur"
                ? "the dock pill (dock:blur_* are -1 = follow), the overview strip cells, "
                  + "the search and results panels, and every layer surface quickshell draws"
                : root.pane === "dock" ? "the dock pill and its hover preview panel"
                : root.pane === "overview" ? "the overview tiles, strip and search chrome"
                : "every surface that reads these keys"
        }
    }
}
