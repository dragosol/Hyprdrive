import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.UPower
import "Model.js" as Model
import "Schema.js" as Schema

// THE HYPRDRIVE SETTINGS, STANDALONE (native port B1). The Omarchy panel
// (omarchy-plugin/HyprdrivePanel.qml) without the Omarchy shell: the same
// Schema.js rows in the same order, the same conditions, controls and
// hdpanel/hdicons conversation, but nothing from qs.Commons / qs.Ui. What the
// shell provided is provided here:
//   - Style.space / Style.font  -> `ui` below: the shell's own scale (body 12 px
//     there), one notch larger by default because this is a window you read,
//     not a popover (HYPRDRIVE_SETTINGS_SCALE multiplies it);
//   - Color.popups / accent / urgent -> hyprdrive's OWN derived palette, from
//     `hyprctl hyprdrive-theme -j` (SettingsApp.cpp): the dock's plate and the
//     overview's text and accent, so the window looks like the rest of
//     hyprdrive and retints when Hyprland reloads a theme. Without the plugin,
//     Qt's platform palette;
//   - KeyboardPanel / the bar host -> a plain window (shell.qml) whose `host`
//     carries the same few things Panel.qml did: opened, pendingIconApp,
//     close().
// It is kept a near line-for-line copy of HyprdrivePanel.qml on purpose: a
// change to one should be a diff that applies to the other. The differences are
// marked NATIVE.
Item {
  id: root

  // shell.qml: { opened, pendingIconApp, pendingPane, close() }.
  property var host: null

  // Mapped one tick after creation, so the card's own fade runs on the way in
  // (created already open, it would just appear).
  property bool shown: false
  readonly property bool isOpen: !!host && host.opened && shown
  Component.onCompleted: Qt.callLater(function() { root.shown = true; root.resolveCtl(); keys.forceActiveFocus() })

  // NATIVE. THE KEYBOARD STAYS WITH THE KEY HANDLER. Alt+1..8, Up/Down and
  // type-to-search live on `keys`, which only hears what reaches it: the
  // focused item or one of its children. In the panel the Omarchy shell hands
  // focus to it; here nothing did -- shell.qml's `focus: true` on this page
  // kept the window's focus on the page itself, above `keys`, so from the
  // first frame no key did anything until the search field was used and left
  // with Escape, the one path that called keys.forceActiveFocus() (phase 3
  // N1, seen after a scrollbar drag). So focus is handed to `keys` once the
  // page is up, and whenever it lands outside `keys`, or nowhere, it goes back.
  function keysOwnFocus() {
    var w = root.Window.window
    if (!w) return
    for (var it = w.activeFocusItem; it; it = it.parent) if (it === keys) return
    keys.forceActiveFocus()
  }
  Connections {
    target: root.Window.window
    function onActiveFocusItemChanged() { Qt.callLater(root.keysOwnFocus) }
  }

  // ------------------------------------------------------------------ theme
  // NATIVE. `theme` is `hyprctl hyprdrive-theme -j`, or {} until it answers
  // (and for good without the plugin), when Qt's palette stands in.
  property var theme: ({})
  SystemPalette { id: sysPal; colorGroup: SystemPalette.Active }
  function themeColor(name, fallback) {
    var v = theme[name]
    return v ? Qt.color(v) : fallback
  }
  readonly property color fg: themeColor("foreground", sysPal.windowText)
  // The dock's plate carries the dock's frost alpha; a window is opaque.
  readonly property color bg: { var c = themeColor("background", sysPal.window); return Qt.rgba(c.r, c.g, c.b, 1) }
  readonly property color accent: themeColor("accent", sysPal.highlight)
  readonly property color urgent: themeColor("urgent", "#f25a5a")
  readonly property color dim: tint(fg, 0.62)
  readonly property color faint: tint(fg, 0.38)
  readonly property color hairline: tint(fg, 0.09)
  readonly property color raised: tint(fg, 0.045)
  readonly property string fontFamily: ui.font.family
  readonly property int radius: Math.max(ui.space(6), Math.min(ui.space(14), ui.cornerRadius + ui.space(4)))

  // NATIVE. The shell's spacing and type scale (Commons/Style.qml: caption 10,
  // body-small 11, body 12, title 14, heading 16, display 24 at scale 1).
  QtObject {
    id: ui
    readonly property real scale: {
      var n = Number(Quickshell.env("HYPRDRIVE_SETTINGS_SCALE") || "")
      return (isFinite(n) && n > 0 ? n : 1) * (13 / 12)
    }
    readonly property int cornerRadius: { var n = Number(root.theme.rounding); return isFinite(n) ? n : 8 }
    function space(px) { var n = Number(px) * scale; return n <= 0 ? 0 : Math.max(1, Math.round(n)) }
    readonly property QtObject font: QtObject {
      // The UI face is the desktop's (Qt's default, i.e. fontconfig's sans);
      // the Omarchy shell draws in its monospace, which is Omarchy's look, not
      // plain Hyprland's.
      readonly property string family: Qt.application.font.family
      readonly property int caption: Math.round(10 * ui.scale)
      readonly property int bodySmall: Math.round(11 * ui.scale)
      readonly property int body: Math.round(12 * ui.scale)
      readonly property int title: Math.round(14 * ui.scale)
      readonly property int heading: Math.round(16 * ui.scale)
      readonly property int display: Math.round(24 * ui.scale)
    }
  }

  // NATIVE. The section and button glyphs are Nerd Font code points, which an
  // Omarchy desktop always has and a plain one may not (audit A15): without one
  // they would draw as boxes, so they are left out and the labels carry it.
  // HYPRDRIVE_SETTINGS_GLYPHS=0 forces that, for testing.
  readonly property bool glyphs: {
    var force = Quickshell.env("HYPRDRIVE_SETTINGS_GLYPHS")
    if (force === "0") return false
    var fams = Qt.fontFamilies()
    for (var i = 0; i < fams.length; i++) if (/Nerd Font|Symbols Nerd/i.test(fams[i])) return true
    return false
  }
  function gl(s, fallback) { return glyphs ? s : (fallback || "") }

  Process {
    id: themeProc
    running: true
    command: ["hyprctl", "hyprdrive-theme", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var t = null
        try { t = JSON.parse(String(text || "")) } catch (e) { t = null }
        if (t && t.foreground) root.theme = t
      }
    }
  }
  // A theme switch reloads Hyprland; follow it, as the dock does.
  Connections {
    target: Hyprland
    function onRawEvent(event) { if (event.name === "configreloaded") themeProc.running = true }
  }
  Component.onDestruction: themeProc.running = false

  function tint(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
  function mix(a, b, t) { return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t) }

  // One motion vocabulary for the panel itself.
  readonly property int quick: 140
  readonly property int calm: 240
  readonly property int slow: 380

  // ------------------------------------------------------------------ state
  property string ctlPath: ""
  property var hd: ({})
  property var pending: ({})
  property var defaults: ({})
  property var metaOptions: ({})
  property bool dumping: false
  property bool dumpWanted: false
  property var ctlQueue: []
  property bool ctlBusy: false

  property string section: "overview"
  property string shownSection: "overview"
  property string query: ""
  property int navDirection: 1
  property string toastText: ""
  property int gestureIndex: 0
  property var gestureDraft: null
  property bool gestureDirty: false
  property real lastScale: 1
  property int lastMinimizeMs: 400

  readonly property bool onBattery: UPower.onBattery === true
  readonly property var shownSectionData: Schema.sectionById(shownSection)
  readonly property var pageCards: query !== "" ? searchCards : shownSectionData.cards
  readonly property var searchCards: {
    var groups = Schema.search(root.query)
    var out = []
    for (var i = 0; i < groups.length; i++) out.push({ title: groups[i].title, rows: groups[i].rows, section: groups[i].section })
    return out
  }

  function k(key, fallback) {
    if (pending[key] !== undefined) return pending[key]
    var fb = fallback !== undefined ? fallback : defaults[key]
    return Model.keyOf(hd, key, fb)
  }
  function kb(key) { return Model.asBool(k(key)) }
  function kn(key) { return Model.asNumber(k(key), Model.asNumber(defaults[key], 0)) }

  function remember(key, value) {
    var next = Object.assign({}, pending)
    next[key] = value
    pending = next
  }

  // --------------------------------------------------------------- hdpanel
  function resolveCtl() {
    if (ctlPath !== "" || resolveProc.running) return
    resolveProc.running = true
  }

  function dump() {
    if (ctlPath === "") return
    if (dumping) { dumpWanted = true; return }
    dumpWanted = false
    dumping = true
    dumpProc.running = true
  }

  // A drag previews on every step; only the newest preview of a key is worth
  // running, so a queued one for the same key is replaced rather than stacked.
  function runCtl(args, refresh, previewKeyName) {
    if (ctlPath === "") return
    var q = ctlQueue.slice()
    if (previewKeyName)
      q = q.filter(function(job) { return job.previewKey !== previewKeyName })
    q.push({ args: args, refresh: refresh !== false, previewKey: previewKeyName || "" })
    ctlQueue = q
    pumpCtl()
  }

  function pumpCtl() {
    if (ctlPath === "" || ctlProc.running || ctlQueue.length === 0) return
    var q = ctlQueue.slice()
    var job = q.shift()
    ctlQueue = q
    ctlProc.refresh = job.refresh
    ctlProc.command = [ctlPath].concat(job.args)
    ctlBusy = true
    ctlProc.running = true
  }

  function setKey(key, value) {
    remember(key, value)
    runCtl(["set", key, String(value)], true)
  }

  function previewKey(key, value) {
    remember(key, value)
    runCtl(["preview", key, String(value)], false, key)
  }

  function setMany(pairs) {
    var args = ["set"]
    for (var i = 0; i < pairs.length; i++) {
      remember(pairs[i][0], pairs[i][1])
      args.push(pairs[i][0], String(pairs[i][1]))
    }
    runCtl(args, true)
  }

  function restoreSection(sec) {
    if (sec.group === "icons") {
      iconsRun(["reset-all"], true)
      showToast("Every dock app has its own icon again")
      return
    }
    runCtl(["reset", sec.group], true)
    var next = Object.assign({}, pending)
    for (var key in defaults) {
      var m = metaFor(key)
      if (m && m.group === sec.group) next[key] = defaults[key]
    }
    pending = next
    if (sec.group === "gestures") { gestureDraft = null; gestureDirty = false; gestureIndex = 0 }
    showToast(sec.title + " restored to defaults")
  }

  function metaFor(key) {
    var list = hd.meta || []
    for (var i = 0; i < list.length; i++) if (list[i].key === key) return list[i]
    return null
  }

  function showToast(text) {
    toastText = text
    toastTimer.restart()
  }

  function askConfirm(spec, onAllow) {
    if (menuLayer.owner) menuLayer.close()
    // Off the search field, so Enter and Escape reach the confirm.
    keys.forceActiveFocus()
    confirmLayer.ask(spec, onAllow)
  }

  // ------------------------------------------------------------- conditions
  function rowEnabled(row) {
    switch (row.when) {
    case "dockOn": return kb("plugin:hyprdrive:dock:enabled")
    case "mountsOn": return kb("plugin:hyprdrive:dock:enabled") && kb("plugin:hyprdrive:dock:show_mounts")
    case "springOn": return kb("plugin:hyprdrive:drag:spring_dock") || kb("plugin:hyprdrive:drag:spring_edges")
    case "hotCornerOn": return kb("plugin:hyprdrive:hot_corner:enabled")
    case "swapOn": return kb("plugin:hyprdrive:drag:hold_to_swap")
    case "isolateOvApplies": return !kb("plugin:hyprdrive:dock:isolate_workspaces")
    case "roomApplies": return kb("plugin:hyprdrive:dock:enabled") && !kb("plugin:hyprdrive:dock:autohide")
    case "motionOn": return kn("plugin:hyprdrive:anim_scale") > 0.001
    case "blurOn": return kb("plugin:hyprdrive:motion_blur:enabled")
    case "mosaicOn": return kb("plugin:hyprdrive:mosaic:enabled")
    default: return true
    }
  }

  // NATIVE. Schema.js is shared with the Omarchy panel and speaks Omarchy
  // where that is true there (the hot corner's menu button, Super+L). Off
  // Omarchy these rows say what happens here instead -- the chords Mosaic
  // takes are plugin:hyprdrive:mosaic:cycle_bind, whose "auto" is Super+L.
  readonly property bool omarchyDesktop: (hd.integration || theme.integration || "none") === "omarchy"
  readonly property string mosaicChord: {
    var v = String(k("plugin:hyprdrive:mosaic:cycle_bind", "auto"))
    if (v === "auto") return "SUPER + L"
    return v === "none" ? "" : v
  }
  function chordLabel(c) {
    return String(c).split("+").map(function(p) { p = p.trim(); return p.charAt(0) + p.slice(1).toLowerCase() }).join("+")
  }
  function rowDesc(row) {
    if (omarchyDesktop) return row.desc || ""
    switch (row.key) {
    case "plugin:hyprdrive:hot_corner:corner":
      return "Only a corner at the outside edge of your screens counts."
    case "plugin:hyprdrive:mosaic:enabled":
      return "Windows keep their natural size and gather in the middle of the desktop. When they no longer fit, the desktop tiles them, and goes back to the mosaic once they fit again. Drag a window's corner to resize it. "
        + (mosaicChord !== "" ? chordLabel(mosaicChord) + " cycles Dwindle → Scrolling → Mosaic. "
                              : "No key is taken: pick a cycle key below, or make Mosaic the default. ")
        + "Recommended for large displays: on a laptop screen only a couple of windows fit before it tiles."
    case "plugin:hyprdrive:mosaic:default":
      return "New desktops, and any you have not set " + (mosaicChord !== "" ? "with " + chordLabel(mosaicChord) : "with the cycle key")
        + ", start in Mosaic. Off restores the previous default."
    }
    return row.desc || ""
  }
  // The question a `confirm` row asks before it turns on, or null to just do it.
  function rowConfirm(row) {
    if (!row.confirm || omarchyDesktop) return row.confirm || null
    if (row.key === "plugin:hyprdrive:mosaic:enabled") {
      if (mosaicChord === "") return null   // nothing outside hyprdrive changes
      var c = chordLabel(mosaicChord)
      return { title: row.confirm.title, glyph: row.confirm.glyph, allow: row.confirm.allow,
               body: c + " will cycle Dwindle → Scrolling → Mosaic, replacing whatever it does now. Turning Mosaic off gives " + c + " back." }
    }
    return row.confirm
  }

  function formatValue(row, v) {
    var n = Number(v)
    switch (row.fmt) {
    case "percent": return Math.round(n * 100) + "%"
    case "follow": return n < 0 ? "Follow" : String(Math.round(n)) + (row.unit ? " " + row.unit : "")
    case "deciseconds": return Math.round(n * 100) + " ms"
    case "samples": return n < 2 ? "Off" : String(Math.round(n))
    case "fraction": return n.toFixed(2)
    }
    var decimals = row.step && row.step < 1 ? (row.step < 0.1 ? 2 : 1) : 0
    return n.toFixed(decimals) + (row.unit ? " " + row.unit : "")
  }

  function goTo(id) {
    if (id === section && query === "") return
    var from = sectionIndex(section), to = sectionIndex(id)
    navDirection = to >= from ? 1 : -1
    query = ""
    searchField.text = ""
    section = id
  }

  function sectionIndex(id) {
    for (var i = 0; i < Schema.sections.length; i++) if (Schema.sections[i].id === id) return i
    return 0
  }

  onSectionChanged: pageSwap.restart()
  onQueryChanged: pageSwap.restart()

  // ------------------------------------------------------------------- icons
  // bin/hdicons, beside hdpanel. Its own process: it answers in JSON of its
  // own, and a search must not wait behind a queue of key writes.
  readonly property string iconsPath: ctlPath === "" ? "" : ctlPath.replace(/hdpanel$/, "hdicons")
  property var iconApps: []
  property var iconTrash: []
  property var iconSettings: ({ dirs: [], selfhst: false })
  property string iconSel: ""
  property string iconQuery: ""
  property var iconResults: ({})
  property bool iconSearching: false
  property var iconQueue: []
  readonly property var iconApp: {
    for (var i = 0; i < iconApps.length; i++) if (iconApps[i].id === iconSel) return iconApps[i]
    for (var j = 0; j < iconTrash.length; j++) if (iconTrash[j].id === iconSel) return iconTrash[j]
    return null
  }
  function iconsRun(args, relist) {
    if (iconsPath === "") return
    iconQueue = iconQueue.concat([{ args: args, relist: relist === true }])
    pumpIcons()
  }
  function pumpIcons() {
    if (iconsPath === "" || iconsProc.running || iconQueue.length === 0) return
    var q = iconQueue.slice(), job = q.shift()
    iconQueue = q
    iconsProc.relist = job.relist
    iconsProc.command = [iconsPath].concat(job.args)
    iconsProc.running = true
  }
  function iconsList() { iconsRun(["list"], false) }
  function iconsSearch(text) {
    iconQuery = text
    iconSearchDebounce.restart()
  }
  function pickIcon(value, label) {
    if (!iconApp) return
    var name = iconApp.trash ? "Trash · " + iconApp.name : iconApp.name
    iconsRun(["set", iconApp.id, value], true)
    showToast(name + " now uses " + label)
  }
  function iconsConfig(change) {
    iconsRun(["config", JSON.stringify(change)], true)
  }
  onIconsPathChanged: if (iconsPath !== "") iconsList()
  // The dock's Get Info -> App Icon (Panel.qml's `icons` IPC call).
  function takePendingIcon() {
    if (!host || !host.pendingIconApp) return
    iconSel = host.pendingIconApp
    host.pendingIconApp = ""
    goTo("icons")
    iconsList()
  }
  // NATIVE. `hyprdrive-settings --pane dock` (and the `settings` dispatcher's
  // `pane <id>`): open on that section. An id that is not a section is ignored.
  function takePendingPane() {
    if (!host || !host.pendingPane) return
    var id = host.pendingPane
    host.pendingPane = ""
    for (var i = 0; i < Schema.sections.length; i++)
      if (Schema.sections[i].id === id) { goTo(id); return }
  }
  onHostChanged: { takePendingIcon(); takePendingPane() }
  Connections {
    target: root.host
    ignoreUnknownSignals: true
    function onPendingIconAppChanged() { root.takePendingIcon() }
    function onPendingPaneChanged() { root.takePendingPane() }
  }

  // ----------------------------------------------------------------- gestures
  readonly property var gestureList: gestureDraft !== null ? gestureDraft : Model.cloneGestures(hd.gestures)
  function editGestures(mutator) {
    var list = Model.cloneGestures(gestureList)
    mutator(list)
    gestureDraft = list
    gestureDirty = true
  }
  function applyGestures() {
    runCtl(["gestures-set", JSON.stringify(gestureList)], true)
    gestureDirty = false
    showToast("Gesture map applied")
  }

  // --------------------------------------------------------------- processes
  Process {
    id: iconsProc
    property bool relist: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var d = null
        try { d = JSON.parse(String(text || "{}")) } catch (e) { d = null }
        if (d && d.ok === false) root.showToast(d.error || "That didn't work")
        else if (d && d.apps) {
          root.iconApps = d.apps
          root.iconTrash = d.trash || []
          root.iconSettings = d.settings || root.iconSettings
          if (root.iconSel === "" && d.apps.length) root.iconSel = d.apps[0].id
        } else if (d && d.settings) root.iconSettings = d.settings
      }
    }
    onExited: {
      if (relist) root.iconsList()
      root.pumpIcons()
    }
  }
  Process {
    id: iconSearchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.iconResults = JSON.parse(String(text || "{}")) } catch (e) { root.iconResults = ({}) }
        root.iconSearching = false
      }
    }
  }
  Timer {
    id: iconSearchDebounce
    interval: 220
    onTriggered: {
      if (root.iconsPath === "" || root.iconQuery.trim() === "") { root.iconResults = ({}); return }
      iconSearchProc.running = false
      root.iconSearching = true
      iconSearchProc.command = [root.iconsPath, "search", root.iconQuery]
      iconSearchProc.running = true
    }
  }

  // NATIVE. The launcher says where hdpanel is (HYPRDRIVE_HDPANEL: the
  // installed $PREFIX/lib/hyprdrive copy, or a checkout's omarchy-plugin/bin);
  // run by hand, the copy beside this checkout, then the default PREFIX.
  Process {
    id: resolveProc
    command: ["sh", "-c",
      'for c in "$HYPRDRIVE_HDPANEL" "$1" "$HOME/.local/lib/hyprdrive/hdpanel"; do ' +
      '[ -n "$c" ] && [ -x "$c" ] && { echo "$c"; exit 0; }; done; echo "$HOME/.local/lib/hyprdrive/hdpanel"',
      "sh", String(Qt.resolvedUrl("../omarchy-plugin/bin/hdpanel")).replace(/^file:\/\//, "")]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.ctlPath = String(text || "").trim()
        root.dump()
        root.pumpCtl()
      }
    }
  }

  Process {
    id: dumpProc
    command: [root.ctlPath, "dump"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = null
        try { parsed = JSON.parse(String(text || "{}")) } catch (e) {}
        if (parsed) {
          var defs = {}, opts = {}
          var meta = parsed.meta || []
          for (var i = 0; i < meta.length; i++) {
            defs[meta[i].key] = meta[i]["default"]
            if (meta[i].options) opts[meta[i].key] = meta[i].options
          }
          root.defaults = defs
          root.metaOptions = opts
          root.hd = parsed
          var s = Model.asNumber(Model.keyOf(parsed, "plugin:hyprdrive:anim_scale", 1), 1)
          if (s > 0.001) root.lastScale = s
          var m = Model.asNumber(Model.keyOf(parsed, "plugin:hyprdrive:dock:minimize_ms", 400), 400)
          if (m > 0) root.lastMinimizeMs = m
        }
        if (!root.ctlBusy) root.pending = ({})
        root.dumping = false
        if (root.dumpWanted) root.dump()
      }
    }
  }

  Process {
    id: ctlProc
    property bool refresh: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.ctlBusy = false
        if (ctlProc.refresh && root.ctlQueue.length === 0) root.dump()
        root.pumpCtl()
      }
    }
  }

  Timer { id: toastTimer; interval: 2200; onTriggered: root.toastText = "" }

  onIsOpenChanged: if (isOpen) resolveCtl()

  // ============================================================== controls

  // A switch: the track fills with the accent, the knob springs across.
  component Switch: Item {
    id: sw
    property bool checked: false
    property bool live: true
    signal toggled()
    implicitWidth: ui.space(40)
    implicitHeight: ui.space(22)
    opacity: live ? 1 : 0.4

    Rectangle {
      anchors.fill: parent
      radius: height / 2
      color: sw.checked ? root.accent : root.tint(root.fg, swArea.containsMouse ? 0.16 : 0.11)
      border.width: 1
      border.color: sw.checked ? root.tint(root.accent, 0.9) : root.tint(root.fg, 0.12)
      Behavior on color { ColorAnimation { duration: root.quick } }
    }
    Rectangle {
      id: knob
      width: sw.height - ui.space(6)
      height: width
      radius: width / 2
      y: ui.space(3)
      x: sw.checked ? sw.width - width - ui.space(3) : ui.space(3)
      color: sw.checked ? root.bg : root.fg
      scale: swArea.pressed ? 0.86 : 1
      Behavior on x { NumberAnimation { duration: root.calm; easing.type: Easing.OutBack; easing.overshoot: 1.6 } }
      Behavior on scale { NumberAnimation { duration: root.quick; easing.type: Easing.OutCubic } }
      Behavior on color { ColorAnimation { duration: root.quick } }
    }
    MouseArea {
      id: swArea
      anchors.fill: parent
      anchors.margins: -ui.space(6)
      hoverEnabled: true
      enabled: sw.live
      cursorShape: Qt.PointingHandCursor
      onClicked: sw.toggled()
    }
  }

  // A track with a value chip. `ticks` draws a detent per step (the motion
  // blur strengths' eighths). moved() while dragging, released() on let go.
  component ValueSlider: Item {
    id: sl
    property real from: 0
    property real to: 1
    property real stepSize: 0.01
    property real value: 0
    property bool ticks: false
    property bool live: true
    property string valueText: ""
    signal moved(real v)
    signal released(real v)
    implicitWidth: ui.space(280)
    implicitHeight: ui.space(26)
    opacity: live ? 1 : 0.4

    property real dragValue: value
    property bool dragging: slArea.pressed
    readonly property real current: dragging ? dragValue : value
    readonly property real frac: to > from ? Math.max(0, Math.min(1, (current - from) / (to - from))) : 0
    readonly property real trackW: width - chip.width - ui.space(14)

    function snap(v) {
      var s = stepSize > 0 ? Math.round((v - from) / stepSize) * stepSize + from : v
      return Math.max(from, Math.min(to, Number(s.toFixed(4))))
    }
    function valueAt(x) { return snap(from + Math.max(0, Math.min(1, x / trackW)) * (to - from)) }

    Item {
      id: track
      width: sl.trackW
      height: parent.height
      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width
        height: ui.space(4)
        radius: height / 2
        color: root.tint(root.fg, 0.12)
      }
      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: Math.max(height, parent.width * sl.frac)
        height: ui.space(4)
        radius: height / 2
        color: root.accent
        Behavior on width { enabled: !sl.dragging; NumberAnimation { duration: root.calm; easing.type: Easing.OutCubic } }
      }
      Repeater {
        model: sl.ticks && sl.stepSize > 0 ? Math.round((sl.to - sl.from) / sl.stepSize) + 1 : 0
        Rectangle {
          required property int index
          readonly property real at: index / Math.max(1, Math.round((sl.to - sl.from) / sl.stepSize))
          x: track.width * at - width / 2
          anchors.verticalCenter: parent.verticalCenter
          width: ui.space(2)
          height: ui.space(8)
          radius: 1
          color: at <= sl.frac + 0.0001 ? root.tint(root.bg, 0.55) : root.tint(root.fg, 0.22)
        }
      }
      Rectangle {
        id: thumb
        width: ui.space(16)
        height: width
        radius: width / 2
        x: track.width * sl.frac - width / 2
        anchors.verticalCenter: parent.verticalCenter
        color: root.fg
        border.width: ui.space(3)
        border.color: root.accent
        scale: sl.dragging ? 1.18 : (slArea.containsMouse ? 1.06 : 1)
        Behavior on x { enabled: !sl.dragging; NumberAnimation { duration: root.calm; easing.type: Easing.OutCubic } }
        Behavior on scale { NumberAnimation { duration: root.quick; easing.type: Easing.OutBack } }
      }
      MouseArea {
        id: slArea
        anchors.fill: parent
        anchors.leftMargin: -ui.space(8)
        anchors.rightMargin: -ui.space(8)
        hoverEnabled: true
        enabled: sl.live
        cursorShape: Qt.PointingHandCursor
        preventStealing: true
        function at(mx) { return sl.valueAt(mx - ui.space(8)) }
        onPressed: function(m) { sl.dragValue = at(m.x); sl.moved(sl.dragValue) }
        onPositionChanged: function(m) {
          if (!pressed) return
          var v = at(m.x)
          if (v !== sl.dragValue) { sl.dragValue = v; sl.moved(v) }
        }
        onReleased: sl.released(sl.dragValue)
        onWheel: function(w) {
          var v = sl.snap(sl.value + (w.angleDelta.y > 0 ? sl.stepSize : -sl.stepSize))
          sl.moved(v); sl.released(v)
        }
      }
    }
    Rectangle {
      id: chip
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Math.max(ui.space(58), chipText.implicitWidth + ui.space(16))
      height: ui.space(24)
      radius: ui.space(7)
      color: sl.dragging ? root.tint(root.accent, 0.22) : root.raised
      border.width: 1
      border.color: sl.dragging ? root.tint(root.accent, 0.6) : root.hairline
      Behavior on color { ColorAnimation { duration: root.quick } }
      Text {
        textFormat: Text.PlainText
        id: chipText
        anchors.centerIn: parent
        text: sl.valueText
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: ui.font.bodySmall
      }
    }
  }

  // Segmented choice: the selection slides between the segments.
  component Segmented: Item {
    id: seg
    property var options: []
    property string value: ""
    property bool live: true
    signal picked(string v)
    implicitWidth: row.implicitWidth + ui.space(6)
    implicitHeight: ui.space(28)
    opacity: live ? 1 : 0.4
    readonly property int currentIndex: {
      for (var i = 0; i < options.length; i++) if (options[i].value === value) return i
      return -1
    }
    Rectangle { anchors.fill: parent; radius: ui.space(8); color: root.raised; border.width: 1; border.color: root.hairline }
    Rectangle {
      id: segSel
      readonly property Item target: rep.count > 0 && seg.currentIndex >= 0 ? rep.itemAt(seg.currentIndex) : null
      visible: target !== null
      x: target ? row.x + target.x : 0
      y: ui.space(3)
      width: target ? target.width : 0
      height: seg.height - ui.space(6)
      radius: ui.space(6)
      color: root.accent
      Behavior on x { NumberAnimation { duration: root.calm; easing.type: Easing.OutCubic } }
      Behavior on width { NumberAnimation { duration: root.calm; easing.type: Easing.OutCubic } }
    }
    Row {
      id: row
      x: ui.space(3)
      anchors.verticalCenter: parent.verticalCenter
      Repeater {
        id: rep
        model: seg.options
        Item {
          required property var modelData
          required property int index
          width: segLabel.implicitWidth + ui.space(22)
          height: seg.height - ui.space(6)
          Text {
            textFormat: Text.PlainText
            id: segLabel
            anchors.centerIn: parent
            text: modelData.label
            color: seg.currentIndex === index ? root.bg : (segHover.containsMouse ? root.fg : root.dim)
            font.family: root.fontFamily
            font.pixelSize: ui.font.bodySmall
            font.weight: seg.currentIndex === index ? Font.DemiBold : Font.Normal
            Behavior on color { ColorAnimation { duration: root.quick } }
          }
          MouseArea {
            id: segHover
            anchors.fill: parent
            hoverEnabled: true
            enabled: seg.live
            cursorShape: Qt.PointingHandCursor
            onClicked: seg.picked(modelData.value)
          }
        }
      }
    }
  }

  // A curve, drawn: the CSS cubic-bezier through (0,0) and (1,1), with room
  // above for an overshoot. `progress` >= 0 rides a dot along it.
  component CurveGlyph: Canvas {
    id: cg
    property var points: [0, 0, 1, 1]
    property color stroke: root.fg
    property real progress: -1
    property real lineWidth: ui.space(2)
    onPointsChanged: requestPaint()
    onStrokeChanged: requestPaint()
    onProgressChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    function bez(t, p1, p2) { var u = 1 - t; return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t }
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var pad = lineWidth + 2
      var w = width - pad * 2, h = height - pad * 2
      var top = 1.35
      function X(v) { return pad + v * w }
      function Y(v) { return pad + h - (v / top) * h }
      ctx.strokeStyle = Qt.rgba(stroke.r, stroke.g, stroke.b, 0.18)
      ctx.lineWidth = 1
      ctx.beginPath(); ctx.moveTo(X(0), Y(1)); ctx.lineTo(X(1), Y(1)); ctx.stroke()
      ctx.strokeStyle = stroke
      ctx.lineWidth = lineWidth
      ctx.lineCap = "round"
      ctx.beginPath()
      ctx.moveTo(X(0), Y(0))
      ctx.bezierCurveTo(X(points[0]), Y(points[1]), X(points[2]), Y(points[3]), X(1), Y(1))
      ctx.stroke()
      if (progress >= 0) {
        // Solve x(t) = progress for the dot's height.
        var lo = 0, hi = 1, t = progress
        for (var i = 0; i < 18; i++) {
          t = (lo + hi) / 2
          if (bez(t, points[0], points[2]) < progress) lo = t; else hi = t
        }
        ctx.fillStyle = root.accent
        ctx.beginPath()
        ctx.arc(X(progress), Y(bez(t, points[1], points[3])), lineWidth * 2.2, 0, Math.PI * 2)
        ctx.fill()
      }
    }
  }

  // A picture the panel can show: a file path, a URL, or nothing.
  component IconPic: Item {
    property string src: ""
    property real px: ui.space(36)
    width: px; height: px
    Image {
      anchors.fill: parent
      visible: parent.src !== ""
      source: parent.src === "" ? "" : (parent.src.indexOf("://") > 0 ? parent.src : "file://" + parent.src)
      sourceSize.width: parent.px * 2; sourceSize.height: parent.px * 2
      fillMode: Image.PreserveAspectFit
      asynchronous: true; smooth: true; mipmap: true
    }
    Rectangle {
      anchors.fill: parent; visible: parent.src === ""
      radius: width * 0.22; color: root.tint(root.fg, 0.08)
      Text { textFormat: Text.PlainText; anchors.centerIn: parent; text: "?"; color: root.faint; font.pixelSize: parent.height * 0.45; font.family: root.fontFamily }
    }
  }

  // A button that reads as text until hovered.
  component GhostButton: Rectangle {
    id: gb
    property string label: ""
    property string glyph: ""
    property bool emphasis: false
    property bool danger: false
    signal activated()
    implicitWidth: gbRow.implicitWidth + ui.space(22)
    implicitHeight: ui.space(30)
    radius: ui.space(8)
    readonly property color hue: danger ? root.urgent : root.accent
    color: emphasis ? hue : (gbArea.containsMouse ? root.tint(root.fg, 0.08) : "transparent")
    border.width: 1
    border.color: emphasis ? hue : (gbArea.containsMouse ? root.tint(root.fg, 0.18) : root.hairline)
    scale: gbArea.pressed ? 0.96 : 1
    Behavior on color { ColorAnimation { duration: root.quick } }
    Behavior on scale { NumberAnimation { duration: root.quick; easing.type: Easing.OutCubic } }
    Row {
      id: gbRow
      anchors.centerIn: parent
      spacing: ui.space(7)
      Text {
        textFormat: Text.PlainText
        visible: root.glyphs && gb.glyph !== ""
        text: gb.glyph
        color: gb.emphasis ? root.bg : root.dim
        font.family: root.fontFamily
        font.pixelSize: ui.font.bodySmall
        anchors.verticalCenter: parent.verticalCenter
      }
      Text {
        textFormat: Text.PlainText
        text: gb.label
        color: gb.emphasis ? root.bg : root.fg
        font.family: root.fontFamily
        font.pixelSize: ui.font.bodySmall
        font.weight: gb.emphasis ? Font.DemiBold : Font.Normal
        anchors.verticalCenter: parent.verticalCenter
      }
    }
    MouseArea {
      id: gbArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: gb.activated()
    }
  }

  // A dropdown button; the list opens in the panel-wide overlay (menuLayer),
  // so a card's clip never cuts it off. `kind` "curve" draws each option's
  // curve beside its name.
  component DropButton: Rectangle {
    id: db
    property var options: []
    property string value: ""
    property string kind: "plain"
    property bool live: true
    signal picked(string v)
    implicitWidth: ui.space(190)
    implicitHeight: ui.space(30)
    radius: ui.space(8)
    opacity: live ? 1 : 0.4
    color: dbArea.containsMouse || (menuLayer.owner === db) ? root.tint(root.fg, 0.08) : root.raised
    border.width: 1
    border.color: menuLayer.owner === db ? root.tint(root.accent, 0.8) : root.hairline
    Behavior on color { ColorAnimation { duration: root.quick } }
    readonly property var current: {
      for (var i = 0; i < options.length; i++) if (options[i].value === value) return options[i]
      return options.length ? options[0] : ({ label: value })
    }
    Row {
      anchors.left: parent.left
      anchors.leftMargin: ui.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: ui.space(8)
      CurveGlyph {
        visible: db.kind === "curve"
        width: ui.space(22)
        height: ui.space(18)
        anchors.verticalCenter: parent.verticalCenter
        points: db.current.decel || [0, 0, 1, 1]
        stroke: root.accent
        lineWidth: ui.space(1.5)
      }
      Text {
        textFormat: Text.PlainText
        text: db.current.label || db.value
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: ui.font.bodySmall
        anchors.verticalCenter: parent.verticalCenter
      }
    }
    Text {
      textFormat: Text.PlainText
      anchors.right: parent.right
      anchors.rightMargin: ui.space(10)
      anchors.verticalCenter: parent.verticalCenter
      text: root.gl("", "▾")
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: ui.font.bodySmall
      rotation: menuLayer.owner === db ? 180 : 0
      Behavior on rotation { NumberAnimation { duration: root.calm; easing.type: Easing.OutCubic } }
    }
    MouseArea {
      id: dbArea
      anchors.fill: parent
      hoverEnabled: true
      enabled: db.live
      cursorShape: Qt.PointingHandCursor
      onClicked: menuLayer.openFor(db, db.options, db.value, db.kind, function(v) { db.picked(v) })
    }
  }

  // One settings row: label and description on the left, its control on the
  // right (or below, for the wide ones).
  component SettingRow: Item {
    id: sr
    property var row: ({})
    property bool first: false
    readonly property bool live: root.rowEnabled(row)
    readonly property bool wide: row.type === "gestures" || row.type === "power" || row.type === "curve" || row.type === "icons"
    width: parent ? parent.width : 0
    implicitHeight: wide ? wideCol.implicitHeight + ui.space(24) : Math.max(labelCol.implicitHeight, controlHolder.implicitHeight) + ui.space(26)

    Rectangle {
      anchors.fill: parent
      anchors.leftMargin: -ui.space(10)
      anchors.rightMargin: -ui.space(10)
      radius: ui.space(8)
      color: rowHover.hovered && !sr.wide ? root.tint(root.fg, 0.035) : "transparent"
      Behavior on color { ColorAnimation { duration: root.quick } }
    }
    HoverHandler { id: rowHover }
    Rectangle {
      visible: !sr.first
      width: parent.width
      height: 1
      color: root.hairline
    }

    Column {
      id: labelCol
      visible: !sr.wide
      anchors.left: parent.left
      anchors.right: controlHolder.left
      anchors.rightMargin: ui.space(20)
      anchors.verticalCenter: parent.verticalCenter
      spacing: ui.space(3)
      opacity: sr.live ? 1 : 0.45
      Behavior on opacity { NumberAnimation { duration: root.calm } }
      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: sr.row.label || ""
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: ui.font.body
        elide: Text.ElideRight
      }
      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: root.rowDesc(sr.row) !== ""
        text: root.rowDesc(sr.row)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: ui.font.caption
        wrapMode: Text.WordWrap
        lineHeight: 1.15
      }
    }

    Loader {
      id: controlHolder
      visible: !sr.wide
      active: !sr.wide
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      sourceComponent: {
        switch (sr.row.type) {
        case "toggle": return toggleControl
        case "slider": return sliderControl
        case "choice": return choiceControl
        case "speed": return speedControl
        case "motion": return motionControl
        case "blur": return blurControl
        }
        return null
      }
      property var row: sr.row
      property bool live: sr.live
    }

    Column {
      id: wideCol
      visible: sr.wide
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.topMargin: ui.space(12)
      spacing: ui.space(10)
      Loader {
        width: parent.width
        active: sr.wide
        sourceComponent: sr.row.type === "curve" ? curveControl : sr.row.type === "gestures" ? gestureEditor : sr.row.type === "power" ? powerControl : sr.row.type === "icons" ? iconEditor : null
        property var row: sr.row
        property bool live: sr.live
      }
    }
  }

  Component {
    id: toggleControl
    Switch {
      property var row: parent ? parent.row : ({})
      checked: root.kb(row.key)
      live: parent ? parent.live : true
      // A row with `confirm` (Schema.js) reaches outside hyprdrive when it
      // turns on, so on asks first and only Allow sets it. Off never asks.
      onToggled: {
        var key = row.key, next = !root.kb(key)
        var ask = root.rowConfirm(row)
        if (next && ask) root.askConfirm(ask, function() { root.setKey(key, true) })
        else root.setKey(key, next)
      }
    }
  }

  Component {
    id: sliderControl
    ValueSlider {
      property var row: parent ? parent.row : ({})
      from: row.min; to: row.max; stepSize: row.step || 1
      value: root.kn(row.key)
      live: parent ? parent.live : true
      valueText: root.formatValue(row, current)
      onMoved: function(v) { root.previewKey(row.key, v) }
      onReleased: function(v) { root.setKey(row.key, v) }
    }
  }

  Component {
    id: choiceControl
    Segmented {
      property var row: parent ? parent.row : ({})
      options: root.metaOptions[row.key] || []
      value: String(root.k(row.key))
      live: parent ? parent.live : true
      onPicked: function(v) { root.setKey(row.key, v) }
    }
  }

  // anim_scale is a SLOWDOWN (2 = half speed); shown the right way up.
  Component {
    id: speedControl
    ValueSlider {
      from: 0.25; to: 2.0; stepSize: 0.05
      readonly property real scaleNow: root.kn("plugin:hyprdrive:anim_scale")
      value: scaleNow > 0.001 ? Math.max(0.25, Math.min(2, 1 / scaleNow)) : 1 / Math.max(0.001, root.lastScale)
      live: parent ? parent.live : true
      valueText: current.toFixed(2) + "×"
      onMoved: function(v) { root.previewKey("plugin:hyprdrive:anim_scale", Number((1 / v).toFixed(3))) }
      onReleased: function(v) { root.setKey("plugin:hyprdrive:anim_scale", Number((1 / v).toFixed(3))) }
    }
  }

  // Off is anim_scale 0 with the flight snapped too; on restores both.
  Component {
    id: motionControl
    Switch {
      checked: root.kn("plugin:hyprdrive:anim_scale") > 0.001
      onToggled: {
        var on = !checked
        if (!on) {
          var cur = root.kn("plugin:hyprdrive:anim_scale")
          if (cur > 0.001) root.lastScale = cur
          var ms = root.kn("plugin:hyprdrive:dock:minimize_ms")
          if (ms > 0) root.lastMinimizeMs = ms
        }
        root.setMany([["plugin:hyprdrive:anim_scale", on ? (root.lastScale > 0.001 ? root.lastScale : 1) : 0],
                      ["plugin:hyprdrive:dock:minimize_ms", on ? (root.lastMinimizeMs > 0 ? root.lastMinimizeMs : 400) : 0]])
      }
    }
  }

  // One motion-blur site: strength in eighths (0 = off) and, for the sites
  // that run on a clock, how the smear fades.
  Component {
    id: blurControl
    Row {
      id: blurRow
      spacing: ui.space(10)
      property var row: parent ? parent.row : ({})
      property bool rowLive: parent ? parent.live : true
      readonly property string sKey: "plugin:hyprdrive:motion_blur:" + row.site + ":strength"
      readonly property string fKey: "plugin:hyprdrive:motion_blur:" + row.site + ":fade"
      DropButton {
        visible: !!blurRow.row.clock
        implicitWidth: ui.space(112)
        anchors.verticalCenter: parent.verticalCenter
        options: Schema.fades
        value: String(root.k(blurRow.fKey))
        live: blurRow.rowLive && root.kn(blurRow.sKey) > 0
        onPicked: function(v) { root.setKey(blurRow.fKey, v) }
      }
      ValueSlider {
        implicitWidth: ui.space(250)
        anchors.verticalCenter: parent.verticalCenter
        from: 0; to: 1; stepSize: 0.125; ticks: true
        value: root.kn(blurRow.sKey)
        live: blurRow.rowLive
        valueText: current <= 0 ? "Off" : current.toFixed(3).replace(/0+$/, "").replace(/\.$/, "")
        onMoved: function(v) { root.previewKey(blurRow.sKey, v) }
        onReleased: function(v) { root.setKey(blurRow.sKey, v) }
      }
    }
  }

  // The curve picker: the choice on the left, a live demonstration on the
  // right -- a puck crossing a track on the chosen curve, and the curve drawn
  // with a dot riding it.
  Component {
    id: curveControl
    Item {
      id: cc
      property var row: parent ? parent.row : ({})
      property bool rowLive: parent ? parent.live : true
      implicitHeight: ui.space(118)
      readonly property string value: String(root.k(row.key))
      readonly property var preset: Schema.curveByValue(value)
      opacity: rowLive ? 1 : 0.45
      Behavior on opacity { NumberAnimation { duration: root.calm } }
      onValueChanged: demo.restart()

      Column {
        anchors.left: parent.left
        anchors.top: parent.top
        width: parent.width * 0.44
        spacing: ui.space(6)
        Text { textFormat: Text.PlainText; text: cc.row.label || ""; color: root.fg; font.family: root.fontFamily; font.pixelSize: ui.font.body }
        Text { textFormat: Text.PlainText; width: parent.width; text: cc.row.desc || ""; color: root.dim; font.family: root.fontFamily; font.pixelSize: ui.font.caption; wrapMode: Text.WordWrap }
        Item { width: 1; height: ui.space(4) }
        DropButton {
          implicitWidth: Math.min(parent.width, ui.space(220))
          options: Schema.curves
          value: cc.value
          kind: "curve"
          live: cc.rowLive
          onPicked: function(v) { root.setKey(cc.row.key, v) }
        }
        Text { textFormat: Text.PlainText; text: cc.preset.note; color: root.faint; font.family: root.fontFamily; font.pixelSize: ui.font.caption }
      }

      Rectangle {
        id: stage
        anchors.right: parent.right
        anchors.top: parent.top
        width: parent.width * 0.52
        height: parent.height
        radius: ui.space(10)
        color: root.raised
        border.width: 1
        border.color: root.hairline
        property real t: 0

        CurveGlyph {
          id: bigCurve
          anchors.left: parent.left
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          anchors.margins: ui.space(10)
          width: height * 1.1
          points: cc.preset.decel
          stroke: root.tint(root.fg, 0.85)
          progress: stage.t
        }
        Item {
          anchors.left: bigCurve.right
          anchors.leftMargin: ui.space(14)
          anchors.right: parent.right
          anchors.rightMargin: ui.space(14)
          anchors.verticalCenter: parent.verticalCenter
          height: ui.space(30)
          Rectangle { anchors.verticalCenter: parent.verticalCenter; width: parent.width; height: ui.space(2); radius: 1; color: root.tint(root.fg, 0.12) }
          Rectangle {
            id: puck
            width: ui.space(24); height: ui.space(24); radius: ui.space(7)
            anchors.verticalCenter: parent.verticalCenter
            color: root.accent
            x: 0
          }
        }
        MouseArea { anchors.fill: parent; hoverEnabled: true; onEntered: demo.restart(); onClicked: demo.restart() }

        SequentialAnimation {
          id: demo
          running: root.isOpen
          loops: 1
          PauseAnimation { duration: 180 }
          ParallelAnimation {
            NumberAnimation {
              target: puck; property: "x"; from: 0; to: puck.parent.width - puck.width; duration: 900
              easing.type: Easing.BezierSpline; easing.bezierCurve: [cc.preset.decel[0], cc.preset.decel[1], cc.preset.decel[2], cc.preset.decel[3], 1, 1]
            }
            NumberAnimation { target: stage; property: "t"; from: 0; to: 1; duration: 900 }
          }
          PauseAnimation { duration: 500 }
          ScriptAction { script: { stage.t = -1 } }
        }
      }
    }
  }

  // The trackpad map: the gestures as chips, the selected one's editor below.
  Component {
    id: gestureEditor
    Column {
      spacing: ui.space(12)
      readonly property var g: root.gestureList[root.gestureIndex] || null

      Flow {
        width: parent.width
        spacing: ui.space(8)
        Repeater {
          model: root.gestureList
          Rectangle {
            required property var modelData
            required property int index
            readonly property bool sel: index === root.gestureIndex
            width: chipLabel.implicitWidth + ui.space(22)
            height: ui.space(30)
            radius: ui.space(15)
            color: sel ? root.accent : (chipArea.containsMouse ? root.tint(root.fg, 0.1) : root.raised)
            border.width: 1
            border.color: sel ? root.accent : root.hairline
            Behavior on color { ColorAnimation { duration: root.quick } }
            Text {
              textFormat: Text.PlainText
              id: chipLabel
              anchors.centerIn: parent
              text: Model.gestureLabel(modelData, root.hd.actions)
              color: parent.sel ? root.bg : root.fg
              font.family: root.fontFamily
              font.pixelSize: ui.font.bodySmall
            }
            MouseArea { id: chipArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.gestureIndex = index }
          }
        }
        GhostButton {
          label: "Add"; glyph: ""
          onActivated: { root.editGestures(function(l) { l.push(Model.emptyGesture()) }); root.gestureIndex = root.gestureList.length - 1 }
        }
      }

      Rectangle {
        visible: g !== null
        width: parent.width
        height: editorCol.implicitHeight + ui.space(28)
        radius: ui.space(10)
        color: root.raised
        border.width: 1
        border.color: root.hairline
        Column {
          id: editorCol
          anchors.fill: parent
          anchors.margins: ui.space(14)
          spacing: ui.space(12)
          Row {
            spacing: ui.space(12)
            Text { textFormat: Text.PlainText; text: "Fingers"; color: root.dim; font.family: root.fontFamily; font.pixelSize: ui.font.bodySmall; anchors.verticalCenter: parent.verticalCenter; width: ui.space(72) }
            Segmented {
              options: [{ value: "2", label: "2" }, { value: "3", label: "3" }, { value: "4", label: "4" }, { value: "5", label: "5" }]
              value: g ? String(g.fingers) : "3"
              onPicked: function(v) { root.editGestures(function(l) { l[root.gestureIndex].fingers = Number(v) }) }
            }
          }
          Row {
            spacing: ui.space(12)
            Text { textFormat: Text.PlainText; text: "Direction"; color: root.dim; font.family: root.fontFamily; font.pixelSize: ui.font.bodySmall; anchors.verticalCenter: parent.verticalCenter; width: ui.space(72) }
            DropButton {
              options: (root.hd.directions || []).map(function(d) { return { value: d, label: d } })
              value: g ? g.direction : "up"
              onPicked: function(v) { root.editGestures(function(l) { l[root.gestureIndex].direction = v }) }
            }
            Text { textFormat: Text.PlainText; text: "Action"; color: root.dim; font.family: root.fontFamily; font.pixelSize: ui.font.bodySmall; anchors.verticalCenter: parent.verticalCenter; width: ui.space(52) }
            DropButton {
              implicitWidth: ui.space(260)
              options: root.hd.actions || []
              value: g ? g.action : "overview"
              onPicked: function(v) { root.editGestures(function(l) { l[root.gestureIndex].action = v }) }
            }
          }
          Row {
            spacing: ui.space(12)
            Text { textFormat: Text.PlainText; text: "Keys held"; color: root.dim; font.family: root.fontFamily; font.pixelSize: ui.font.bodySmall; anchors.verticalCenter: parent.verticalCenter; width: ui.space(72) }
            Rectangle {
              width: ui.space(200); height: ui.space(30); radius: ui.space(8)
              color: root.tint(root.fg, 0.03); border.width: 1; border.color: modsInput.activeFocus ? root.accent : root.hairline
              TextInput {
                id: modsInput
                anchors.fill: parent; anchors.leftMargin: ui.space(10); anchors.rightMargin: ui.space(10)
                verticalAlignment: TextInput.AlignVCenter
                text: g ? (g.mods || "") : ""
                color: root.fg; font.family: root.fontFamily; font.pixelSize: ui.font.bodySmall
                selectByMouse: true
                onEditingFinished: { var v = text; root.editGestures(function(l) { l[root.gestureIndex].mods = v }) }
                Text { textFormat: Text.PlainText; visible: !parent.text && !parent.activeFocus; text: "SUPER, ALT, CTRL"; color: root.faint; font: parent.font; anchors.verticalCenter: parent.verticalCenter }
              }
            }
            Text {
              textFormat: Text.PlainText
              visible: g && Model.actionNeedsArg(g.action)
              text: "Argument"; color: root.dim; font.family: root.fontFamily; font.pixelSize: ui.font.bodySmall; anchors.verticalCenter: parent.verticalCenter
            }
            Rectangle {
              visible: g && Model.actionNeedsArg(g.action)
              width: ui.space(250); height: ui.space(30); radius: ui.space(8)
              color: root.tint(root.fg, 0.03); border.width: 1; border.color: argInput.activeFocus ? root.accent : root.hairline
              TextInput {
                id: argInput
                anchors.fill: parent; anchors.leftMargin: ui.space(10); anchors.rightMargin: ui.space(10)
                verticalAlignment: TextInput.AlignVCenter
                text: g ? (g.arg || "") : ""
                color: root.fg; font.family: root.fontFamily; font.pixelSize: ui.font.bodySmall
                selectByMouse: true
                clip: true
                onEditingFinished: { var v = text; root.editGestures(function(l) { l[root.gestureIndex].arg = v }) }
                Text { textFormat: Text.PlainText; visible: !parent.text && !parent.activeFocus; text: g ? Model.argPlaceholder(g.action) : ""; color: root.faint; font: parent.font; anchors.verticalCenter: parent.verticalCenter }
              }
            }
          }
          Row {
            spacing: ui.space(12)
            Text { textFormat: Text.PlainText; text: "Distance"; color: root.dim; font.family: root.fontFamily; font.pixelSize: ui.font.bodySmall; anchors.verticalCenter: parent.verticalCenter; width: ui.space(72) }
            ValueSlider {
              implicitWidth: ui.space(300)
              from: 0.2; to: 3; stepSize: 0.05
              value: g ? g.scale : 1
              valueText: current.toFixed(2) + "×"
              onReleased: function(v) { root.editGestures(function(l) { l[root.gestureIndex].scale = v }) }
            }
            Text { textFormat: Text.PlainText; text: "Ignore inhibit"; color: root.dim; font.family: root.fontFamily; font.pixelSize: ui.font.bodySmall; anchors.verticalCenter: parent.verticalCenter }
            Switch {
              anchors.verticalCenter: parent.verticalCenter
              checked: !!(g && g.disable_inhibit)
              onToggled: root.editGestures(function(l) { l[root.gestureIndex].disable_inhibit = !l[root.gestureIndex].disable_inhibit })
            }
          }
        }
      }

      Row {
        spacing: ui.space(8)
        GhostButton { label: "Apply map"; glyph: ""; emphasis: root.gestureDirty; onActivated: root.applyGestures() }
        GhostButton {
          label: "Remove gesture"; glyph: ""; danger: true
          onActivated: {
            var i = root.gestureIndex
            root.editGestures(function(l) { l.splice(i, 1) })
            root.gestureIndex = Math.max(0, Math.min(i, root.gestureList.length - 1))
          }
        }
        GhostButton { visible: root.gestureDirty; label: "Discard changes"; onActivated: { root.gestureDraft = null; root.gestureDirty = false } }
      }
    }
  }

  // Icons: the dock's apps as tiles; the chosen one's replacements below.
  Component {
    id: iconEditor
    Column {
      id: ie
      spacing: ui.space(14)
      Component.onCompleted: root.iconsList()
      // A newly chosen app starts with a search for its own name -- from a
      // tile click or from the dock's Get Info alike. The list may arrive after
      // the choice (opened from the dock), so both changes are watched.
      property string seeded: ""
      function seed() {
        var a = root.iconApp
        if (!a || seeded === a.id) return
        seeded = a.id
        pickField.text = a.trash ? "trash" : String(a.name || "").toLowerCase()
        root.iconsSearch(pickField.text)
      }
      Connections {
        target: root
        function onIconSelChanged() { ie.seed() }
        function onIconAppsChanged() { ie.seed() }
        function onIconTrashChanged() { ie.seed() }
      }

      Text {
        visible: root.iconApps.length === 0
        width: parent.width; wrapMode: Text.WordWrap; textFormat: Text.PlainText
        text: "No dock apps yet. The list comes from the running dock -- open the dock once, then come back."
        color: root.dim; font.family: root.fontFamily; font.pixelSize: ui.font.bodySmall
      }

      Flow {
        width: parent.width
        spacing: ui.space(8)
        Repeater {
          model: root.iconApps
          Rectangle {
            required property var modelData
            readonly property bool sel: modelData.id === root.iconSel
            width: ui.space(84); height: ui.space(86)
            radius: ui.space(12)
            color: sel ? root.tint(root.accent, 0.18) : (appArea.containsMouse ? root.tint(root.fg, 0.07) : root.raised)
            border.width: 1
            border.color: sel ? root.accent : root.hairline
            Behavior on color { ColorAnimation { duration: root.quick } }
            IconPic { anchors.horizontalCenter: parent.horizontalCenter; y: ui.space(10); src: modelData.shown }
            Rectangle {
              visible: modelData.override !== ""
              width: ui.space(8); height: width; radius: width / 2; color: root.accent
              anchors.right: parent.right; anchors.top: parent.top; anchors.margins: ui.space(7)
            }
            Text {
              anchors.bottom: parent.bottom; anchors.bottomMargin: ui.space(9)
              anchors.horizontalCenter: parent.horizontalCenter
              width: parent.width - ui.space(10); horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideRight; textFormat: Text.PlainText
              text: modelData.name; color: parent.sel ? root.fg : root.dim
              font.family: root.fontFamily; font.pixelSize: ui.font.caption
            }
            MouseArea {
              id: appArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
              onClicked: root.iconSel = modelData.id
            }
          }
        }
      }

      // The Trash: one picture per state, empty or full, on a dark dock or a
      // light one -- the dock picks the state; each can be changed alone.
      Column {
        visible: root.iconTrash.length > 0
        width: parent.width
        spacing: ui.space(6)
        Text {
          textFormat: Text.PlainText
          text: "Trash -- one icon for each state. The dock shows the one that matches: empty or full, on a dark dock or a light one."
          width: parent.width; wrapMode: Text.WordWrap
          color: root.dim; font.family: root.fontFamily; font.pixelSize: ui.font.caption
        }
        Flow {
          width: parent.width
          spacing: ui.space(8)
          Repeater {
            model: root.iconTrash
            Rectangle {
              required property var modelData
              readonly property bool sel: modelData.id === root.iconSel
              readonly property bool lightDock: modelData.id.indexOf("-light") > 0
              width: ui.space(104); height: ui.space(86)
              radius: ui.space(12)
              // The tile wears the dock's shade for that state, so a light-dock
              // picture is judged on a light background.
              color: lightDock ? "#e8e8ea" : "#18181b"
              border.width: sel ? 2 : 1
              border.color: sel ? root.accent : (trashArea.containsMouse ? root.tint(root.fg, 0.3) : root.hairline)
              IconPic { anchors.horizontalCenter: parent.horizontalCenter; y: ui.space(10); src: modelData.shown }
              Rectangle {
                visible: modelData.override !== ""
                width: ui.space(8); height: width; radius: width / 2; color: root.accent
                anchors.right: parent.right; anchors.top: parent.top; anchors.margins: ui.space(7)
              }
              Text {
                anchors.bottom: parent.bottom; anchors.bottomMargin: ui.space(9)
                anchors.horizontalCenter: parent.horizontalCenter
                width: parent.width - ui.space(10); horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight; textFormat: Text.PlainText
                text: modelData.name; color: parent.lightDock ? "#3f3f46" : "#d4d4d8"
                font.family: root.fontFamily; font.pixelSize: ui.font.caption
              }
              MouseArea { id: trashArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.iconSel = modelData.id }
            }
          }
        }
      }

      // The chosen app: what it has now, and where to find another.
      Rectangle {
        visible: root.iconApp !== null
        width: parent.width
        height: pickCol.implicitHeight + ui.space(28)
        radius: ui.space(10)
        color: root.raised
        border.width: 1
        border.color: root.hairline
        Column {
          id: pickCol
          anchors.fill: parent
          anchors.margins: ui.space(14)
          spacing: ui.space(12)
          Row {
            spacing: ui.space(12)
            IconPic { src: root.iconApp ? root.iconApp.shown : ""; px: ui.space(44); anchors.verticalCenter: parent.verticalCenter }
            Column {
              anchors.verticalCenter: parent.verticalCenter
              spacing: ui.space(2)
              Text { textFormat: Text.PlainText; text: root.iconApp ? root.iconApp.name : ""; color: root.fg; font.family: root.fontFamily; font.pixelSize: ui.font.body }
              Text {
                textFormat: Text.PlainText
                text: root.iconApp && root.iconApp.override !== "" ? "Custom icon" : (root.iconApp && root.iconApp.trash ? "Hyprdrive's Trash" : "Its own icon")
                color: root.dim; font.family: root.fontFamily; font.pixelSize: ui.font.caption
              }
            }
            GhostButton {
              visible: root.iconApp !== null && root.iconApp.override !== ""
              anchors.verticalCenter: parent.verticalCenter
              label: "Reset"; glyph: ""
              onActivated: { var a = root.iconApp; root.iconsRun(["reset", a.id], true); root.showToast(a.trash ? "Trash · " + a.name + " is back to the default" : a.name + " has its own icon again") }
            }
          }
          Rectangle {
            width: parent.width; height: ui.space(34); radius: ui.space(8)
            color: root.tint(root.fg, 0.03); border.width: 1; border.color: pickField.activeFocus ? root.accent : root.hairline
            TextInput {
              id: pickField
              anchors.fill: parent; anchors.leftMargin: ui.space(12); anchors.rightMargin: ui.space(12)
              verticalAlignment: TextInput.AlignVCenter
              color: root.fg; font.family: root.fontFamily; font.pixelSize: ui.font.bodySmall
              selectByMouse: true
              onTextEdited: root.iconsSearch(text)
              Keys.onEscapePressed: function(e) { text = ""; root.iconsSearch(""); e.accepted = true }
              Text { textFormat: Text.PlainText; visible: !parent.text; text: "Search icons -- “firefox”, “terminal”, “mail”"; color: root.faint; font: parent.font; anchors.verticalCenter: parent.verticalCenter }
            }
          }
          Repeater {
            model: [
              { key: "theme", title: "Your icon theme" },
              { key: "folders", title: "Your folders" },
              { key: "selfhst", title: "selfh.st" }
            ]
            Column {
              required property var modelData
              readonly property var hits: root.iconResults[modelData.key] || []
              visible: hits.length > 0
              width: pickCol.width
              spacing: ui.space(6)
              Text { textFormat: Text.PlainText; text: modelData.title + " · " + hits.length; color: root.dim; font.family: root.fontFamily; font.pixelSize: ui.font.caption }
              Flow {
                width: parent.width
                spacing: ui.space(6)
                Repeater {
                  model: parent.parent.hits
                  Rectangle {
                    required property var modelData
                    width: ui.space(52); height: width; radius: ui.space(10)
                    color: hitArea.containsMouse ? root.tint(root.accent, 0.2) : root.tint(root.fg, 0.04)
                    border.width: 1; border.color: hitArea.containsMouse ? root.accent : "transparent"
                    IconPic { anchors.centerIn: parent; src: modelData.preview; px: ui.space(34) }
                    MouseArea {
                      id: hitArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                      onClicked: root.pickIcon(modelData.value, modelData.label)
                    }
                    // Its own tooltip with a PLAIN-text label: an attached
                    // ToolTip.text is AutoText, and a name from the selfh.st
                    // index or a file name in a folder is not ours to parse.
                    ToolTip {
                      visible: hitArea.containsMouse
                      delay: 400
                      contentItem: Text { textFormat: Text.PlainText; text: modelData.label; color: root.fg; font.family: root.fontFamily; font.pixelSize: ui.font.caption }
                      // The style's own background is white: the label (root.fg) vanished
                      // into it. Drawn like the dropdown cards instead.
                      background: Rectangle { radius: ui.space(6); color: root.mix(root.bg, root.fg, 0.07); border.width: 1; border.color: root.tint(root.fg, 0.14) }
                    }
                  }
                }
              }
            }
          }
          Text {
            visible: pickField.text.trim() !== "" && !root.iconSearching
                     && !(root.iconResults.theme || []).length && !(root.iconResults.folders || []).length && !(root.iconResults.selfhst || []).length
            textFormat: Text.PlainText; width: parent.width; wrapMode: Text.WordWrap
            text: "Nothing called that." + (root.iconSettings.selfhst ? "" : " Turn on selfh.st below for app logos.")
            color: root.dim; font.family: root.fontFamily; font.pixelSize: ui.font.caption
          }
          Text {
            visible: !!root.iconResults.selfhstError
            textFormat: Text.PlainText; text: root.iconResults.selfhstError || ""
            color: root.urgent; font.family: root.fontFamily; font.pixelSize: ui.font.caption
          }
        }
      }

      // Where icons come from.
      Row {
        spacing: ui.space(12)
        width: parent.width
        Switch {
          anchors.verticalCenter: parent.verticalCenter
          checked: root.iconSettings.selfhst
          onToggled: root.iconsConfig({ selfhst: !root.iconSettings.selfhst })
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - ui.space(60); wrapMode: Text.WordWrap; textFormat: Text.PlainText
          text: "selfh.st icons -- about 3,000 app logos. The list is downloaded from cdn.jsdelivr.net once a day and searched here; previews of the matches load from there too (so it can see which logos were shown), and picking one downloads it. Off, Hyprdrive never goes online for icons. Logos by selfh.st/icons, CC BY 4.0."
          color: root.dim; font.family: root.fontFamily; font.pixelSize: ui.font.caption
        }
      }
      Column {
        width: parent.width
        spacing: ui.space(6)
        Text { textFormat: Text.PlainText; text: "Your icon folders -- searched too. One per line, e.g. a downloaded icon pack."; color: root.dim; font.family: root.fontFamily; font.pixelSize: ui.font.caption }
        Rectangle {
          width: parent.width; height: Math.max(ui.space(34), dirsInput.contentHeight + ui.space(16)); radius: ui.space(8)
          color: root.tint(root.fg, 0.03); border.width: 1; border.color: dirsInput.activeFocus ? root.accent : root.hairline
          TextEdit {
            id: dirsInput
            anchors.fill: parent; anchors.margins: ui.space(8); anchors.leftMargin: ui.space(12)
            text: (root.iconSettings.dirs || []).join("\n")
            color: root.fg; font.family: root.fontFamily; font.pixelSize: ui.font.bodySmall
            selectByMouse: true; textFormat: TextEdit.PlainText
            onActiveFocusChanged: if (!activeFocus) {
              var dirs = text.split("\n").map(function(s) { return s.trim() }).filter(function(s) { return s !== "" })
              if (JSON.stringify(dirs) !== JSON.stringify(root.iconSettings.dirs || [])) root.iconsConfig({ dirs: dirs })
            }
            Text { textFormat: Text.PlainText; visible: !parent.text && !parent.activeFocus; text: "~/Pictures/icons"; color: root.faint; font: parent.font }
          }
        }
      }
    }
  }

  Component {
    id: powerControl
    Column {
      spacing: ui.space(12)
      readonly property string mode: root.hd.profileMode || "auto"
      Row {
        spacing: ui.space(12)
        Rectangle {
          width: ui.space(10); height: width; radius: width / 2
          anchors.verticalCenter: parent.verticalCenter
          color: root.onBattery ? root.urgent : root.accent
        }
        Text {
          textFormat: Text.PlainText
          text: (root.onBattery ? "On battery" : "On AC power") + " · " + (parent.parent.mode === "auto" ? "profiles follow the charger" : "profile forced")
          color: root.fg; font.family: root.fontFamily; font.pixelSize: ui.font.body
          anchors.verticalCenter: parent.verticalCenter
        }
      }
      Segmented {
        options: [{ value: "auto", label: "Auto" }, { value: "ac", label: "Always AC" }, { value: "battery", label: "Always battery" }]
        value: parent.mode
        onPicked: function(v) { root.runCtl(["profile-mode", v], true) }
      }
      Text {
        textFormat: Text.PlainText
        width: parent.width
        wrapMode: Text.WordWrap
        text: "Save what the panel is set to now as the AC or battery profile. In Auto, the matching one is applied when the charger is plugged in or pulled."
        color: root.dim; font.family: root.fontFamily; font.pixelSize: ui.font.caption
      }
      Row {
        spacing: ui.space(8)
        GhostButton { label: "Save as AC"; glyph: ""; onActivated: { root.runCtl(["profile-save", "ac"], true); root.showToast("Saved as the AC profile") } }
        GhostButton { label: "Save as battery"; glyph: ""; onActivated: { root.runCtl(["profile-save", "battery"], true); root.showToast("Saved as the battery profile") } }
        GhostButton { label: "Apply now"; glyph: ""; onActivated: { root.runCtl(["profile-apply", "auto"], true); root.showToast("Profile applied") } }
      }
    }
  }

  // ================================================================ window

  // NATIVE. No KeyboardPanel card: the window (shell.qml) is the card, and
  // this fills it. The page's own entrance (nav stagger, cards rising, the
  // brand mark) still plays off isOpen.
  Rectangle { anchors.fill: parent; color: root.bg }

  Item {
    id: panel
    anchors.fill: parent

    Item {
      id: keys
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(e) {
        var typing = searchField.activeFocus
        // The confirm owns the keyboard while it is up: Escape cancels,
        // Enter allows, and nothing else reaches the page behind it.
        if (confirmLayer.open) {
          if (e.key === Qt.Key_Escape) confirmLayer.cancel()
          else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) confirmLayer.allow()
          e.accepted = true; return
        }
        if (e.key === Qt.Key_Escape) {
          if (menuLayer.owner) menuLayer.close()
          else if (root.query !== "" || typing) { searchField.text = ""; keys.forceActiveFocus() }
          else if (root.host) root.host.close()
          e.accepted = true; return
        }
        // NATIVE. Tab moved between the shell's panels; a window has none, so
        // Ctrl+Tab / Ctrl+Shift+Tab step through the sections instead.
        if ((e.key === Qt.Key_Tab || e.key === Qt.Key_Backtab) && (e.modifiers & Qt.ControlModifier)) {
          var t = root.sectionIndex(root.section) + ((e.modifiers & Qt.ShiftModifier) || e.key === Qt.Key_Backtab ? -1 : 1)
          root.goTo(Schema.sections[(t + Schema.sections.length) % Schema.sections.length].id)
          e.accepted = true; return
        }
        if ((e.modifiers & Qt.ControlModifier) && e.key === Qt.Key_F) { searchField.forceActiveFocus(); e.accepted = true; return }
        if (typing) return
        if ((e.modifiers & Qt.AltModifier) && e.key >= Qt.Key_1 && e.key <= Qt.Key_9) {
          var n = e.key - Qt.Key_1
          if (n < Schema.sections.length) root.goTo(Schema.sections[n].id)
          e.accepted = true; return
        }
        if (e.key === Qt.Key_Up || e.key === Qt.Key_Down) {
          var i = root.sectionIndex(root.section) + (e.key === Qt.Key_Down ? 1 : -1)
          root.goTo(Schema.sections[(i + Schema.sections.length) % Schema.sections.length].id)
          e.accepted = true; return
        }
        // Typing anywhere starts a search.
        if (e.text && e.text.length === 1 && e.text >= " " && !(e.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) {
          searchField.forceActiveFocus()
          searchField.text = searchField.text + e.text
          e.accepted = true
        }
      }

      // --------------------------------------------------------- the rail
      Rectangle {
        id: rail
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: ui.space(232)
        // NATIVE. Square: the window's corners are the compositor's rounding,
        // and the panel's squaring strip over a translucent rail drew a
        // darker band down its edge.
        color: root.tint(root.fg, 0.03)
        Rectangle { anchors.right: parent.right; anchors.top: parent.top; anchors.bottom: parent.bottom; width: 1; color: root.hairline }

        // The brand: the mark, the name, the version.
        Item {
          id: brand
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.margins: ui.space(20)
          height: ui.space(56)

          Rectangle {
            id: markTile
            width: ui.space(44); height: width
            radius: ui.space(12)
            anchors.verticalCenter: parent.verticalCenter
            gradient: Gradient {
              orientation: Gradient.Vertical
              GradientStop { position: 0; color: root.mix(root.accent, root.fg, 0.18) }
              GradientStop { position: 1; color: root.mix(root.accent, root.bg, 0.28) }
            }
            scale: root.isOpen ? 1 : 0.6
            rotation: root.isOpen ? 0 : -12
            opacity: root.isOpen ? 1 : 0
            Behavior on scale { NumberAnimation { duration: root.slow; easing.type: Easing.OutBack; easing.overshoot: 1.8 } }
            Behavior on rotation { NumberAnimation { duration: root.slow; easing.type: Easing.OutCubic } }
            Behavior on opacity { NumberAnimation { duration: root.calm } }
            Image {
              id: markImg
              anchors.centerIn: parent
              width: parent.width * 0.62; height: width
              source: Qt.resolvedUrl("hyprdrive-icon.png")
              sourceSize: Qt.size(128, 128)
              smooth: true; mipmap: true
              visible: false
            }
            MultiEffect { anchors.fill: markImg; source: markImg; colorization: 1.0; colorizationColor: root.bg }
          }
          Column {
            anchors.left: markTile.right
            anchors.leftMargin: ui.space(12)
            anchors.verticalCenter: parent.verticalCenter
            spacing: ui.space(2)
            opacity: root.isOpen ? 1 : 0
            x: root.isOpen ? 0 : -ui.space(8)
            Behavior on opacity { NumberAnimation { duration: root.slow; easing.type: Easing.OutCubic } }
            Text {
              textFormat: Text.PlainText
              text: "Hyprdrive"
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: ui.font.heading + ui.space(3)
              font.weight: Font.Bold
              font.letterSpacing: -0.3
            }
            Rectangle {
              width: verText.implicitWidth + ui.space(12)
              height: ui.space(18)
              radius: ui.space(9)
              color: root.tint(root.accent, 0.16)
              visible: verText.text !== ""
              Text {
                textFormat: Text.PlainText
                id: verText
                anchors.centerIn: parent
                text: root.hd.version ? "v" + root.hd.version : ""
                color: root.accent
                font.family: root.fontFamily
                font.pixelSize: ui.font.caption
              }
            }
          }
        }

        // Find a setting.
        Rectangle {
          id: searchBox
          anchors.top: brand.bottom
          anchors.topMargin: ui.space(14)
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.leftMargin: ui.space(14)
          anchors.rightMargin: ui.space(14)
          height: ui.space(34)
          radius: ui.space(9)
          color: searchField.activeFocus ? root.tint(root.fg, 0.07) : root.tint(root.fg, 0.045)
          border.width: 1
          border.color: searchField.activeFocus ? root.tint(root.accent, 0.85) : root.hairline
          Behavior on border.color { ColorAnimation { duration: root.quick } }
          Text {
            textFormat: Text.PlainText
            id: searchGlyph
            anchors.left: parent.left
            anchors.leftMargin: ui.space(11)
            anchors.verticalCenter: parent.verticalCenter
            text: root.gl("", "")
            color: searchField.activeFocus ? root.accent : root.faint
            font.family: root.fontFamily
            font.pixelSize: ui.font.bodySmall
          }
          TextInput {
            id: searchField
            anchors.left: searchGlyph.right
            anchors.leftMargin: ui.space(9)
            anchors.right: parent.right
            anchors.rightMargin: ui.space(10)
            anchors.verticalCenter: parent.verticalCenter
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: ui.font.body
            clip: true
            selectByMouse: true
            onTextChanged: root.query = text
            Keys.onDownPressed: keys.forceActiveFocus()
            Text {
              textFormat: Text.PlainText
              visible: !parent.text
              text: "Find a setting"
              color: root.faint
              font: parent.font
              anchors.verticalCenter: parent.verticalCenter
            }
          }
        }

        // The sections. The highlight glides between them.
        Item {
          id: nav
          anchors.top: searchBox.bottom
          anchors.topMargin: ui.space(14)
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.leftMargin: ui.space(10)
          anchors.rightMargin: ui.space(10)
          height: navCol.implicitHeight

          Rectangle {
            id: navHighlight
            readonly property Item target: navRep.count > 0 && root.query === "" ? navRep.itemAt(root.sectionIndex(root.section)) : null
            visible: target !== null
            x: 0
            width: nav.width
            y: target ? target.y : 0
            height: target ? target.height : 0
            radius: ui.space(9)
            color: root.tint(root.accent, 0.16)
            Behavior on y { NumberAnimation { duration: root.calm + 40; easing.type: Easing.OutBack; easing.overshoot: 0.9 } }
            Rectangle {
              width: ui.space(3)
              height: parent.height * 0.5
              radius: width / 2
              anchors.left: parent.left
              anchors.leftMargin: ui.space(3)
              anchors.verticalCenter: parent.verticalCenter
              color: root.accent
            }
          }

          Column {
            id: navCol
            width: parent.width
            spacing: ui.space(2)
            Repeater {
              id: navRep
              model: Schema.sections
              Item {
                id: navItem
                required property var modelData
                required property int index
                readonly property bool active: root.query === "" && root.section === modelData.id
                width: navCol.width
                height: ui.space(38)
                opacity: root.isOpen ? 1 : 0
                transform: Translate {
                  x: root.isOpen ? 0 : -ui.space(14)
                  Behavior on x { SequentialAnimation { PauseAnimation { duration: 40 + navItem.index * 35 } NumberAnimation { duration: root.slow; easing.type: Easing.OutCubic } } }
                }
                Behavior on opacity { SequentialAnimation { PauseAnimation { duration: 40 + navItem.index * 35 } NumberAnimation { duration: root.calm; easing.type: Easing.OutCubic } } }

                Rectangle {
                  anchors.fill: parent
                  radius: ui.space(9)
                  color: navArea.containsMouse && !navItem.active ? root.tint(root.fg, 0.05) : "transparent"
                  Behavior on color { ColorAnimation { duration: root.quick } }
                }
                Text {
                  textFormat: Text.PlainText
                  id: navGlyph
                  anchors.left: parent.left
                  anchors.leftMargin: ui.space(16)
                  anchors.verticalCenter: parent.verticalCenter
                  width: ui.space(18)
                  horizontalAlignment: Text.AlignHCenter
                  text: root.gl(navItem.modelData.icon, "•")
                  color: navItem.active ? root.accent : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: ui.font.title
                  scale: navItem.active ? 1.08 : 1
                  Behavior on color { ColorAnimation { duration: root.quick } }
                  Behavior on scale { NumberAnimation { duration: root.calm; easing.type: Easing.OutBack } }
                }
                Text {
                  textFormat: Text.PlainText
                  id: navTitle
                  anchors.left: navGlyph.right
                  anchors.leftMargin: ui.space(12)
                  anchors.verticalCenter: parent.verticalCenter
                  text: navItem.modelData.title
                  color: navItem.active ? root.fg : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: ui.font.body
                  font.weight: navItem.active ? Font.DemiBold : Font.Normal
                  Behavior on color { ColorAnimation { duration: root.quick } }
                }
                // A section still finding its shape says so (Schema `experimental`).
                Rectangle {
                  visible: !!navItem.modelData.experimental
                  anchors.left: navTitle.right
                  anchors.leftMargin: ui.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                  width: navExp.implicitWidth + ui.space(10)
                  height: ui.space(16)
                  radius: ui.space(8)
                  color: root.tint(root.accent, 0.16)
                  Text {
                    textFormat: Text.PlainText
                    id: navExp
                    anchors.centerIn: parent
                    text: "Experimental"
                    color: root.accent
                    font.family: root.fontFamily
                    font.pixelSize: ui.font.caption - 1
                  }
                }
                Text {
                  textFormat: Text.PlainText
                  anchors.right: parent.right
                  anchors.rightMargin: ui.space(12)
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Alt " + (navItem.index + 1)
                  color: root.faint
                  font.family: root.fontFamily
                  font.pixelSize: ui.font.caption
                  opacity: navArea.containsMouse ? 1 : 0
                  Behavior on opacity { NumberAnimation { duration: root.quick } }
                }
                MouseArea {
                  id: navArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.goTo(navItem.modelData.id)
                }
              }
            }
          }
        }

        // SEND FEEDBACK (user, 2026-10-11): always in view, right above the
        // signature. GitHub's issue form for Hyprdrive, with this install's
        // version already filled in -- a bug, an idea, anything.
        Rectangle {
          id: feedbackRow
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: signature.top
          anchors.leftMargin: ui.space(14)
          anchors.rightMargin: ui.space(14)
          anchors.bottomMargin: ui.space(2)
          height: ui.space(36)
          radius: ui.space(10)
          color: fbArea.containsMouse ? root.tint(root.accent, 0.16) : "transparent"
          Behavior on color { ColorAnimation { duration: root.quick } }
          Text {
            textFormat: Text.PlainText
            id: fbGlyph
            anchors.left: parent.left
            anchors.leftMargin: ui.space(14)
            anchors.verticalCenter: parent.verticalCenter
            width: ui.space(18)
            horizontalAlignment: Text.AlignHCenter
            text: root.gl("\uf0e6", "\u2022")
            color: fbArea.containsMouse ? root.accent : root.dim
            font.family: root.fontFamily
            font.pixelSize: ui.font.title
          }
          Text {
            textFormat: Text.PlainText
            anchors.left: fbGlyph.right
            anchors.leftMargin: ui.space(12)
            anchors.verticalCenter: parent.verticalCenter
            text: "Send feedback"
            color: fbArea.containsMouse ? root.fg : root.dim
            font.family: root.fontFamily
            font.pixelSize: ui.font.body
          }
          MouseArea {
            id: fbArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              Qt.openUrlExternally(Schema.feedbackUrl + (root.hd.version ? "&version=" + encodeURIComponent(root.hd.version) : ""))
            }
          }
        }

        // By dragosol, with the links behind it.
        Item {
          id: signature
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          anchors.margins: ui.space(14)
          height: ui.space(40)
          readonly property bool hot: sigArea.containsMouse || linksHover.hovered
          onHotChanged: if (hot) linksGrace.stop(); else linksGrace.restart()
          property bool revealed: false
          // Revealed by this very arrival of the pointer: a click that comes
          // with the arrival (a quick move-and-click) then keeps the links up
          // instead of toggling them straight back off.
          property bool hoverRevealed: false
          Timer { id: linksGrace; interval: 260; onTriggered: signature.revealed = false }
          onRevealedChanged: if (!revealed) linksGrace.stop()

          Rectangle {
            anchors.fill: parent
            radius: ui.space(10)
            color: signature.revealed ? root.tint(root.fg, 0.06) : "transparent"
            Behavior on color { ColorAnimation { duration: root.quick } }
          }
          Rectangle {
            id: avatar
            width: ui.space(26); height: width; radius: width / 2
            anchors.left: parent.left
            anchors.leftMargin: ui.space(8)
            anchors.verticalCenter: parent.verticalCenter
            gradient: Gradient {
              GradientStop { position: 0; color: root.mix(root.accent, root.fg, 0.25) }
              GradientStop { position: 1; color: root.mix(root.accent, root.bg, 0.35) }
            }
            Text { textFormat: Text.PlainText; anchors.centerIn: parent; text: "d"; color: root.bg; font.family: root.fontFamily; font.pixelSize: ui.font.body; font.weight: Font.Bold }
          }
          Row {
            anchors.left: avatar.right
            anchors.leftMargin: ui.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: ui.space(5)
            Text { textFormat: Text.PlainText; text: "by"; color: root.dim; font.family: root.fontFamily; font.pixelSize: ui.font.body }
            Text { textFormat: Text.PlainText; text: "dragosol"; color: root.fg; font.family: root.fontFamily; font.pixelSize: ui.font.body; font.weight: Font.DemiBold }
          }
          Text {
            textFormat: Text.PlainText
            anchors.right: parent.right
            anchors.rightMargin: ui.space(10)
            anchors.verticalCenter: parent.verticalCenter
            text: root.gl("", "▴")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: ui.font.bodySmall
            rotation: signature.revealed ? 0 : 180
            Behavior on rotation { NumberAnimation { duration: root.calm; easing.type: Easing.OutCubic } }
          }
          MouseArea {
            id: sigArea
            anchors.fill: parent
            hoverEnabled: true
            onEntered: if (!signature.revealed) { signature.revealed = true; signature.hoverRevealed = true }
            onExited: signature.hoverRevealed = false
            onClicked: {
              if (signature.hoverRevealed) signature.hoverRevealed = false
              else signature.revealed = !signature.revealed
            }
          }

          // The links card rises out of the signature.
          Rectangle {
            id: linksCard
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.top
            anchors.bottomMargin: ui.space(8)
            height: linksCol.implicitHeight + ui.space(12)
            radius: ui.space(12)
            color: root.mix(root.bg, root.fg, 0.06)
            border.width: 1
            border.color: root.tint(root.fg, 0.12)
            visible: opacity > 0.01
            opacity: signature.revealed ? 1 : 0
            transform: [
              Translate { y: signature.revealed ? 0 : ui.space(10) ; Behavior on y { NumberAnimation { duration: root.calm; easing.type: Easing.OutCubic } } },
              Scale { origin.x: linksCard.width / 2; origin.y: linksCard.height; xScale: signature.revealed ? 1 : 0.94; yScale: xScale
                      Behavior on xScale { NumberAnimation { duration: root.calm; easing.type: Easing.OutBack } } }
            ]
            Behavior on opacity { NumberAnimation { duration: root.quick; easing.type: Easing.OutCubic } }
            HoverHandler { id: linksHover }

            Column {
              id: linksCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: ui.space(6)
              spacing: ui.space(2)
              Repeater {
                model: Schema.links
                Rectangle {
                  id: linkRow
                  required property var modelData
                  required property int index
                  width: linksCol.width
                  height: ui.space(40)
                  radius: ui.space(8)
                  color: linkArea.containsMouse ? root.tint(root.accent, 0.16) : "transparent"
                  Behavior on color { ColorAnimation { duration: root.quick } }
                  opacity: signature.revealed ? 1 : 0
                  Behavior on opacity { SequentialAnimation { PauseAnimation { duration: signature.revealed ? 30 + linkRow.index * 45 : 0 } NumberAnimation { duration: root.quick } } }
                  Text {
                    textFormat: Text.PlainText
                    id: linkGlyph
                    anchors.left: parent.left
                    anchors.leftMargin: ui.space(10)
                    anchors.verticalCenter: parent.verticalCenter
                    width: ui.space(18)
                    horizontalAlignment: Text.AlignHCenter
                    text: root.gl(linkRow.modelData.icon, "•")
                    color: linkArea.containsMouse ? root.accent : root.fg
                    font.family: root.fontFamily
                    font.pixelSize: ui.font.title
                  }
                  Column {
                    anchors.left: linkGlyph.right
                    anchors.leftMargin: ui.space(10)
                    anchors.right: linkArrow.left
                    anchors.rightMargin: ui.space(6)
                    anchors.verticalCenter: parent.verticalCenter
                    // Bounded and elided: a long handle must never run out of the card.
                    Text { textFormat: Text.PlainText; width: parent.width; elide: Text.ElideRight; text: linkRow.modelData.label; color: root.fg; font.family: root.fontFamily; font.pixelSize: ui.font.bodySmall }
                    Text { textFormat: Text.PlainText; width: parent.width; elide: Text.ElideRight; text: linkRow.modelData.detail; color: root.dim; font.family: root.fontFamily; font.pixelSize: ui.font.caption }
                  }
                  Text {
                    textFormat: Text.PlainText
                    id: linkArrow
                    anchors.right: parent.right
                    anchors.rightMargin: ui.space(10)
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.gl("", "↗")
                    color: root.faint
                    font.family: root.fontFamily
                    font.pixelSize: ui.font.caption
                    opacity: linkArea.containsMouse ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: root.quick } }
                  }
                  MouseArea {
                    id: linkArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      Qt.openUrlExternally(linkRow.modelData.url)
                    }
                  }
                }
              }
            }
          }
        }
      }

      // --------------------------------------------------------- the page
      Item {
        id: page
        anchors.left: rail.right
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        clip: true

        property real slide: 0
        opacity: 1

        SequentialAnimation {
          id: pageSwap
          NumberAnimation { target: page; property: "opacity"; to: 0; duration: 90; easing.type: Easing.InCubic }
          ScriptAction {
            script: {
              root.shownSection = root.section
              flick.contentY = 0
              page.slide = ui.space(18) * root.navDirection
            }
          }
          ParallelAnimation {
            NumberAnimation { target: page; property: "opacity"; to: 1; duration: root.calm; easing.type: Easing.OutCubic }
            NumberAnimation { target: page; property: "slide"; to: 0; duration: root.slow; easing.type: Easing.OutCubic }
          }
        }

        // Title, subtitle, restore defaults.
        Item {
          id: pageHead
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.leftMargin: ui.space(30)
          anchors.rightMargin: ui.space(26)
          anchors.topMargin: ui.space(24)
          height: ui.space(58)
          transform: Translate { y: page.slide * 0.5 }

          Column {
            anchors.left: parent.left
            anchors.right: restore.left
            anchors.rightMargin: ui.space(16)
            anchors.verticalCenter: parent.verticalCenter
            spacing: ui.space(4)
            Row {
              spacing: ui.space(10)
              Text {
                textFormat: Text.PlainText
                text: root.query !== "" ? "Results" : root.shownSectionData.title
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: ui.font.display
                font.weight: Font.Bold
                font.letterSpacing: -0.4
              }
              Rectangle {
                visible: root.query === "" && !!root.shownSectionData.experimental
                anchors.verticalCenter: parent.verticalCenter
                width: pageExp.implicitWidth + ui.space(14)
                height: ui.space(20)
                radius: ui.space(10)
                color: root.tint(root.accent, 0.16)
                Text {
                  textFormat: Text.PlainText
                  id: pageExp
                  anchors.centerIn: parent
                  text: "Experimental"
                  color: root.accent
                  font.family: root.fontFamily
                  font.pixelSize: ui.font.caption
                }
              }
            }
            Text {
              textFormat: Text.PlainText
              width: parent.width
              elide: Text.ElideRight
              text: root.query !== ""
                ? (root.searchCards.length ? "Settings matching “" + root.query + "”" : "Nothing matches “" + root.query + "”")
                : root.shownSectionData.subtitle
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: ui.font.body
            }
          }

          // Restore defaults: one click arms it, the second restores.
          GhostButton {
            id: restore
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: root.query === ""
            property bool armed: false
            glyph: ""
            label: armed ? "Click again to restore" : "Restore defaults"
            emphasis: armed
            onActivated: {
              if (!armed) { armed = true; disarm.restart(); return }
              armed = false
              root.restoreSection(root.shownSectionData)
            }
            Timer { id: disarm; interval: 4000; onTriggered: restore.armed = false }
            Connections { target: root; function onShownSectionChanged() { restore.armed = false } }
          }
        }

        Flickable {
          id: flick
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: pageHead.bottom
          anchors.bottom: parent.bottom
          anchors.topMargin: ui.space(12)
          contentWidth: width
          contentHeight: cardsCol.implicitHeight + ui.space(40)
          boundsBehavior: Flickable.StopAtBounds
          clip: true
          ScrollBar.vertical: ScrollBar {
            policy: flick.contentHeight > flick.height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
            // NATIVE. A drag on it is a pointer gesture, never a keyboard target.
            focusPolicy: Qt.NoFocus
            contentItem: Rectangle { implicitWidth: ui.space(4); radius: 2; color: root.tint(root.fg, 0.25) }
          }

          Column {
            id: cardsCol
            x: ui.space(30)
            width: flick.width - ui.space(56)
            spacing: ui.space(16)
            transform: Translate { y: page.slide }

            Repeater {
              model: root.pageCards
              Item {
                id: cardItem
                required property var modelData
                required property int index
                width: cardsCol.width
                height: cardBody.height + cardTitle.height + ui.space(8)

                // Staggered entrance each time the page is rebuilt.
                opacity: 0
                property real rise: ui.space(10)
                Component.onCompleted: cardIn.start()
                ParallelAnimation {
                  id: cardIn
                  SequentialAnimation {
                    PauseAnimation { duration: 30 + cardItem.index * 45 }
                    ParallelAnimation {
                      NumberAnimation { target: cardItem; property: "opacity"; to: 1; duration: root.calm; easing.type: Easing.OutCubic }
                      NumberAnimation { target: cardItem; property: "rise"; to: 0; duration: root.slow; easing.type: Easing.OutCubic }
                    }
                  }
                }
                transform: Translate { y: cardItem.rise }

                Row {
                  id: cardTitle
                  spacing: ui.space(8)
                  height: ui.space(22)
                  Text {
                    textFormat: Text.PlainText
                    text: cardItem.modelData.title.toUpperCase()
                    color: root.faint
                    font.family: root.fontFamily
                    font.pixelSize: ui.font.caption
                    font.weight: Font.DemiBold
                    font.letterSpacing: 1.2
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  // In search results, a way back to where the setting lives.
                  Text {
                    textFormat: Text.PlainText
                    visible: root.query !== "" && !!cardItem.modelData.section
                    text: root.glyphs ? "Open " : "Open →"
                    color: root.accent
                    font.family: root.fontFamily
                    font.pixelSize: ui.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                    MouseArea { anchors.fill: parent; anchors.margins: -ui.space(4); cursorShape: Qt.PointingHandCursor; onClicked: root.goTo(cardItem.modelData.section) }
                  }
                }

                Rectangle {
                  id: cardBody
                  anchors.top: cardTitle.bottom
                  anchors.topMargin: ui.space(8)
                  width: parent.width
                  height: rowsCol.implicitHeight + ui.space(8)
                  radius: root.radius
                  color: root.raised
                  border.width: 1
                  border.color: root.hairline

                  Column {
                    id: rowsCol
                    x: ui.space(18)
                    y: ui.space(4)
                    width: parent.width - ui.space(36)
                    Repeater {
                      model: cardItem.modelData.rows
                      SettingRow {
                        required property var modelData
                        required property int index
                        row: modelData
                        first: index === 0
                      }
                    }
                  }
                }
              }
            }

            // Search found nothing: say so, softly.
            Item {
              visible: root.query !== "" && root.searchCards.length === 0
              width: parent.width
              height: ui.space(160)
              Column {
                anchors.centerIn: parent
                spacing: ui.space(8)
                Text { textFormat: Text.PlainText; anchors.horizontalCenter: parent.horizontalCenter; text: root.gl("", ""); color: root.faint; font.family: root.fontFamily; font.pixelSize: ui.font.display }
                Text { textFormat: Text.PlainText; anchors.horizontalCenter: parent.horizontalCenter; text: "Try “blur”, “dock” or “speed”"; color: root.dim; font.family: root.fontFamily; font.pixelSize: ui.font.body }
              }
            }
          }
        }

        // Toast.
        Rectangle {
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.bottom: parent.bottom
          anchors.bottomMargin: root.toastText !== "" ? ui.space(18) : ui.space(4)
          width: toastRow.implicitWidth + ui.space(28)
          height: ui.space(34)
          radius: height / 2
          color: root.mix(root.bg, root.fg, 0.12)
          border.width: 1
          border.color: root.tint(root.accent, 0.5)
          opacity: root.toastText !== "" ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: root.calm; easing.type: Easing.OutCubic } }
          Behavior on anchors.bottomMargin { NumberAnimation { duration: root.calm; easing.type: Easing.OutBack } }
          Row {
            id: toastRow
            anchors.centerIn: parent
            spacing: ui.space(8)
            Text { textFormat: Text.PlainText; text: root.gl("", "✓"); color: root.accent; font.family: root.fontFamily; font.pixelSize: ui.font.bodySmall; anchors.verticalCenter: parent.verticalCenter }
            Text { textFormat: Text.PlainText; text: root.toastText; color: root.fg; font.family: root.fontFamily; font.pixelSize: ui.font.bodySmall; anchors.verticalCenter: parent.verticalCenter }
          }
        }

        // Working: a thin line along the page's top edge while hdpanel runs.
        Rectangle {
          anchors.top: parent.top
          height: ui.space(2)
          width: parent.width * 0.25
          color: root.accent
          radius: 1
          visible: root.ctlBusy
          SequentialAnimation on x {
            running: root.ctlBusy
            loops: Animation.Infinite
            NumberAnimation { from: -page.width * 0.25; to: page.width; duration: 900; easing.type: Easing.InOutCubic }
          }
        }
      }

      // ------------------------------------------------------ the dropdowns
      Item {
        id: menuLayer
        anchors.fill: parent
        z: 50
        visible: owner !== null
        property Item owner: null
        property var options: []
        property string value: ""
        property string kind: "plain"
        property var onPick: null

        function openFor(item, options, value, kind, onPick) {
          if (owner === item) { close(); return }
          owner = item
          menuLayer.options = options
          menuLayer.value = value
          menuLayer.kind = kind
          menuLayer.onPick = onPick
          menu.width = Math.max(item.width, kind === "curve" ? ui.space(260) : ui.space(180))
          menuFlick.contentY = 0
          var p = item.mapToItem(menuLayer, 0, item.height + ui.space(6))
          var h = menu.height
          menu.x = Math.max(ui.space(10), Math.min(p.x, menuLayer.width - menu.width - ui.space(10)))
          menu.y = p.y + h > menuLayer.height - ui.space(10) ? Math.max(ui.space(10), item.mapToItem(menuLayer, 0, 0).y - h - ui.space(6)) : p.y
          menuIn.restart()
        }
        function close() { owner = null }
        // The list's height, from the options themselves. menuList.implicitHeight
        // is the Column's last layout, and the Column lays out the new rows only
        // after openFor has placed the card -- so a menu opened right after a
        // shorter one was placed with the shorter one's height and ran off the
        // window (the 18 gesture actions after a 5-item fade menu).
        readonly property real rowHeight: kind === "curve" ? ui.space(46) : ui.space(32)
        readonly property real listHeight: options.length * rowHeight + Math.max(0, options.length - 1) * menuList.spacing

        MouseArea { anchors.fill: parent; onClicked: menuLayer.close() }

        Rectangle {
          id: menu
          height: Math.min(menuLayer.listHeight + ui.space(12), menuLayer.height - ui.space(20))
          radius: ui.space(10)
          color: root.mix(root.bg, root.fg, 0.07)
          border.width: 1
          border.color: root.tint(root.fg, 0.14)
          clip: true
          transformOrigin: Item.Top
          ParallelAnimation {
            id: menuIn
            NumberAnimation { target: menu; property: "opacity"; from: 0; to: 1; duration: root.quick; easing.type: Easing.OutCubic }
            NumberAnimation { target: menu; property: "scale"; from: 0.94; to: 1; duration: root.calm; easing.type: Easing.OutBack }
          }
          Flickable {
            id: menuFlick
            anchors.fill: parent
            anchors.margins: ui.space(6)
            contentHeight: menuLayer.listHeight
            boundsBehavior: Flickable.StopAtBounds
            clip: true
            Column {
              id: menuList
              width: parent.width
              spacing: ui.space(1)
              Repeater {
                model: menuLayer.options
                Rectangle {
                  id: opt
                  required property var modelData
                  readonly property bool sel: modelData.value === menuLayer.value
                  width: menuList.width
                  height: menuLayer.rowHeight
                  radius: ui.space(7)
                  color: optArea.containsMouse ? root.tint(root.accent, 0.18) : (sel ? root.tint(root.fg, 0.06) : "transparent")
                  Behavior on color { ColorAnimation { duration: root.quick } }
                  CurveGlyph {
                    id: optCurve
                    visible: menuLayer.kind === "curve"
                    anchors.left: parent.left
                    anchors.leftMargin: ui.space(10)
                    anchors.verticalCenter: parent.verticalCenter
                    width: ui.space(38); height: ui.space(32)
                    points: opt.modelData.decel || [0, 0, 1, 1]
                    stroke: opt.sel || optArea.containsMouse ? root.accent : root.dim
                    lineWidth: ui.space(1.6)
                  }
                  Column {
                    anchors.left: menuLayer.kind === "curve" ? optCurve.right : parent.left
                    anchors.leftMargin: ui.space(10)
                    anchors.verticalCenter: parent.verticalCenter
                    Text { textFormat: Text.PlainText; text: opt.modelData.label || opt.modelData.value; color: root.fg; font.family: root.fontFamily; font.pixelSize: ui.font.bodySmall; font.weight: opt.sel ? Font.DemiBold : Font.Normal }
                    Text { textFormat: Text.PlainText; visible: !!opt.modelData.note; text: opt.modelData.note || ""; color: root.dim; font.family: root.fontFamily; font.pixelSize: ui.font.caption }
                  }
                  Text {
                    textFormat: Text.PlainText
                    anchors.right: parent.right
                    anchors.rightMargin: ui.space(10)
                    anchors.verticalCenter: parent.verticalCenter
                    visible: opt.sel
                    text: root.gl("", "✓")
                    color: root.accent
                    font.family: root.fontFamily
                    font.pixelSize: ui.font.caption
                  }
                  MouseArea {
                    id: optArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      var cb = menuLayer.onPick
                      var v = opt.modelData.value
                      menuLayer.close()
                      if (cb) cb(v)
                    }
                  }
                }
              }
            }
          }
        }
      }

      // ------------------------------------------------------- the confirm
      // A question before a row changes something outside hyprdrive (a row's
      // `confirm` in Schema.js). Only Allow runs the change; Cancel, Escape
      // or a click outside the card leave everything as it was. Drawn like
      // the dropdowns, over a dimmed panel.
      Item {
        id: confirmLayer
        anchors.fill: parent
        z: 60
        property var spec: null
        property var onAllow: null
        // What the card shows. Kept after a close so the text does not
        // blank out while the card fades.
        property var shown: ({})
        readonly property bool open: spec !== null
        visible: open || card.opacity > 0.01

        function ask(s, cb) {
          shown = s
          onAllow = cb
          spec = s
        }
        function cancel() { spec = null; onAllow = null }
        function allow() {
          var cb = onAllow
          cancel()
          if (cb) cb()
        }

        Rectangle {
          anchors.fill: parent
          radius: root.radius
          color: root.tint(root.bg, 0.6)
          opacity: confirmLayer.open ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: root.calm; easing.type: Easing.OutCubic } }
        }
        MouseArea { anchors.fill: parent; hoverEnabled: true; onClicked: confirmLayer.cancel() }

        Rectangle {
          id: card
          anchors.centerIn: parent
          width: Math.min(ui.space(440), parent.width - ui.space(60))
          height: cardCol.implicitHeight + ui.space(44)
          radius: ui.space(14)
          color: root.mix(root.bg, root.fg, 0.07)
          border.width: 1
          border.color: root.tint(root.fg, 0.14)
          opacity: confirmLayer.open ? 1 : 0
          scale: confirmLayer.open ? 1 : 0.94
          Behavior on opacity { NumberAnimation { duration: root.quick; easing.type: Easing.OutCubic } }
          Behavior on scale { NumberAnimation { duration: root.calm; easing.type: Easing.OutBack } }
          // Clicks on the card itself are not a click outside it.
          MouseArea { anchors.fill: parent }

          Column {
            id: cardCol
            x: ui.space(22)
            y: ui.space(22)
            width: parent.width - ui.space(44)
            spacing: ui.space(10)

            Rectangle {
              visible: root.glyphs && !!confirmLayer.shown.glyph
              width: ui.space(40); height: width
              radius: ui.space(11)
              color: root.tint(root.accent, 0.16)
              Text {
                textFormat: Text.PlainText
                anchors.centerIn: parent
                text: confirmLayer.shown.glyph || ""
                color: root.accent
                font.family: root.fontFamily
                font.pixelSize: ui.font.body
              }
            }
            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: confirmLayer.shown.title || ""
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: ui.font.body
              font.weight: Font.DemiBold
              wrapMode: Text.WordWrap
            }
            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: !!confirmLayer.shown.body
              text: confirmLayer.shown.body || ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: ui.font.bodySmall
              wrapMode: Text.WordWrap
              lineHeight: 1.2
            }
            Item { width: 1; height: ui.space(4) }
            Row {
              anchors.right: parent.right
              spacing: ui.space(8)
              GhostButton { label: confirmLayer.shown.cancel || "Cancel"; onActivated: confirmLayer.cancel() }
              GhostButton { label: confirmLayer.shown.allow || "Allow"; emphasis: true; onActivated: confirmLayer.allow() }
            }
          }
        }
      }
    }
  }
}
