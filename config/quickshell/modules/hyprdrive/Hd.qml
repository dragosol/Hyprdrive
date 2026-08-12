import QtQuick
import Quickshell
import Quickshell.Io
pragma Singleton
pragma ComponentBehavior: Bound

/**
 * Hd -- the app's only door to the outside.
 *
 * Every read is a process that prints json and every write is `hdctl`. There is
 * deliberately no QML that composes a config line: the fragment contract lives
 * in scripts/fragment.py and a second implementation of it here is the one that
 * would eat somebody's raw block. So this file knows argv and nothing else.
 *
 * PREVIEW vs COMMIT is the model, not a detail. Dragging a slider calls
 * preview(), which is a live one-shot the compositor forgets at the next reload;
 * letting go calls set(), which writes the fragment and reloads. The UI says so
 * out loud because the difference is the difference between a value that
 * survives a wallpaper change and one that does not (Phase 10).
 */
Singleton {
    id: root

    property string repo: ""
    property var schema: null
    property bool ready: false
    property string status: ""
    property var monitors: []
    property real pendingSeconds: -1

    readonly property string hdctl: `${root.repo}/scripts/hdctl.py`
    readonly property string hdmon: `${root.repo}/scripts/hdmon.py`

    function entriesFor(pane) {
        if (!root.schema) return [];
        return root.schema.entries.filter(e => e.pane === pane);
    }

    function paneFragment(pane) {
        if (!root.schema) return null;
        const p = root.schema.panes.find(x => x.id === pane);
        return p ? p.fragment : null;
    }

    // --------------------------------------------------------------- writes --
    function preview(key, value) {
        Quickshell.execDetached(["python3", root.hdctl, "preview", key, String(value)]);
    }

    function commit(key, value) {
        root.status = `writing ${key}`;
        setProc.command = ["python3", root.hdctl, "set", key, String(value)];
        setProc.running = true;
    }

    function unset(key) {
        root.status = `unsetting ${key}`;
        setProc.command = ["python3", root.hdctl, "unset", key];
        setProc.running = true;
    }

    function iiSet(path, value) {
        root.status = `writing ${path}`;
        setProc.command = ["python3", root.hdctl, "ii-set", path, String(value)];
        setProc.running = true;
    }

    // The raw block goes over as base64 so nothing in somebody's Lua -- a quote,
    // a backslash, a newline, a `$` -- can become shell syntax on the way.
    function rawWrite(pane, text) {
        root.status = `writing the ${pane} raw block`;
        setProc.command = ["bash", "-c",
            `printf %s '${Qt.btoa(text)}' | base64 -d | python3 ${root.hdctl} raw-write ${pane}`];
        setProc.running = true;
    }

    // ---------------------------------------------------------------- reads --
    function refresh() {
        if (!root.repo) return;
        schemaProc.running = true;
    }

    function readRaw(pane) {
        rawProc.pane = pane;
        rawProc.command = ["python3", root.hdctl, "raw", pane];
        rawProc.running = true;
    }

    property string rawText: ""
    property string rawPane: ""

    function refreshMonitors() {
        monProc.running = true;
    }

    // ------------------------------------------------------------- monitors --
    function monitorApply(output, args) {
        var cmd = ["python3", root.hdmon, "apply", "--output", output];
        for (const k in args) {
            if (args[k] !== undefined && args[k] !== null && args[k] !== "")
                cmd = cmd.concat(["--" + k, String(args[k])]);
        }
        root.status = `applying ${output} -- confirm before the countdown ends`;
        setProc.command = cmd;
        setProc.running = true;
        pendingTimer.running = true;
    }

    function monitorConfirm() {
        root.status = "kept";
        setProc.command = ["python3", root.hdmon, "confirm"];
        setProc.running = true;
        root.pendingSeconds = -1;
        pendingTimer.running = false;
    }

    function monitorRevert() {
        root.status = "reverting";
        setProc.command = ["python3", root.hdmon, "revert"];
        setProc.running = true;
        root.pendingSeconds = -1;
        pendingTimer.running = false;
    }

    // --------------------------------------------------------------- plumbing --
    Process {
        id: repoProc
        running: true
        command: ["bash", "-c", "echo ${HYPRDRIVE_REPO:-$HOME/overview-cpp}"]
        stdout: StdioCollector {
            onStreamFinished: {
                root.repo = text.trim();
                root.refresh();
                root.refreshMonitors();
            }
        }
    }

    Process {
        id: schemaProc
        command: ["python3", root.hdctl, "schema", "--live"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.schema = JSON.parse(text);
                    root.ready = true;
                } catch (e) {
                    root.status = "schema unreadable: " + e;
                }
            }
        }
    }

    Process {
        id: monProc
        command: ["python3", root.hdmon, "list"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.monitors = JSON.parse(text); } catch (e) { root.monitors = []; }
            }
        }
    }

    Process {
        id: rawProc
        property string pane: ""
        stdout: StdioCollector {
            onStreamFinished: {
                root.rawPane = rawProc.pane;
                root.rawText = text.replace(/\n+$/, "");
            }
        }
    }

    Process {
        id: setProc
        stdout: StdioCollector {
            onStreamFinished: {
                root.status = text.trim().split("\n").pop();
                // The write already happened; re-read so every row shows what the
                // compositor actually has rather than what we asked for. They
                // differ whenever a pin, a raw line or a clamp had an opinion.
                refreshTimer.restart();
            }
        }
        stderr: StdioCollector {
            onStreamFinished: { if (text.trim()) root.status = text.trim(); }
        }
    }

    Timer {
        id: refreshTimer
        interval: 350          // the reload has to land first
        onTriggered: { root.refresh(); root.refreshMonitors(); }
    }

    Process {
        id: pendingProc
        command: ["python3", root.hdmon, "pending"]
        stdout: StdioCollector {
            onStreamFinished: {
                const t = text.trim();
                root.pendingSeconds = (t === "none" || t === "") ? -1 : parseFloat(t);
                if (root.pendingSeconds <= 0) {
                    pendingTimer.running = false;
                    root.refreshMonitors();
                }
            }
        }
    }

    Timer {
        id: pendingTimer
        interval: 500
        repeat: true
        onTriggered: pendingProc.running = true
    }
}
