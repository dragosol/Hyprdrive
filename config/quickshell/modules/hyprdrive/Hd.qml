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

    // Profiles. `profDirty` is the list of files that differ from the last
    // snapshot -- it is what the Revert button is enabled by, so it is a
    // property and not a computed guess.
    property var snapshots: []
    property var profiles: []
    property var profDirty: []
    property string profHead: ""

    readonly property string hdctl: `${root.repo}/scripts/hdctl.py`
    readonly property string hdmon: `${root.repo}/scripts/hdmon.py`
    readonly property string hdprof: `${root.repo}/scripts/hdprof.py`
    readonly property string hdwall: `${root.repo}/scripts/hdwall.py`

    // Wallpapers. The repository list is data rather than a setting, so it lives
    // here and not in the schema; the mode, the interval and "the theme follows"
    // are settings and are ordinary schema rows.
    property var wallRepos: []
    property var wallList: []
    property string wallCurrent: ""

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

    // -------------------------------------------------------------- profiles --
    // Every one of these is `hdprof`, and hdprof is what the importer and the
    // monitor pane call too -- so "snapshot" means the same thing whether a
    // person clicked it or an import took it on their behalf.
    function refreshProfiles() {
        if (!root.repo) return;
        profStatusProc.running = true;
        profListProc.running = true;
        profTagProc.running = true;
    }

    function profSnapshot(reason) {
        root.status = "taking a snapshot";
        profProc.command = ["python3", root.hdprof, "snapshot", "--reason", reason];
        profProc.running = true;
    }

    function profSave(name) {
        root.status = `saving profile ${name}`;
        profProc.command = ["python3", root.hdprof, "save", name];
        profProc.running = true;
    }

    function profApply(name) {
        root.status = `applying profile ${name}`;
        profProc.command = ["python3", root.hdprof, "apply", name];
        profProc.running = true;
    }

    // No ref = the last snapshot, which is the one taken before whatever just
    // happened. That is the whole point of taking them before rather than after.
    function profRevert(ref) {
        root.status = ref ? `restoring ${ref}` : "reverting to the last snapshot";
        profProc.command = ref
            ? ["python3", root.hdprof, "revert", ref]
            : ["python3", root.hdprof, "revert"];
        profProc.running = true;
    }

    function profImportPreview(path) {
        root.importReport = null;
        root.status = `reading ${path}`;
        importProc.command = ["python3", `${root.repo}/scripts/hdimport.py`, "preview", path, "--json"];
        importProc.running = true;
    }

    function profImportApply(path) {
        root.status = `importing ${path}`;
        profProc.command = ["python3", `${root.repo}/scripts/hdimport.py`, "apply", path];
        profProc.running = true;
    }

    property var importReport: null

    // ------------------------------------------------------------ wallpaper --
    function wallRefresh() {
        if (!root.repo) return;
        wallReposProc.running = true;
        wallListProc.running = true;
    }

    // Not `hdctl set wallpaper.path`, and the difference matters: that row's
    // apply-strategy would take the theme flag from the store, which is right,
    // but the pane also has to refresh its own grid afterwards. Same script
    // underneath either way -- hyprwall-rotate.sh, THEME from the setting.
    function wallSet(path) {
        root.status = `wallpaper -> ${path}`;
        wallProc.command = ["python3", root.hdwall, "set", path];
        wallProc.running = true;
    }

    function wallRepoAdd(name, source) {
        root.status = `adding ${name}`;
        wallProc.command = ["python3", root.hdwall, "repo-add", name, source];
        wallProc.running = true;
    }

    function wallRepoRemove(name) {
        root.status = `removing ${name}`;
        wallProc.command = ["python3", root.hdwall, "repo-remove", name];
        wallProc.running = true;
    }

    function wallRepoPull(name) {
        root.status = `pulling ${name}`;
        wallProc.command = ["python3", root.hdwall, "repo-pull", name];
        wallProc.running = true;
    }

    // Called after the slideshow rows change: it only starts or stops the timer,
    // because the tick re-reads the settings itself.
    function wallSlideshowSync() {
        wallSyncProc.running = true;
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
                root.refreshProfiles();
                root.wallRefresh();
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
        onTriggered: {
            root.refresh();
            root.refreshMonitors();
            root.refreshProfiles();
            root.wallRefresh();
            root.wallSlideshowSync();
        }
    }

    Process {
        id: profStatusProc
        command: ["python3", root.hdprof, "status", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const d = JSON.parse(text);
                    root.profDirty = d.dirty ?? [];
                    root.profHead = d.head ?? "";
                } catch (e) { root.profDirty = []; }
            }
        }
    }

    Process {
        id: profListProc
        command: ["python3", root.hdprof, "list", "--json", "-n", "25"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.snapshots = JSON.parse(text).snapshots ?? []; }
                catch (e) { root.snapshots = []; }
            }
        }
    }

    Process {
        id: profTagProc
        command: ["python3", root.hdprof, "profiles", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.profiles = JSON.parse(text); } catch (e) { root.profiles = []; }
            }
        }
    }

    Process {
        id: importProc
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.importReport = JSON.parse(text); }
                catch (e) { root.status = "that file did not parse: " + e; }
            }
        }
        stderr: StdioCollector {
            onStreamFinished: { if (text.trim()) root.status = text.trim(); }
        }
    }

    Process {
        id: wallReposProc
        command: ["python3", root.hdwall, "repos", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.wallRepos = JSON.parse(text); } catch (e) { root.wallRepos = []; }
            }
        }
    }

    Process {
        id: wallListProc
        command: ["python3", root.hdwall, "list", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const d = JSON.parse(text);
                    root.wallList = d.wallpapers ?? [];
                    root.wallCurrent = d.current ?? "";
                } catch (e) { root.wallList = []; }
            }
        }
    }

    Process {
        id: wallSyncProc
        command: ["python3", root.hdwall, "slideshow"]
        stdout: StdioCollector { onStreamFinished: root.status = text.trim().split("\n").pop() }
    }

    Process {
        id: wallProc
        stdout: StdioCollector {
            onStreamFinished: {
                root.status = text.trim().split("\n").pop();
                refreshTimer.restart();
            }
        }
        stderr: StdioCollector {
            onStreamFinished: { if (text.trim()) root.status = text.trim(); }
        }
    }

    Process {
        id: profProc
        stdout: StdioCollector {
            onStreamFinished: {
                root.status = text.trim().split("\n").pop();
                refreshTimer.restart();
            }
        }
        stderr: StdioCollector {
            onStreamFinished: { if (text.trim()) root.status = text.trim(); }
        }
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
