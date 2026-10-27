#!/usr/bin/env python3
"""The standalone settings app (settings/) and hdpanel's native paths, checked
without a compositor (native port B1, A18-A20). Part of `make check`.

  - settings/ imports nothing from the Omarchy shell (qs.Commons / qs.Ui) and
    its Schema.js / Model.js / mark are the panel's own files (symlinks), so
    the two front ends cannot drift: Quickshell refuses imports from outside the
    app's directory, which is why they are links and not ../ imports;
  - hdpanel, Omarchy forced: animation leaves and Mosaic binds are what they
    were before the port (the same lines, Mosaic's inside hyprdrive_omarchy());
  - hdpanel, plain Hyprland: no chord is taken by "auto", an explicit chord is,
    "none" takes nothing; animations come back from the user's own snapshot,
    with a vanished curve falling back to `default`, and with no snapshot a
    reload is asked for instead of Omarchy's curves;
  - the hyprdrive-settings launcher on Omarchy: the panel when the Omarchy
    shell answers, the standalone app when it does not.
"""
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import importlib.util
from importlib.machinery import SourceFileLoader

ROOT = pathlib.Path(__file__).resolve().parent.parent
fails = 0


def check(name, ok, detail=""):
    global fails
    print("%-58s %s" % (name, "ok" if ok else "FAIL " + detail))
    if not ok:
        fails += 1


# ---------------------------------------------------------------- the app
for qml in sorted((ROOT / "settings").glob("*.qml")):
    text = qml.read_text()
    check("%s: no Omarchy shell imports" % qml.name, not re.search(r"^\s*import\s+qs\.", text, re.M))
    check("%s: no ../ imports (Quickshell blackholes them)" % qml.name, not re.search(r'^\s*import\s+"\.\./', text, re.M))
for f in ("Schema.js", "Model.js", "hyprdrive-icon.png"):
    p = ROOT / "settings" / f
    check("settings/%s is the panel's file" % f,
          p.is_symlink() and p.resolve() == (ROOT / "omarchy-plugin" / f).resolve())

# Every row type and condition the panel renders, the app renders too.
panel = (ROOT / "omarchy-plugin" / "HyprdrivePanel.qml").read_text()
app = (ROOT / "settings" / "SettingsPage.qml").read_text()
for kind in sorted(set(re.findall(r'case "(\w+)": return \w+Control', panel))):
    check("row type %s handled" % kind, ('case "%s": return' % kind) in app)
for cond in sorted(set(re.findall(r'case "(\w+)": return k', panel))):
    check("condition %s handled" % cond, ('case "%s": return' % cond) in app)


# ---------------------------------------------------------------- hdpanel
def load(integration):
    os.environ.pop("HYPRDRIVE_NO_OMARCHY", None)
    os.environ["HYPRDRIVE_INTEGRATION"] = integration
    # No compositor: hyprctl() must find nothing rather than a real session.
    os.environ["XDG_RUNTIME_DIR"] = tempfile.mkdtemp()
    os.environ["HYPRLAND_INSTANCE_SIGNATURE"] = "none"
    os.environ["PATH"] = "/nonexistent"  # no hyprdrive-integration CLI either
    # load_module() is gone in newer Pythons: spec + exec_module instead.
    loader = SourceFileLoader("hdpanel_" + integration, str(ROOT / "omarchy-plugin" / "bin" / "hdpanel"))
    m = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
    loader.exec_module(m)
    m.LAYOUT_CYCLE = pathlib.Path("/x/hd-layout-cycle")
    return m


path_save = os.environ.get("PATH", "")
om = load("omarchy")
check("integration forced omarchy", om.integration() == "omarchy")
off, _ = om.compositor_anim_lua(False, {})
on, restored = om.compositor_anim_lua(True, {})
check("omarchy: off disables Omarchy's leaves + windowsMove",
      all("leaf = '%s', enabled = false" % l[0] in off for l in om.OMARCHY_ANIM_LEAVES) and "windowsMove" in off)
check("omarchy: on restores looknfeel's curves", restored and "easeOutQuint" in on and "popin 87%" in on)
lines = "\n".join(om.mosaic_lua({"keys": {om.MOSAIC_ON: True}}))
check("omarchy: auto = Super+L + Super+arrows, under hyprdrive_omarchy()",
      "if hyprdrive_omarchy and hyprdrive_omarchy() then" in lines and "hl.unbind('SUPER + L')" in lines and "SUPER + LEFT" in lines)

na = load("none")
check("integration forced none", na.integration() == "none")
lines = "\n".join(na.mosaic_lua({"keys": {na.MOSAIC_ON: True, na.MOSAIC_CYCLE: "none", na.MOSAIC_FOCUS: "none"}}))
check("none: chords 'none' bind nothing", "hl.bind(" not in lines and "hl.unbind(" not in lines)
lines = na.mosaic_lua({"keys": {na.MOSAIC_ON: True, na.MOSAIC_CYCLE: "SUPER + M", na.MOSAIC_FOCUS: "SUPER + ALT"}})
txt = "\n".join(lines)
check("none: an explicit chord is bound unguarded",
      "hl.unbind('SUPER + M')" in txt and "'SUPER + ALT + LEFT'" in txt and "hyprdrive_omarchy" not in txt)
lines = na.mosaic_lua({"keys": {na.MOSAIC_ON: True, na.MOSAIC_CYCLE: "auto", na.MOSAIC_FOCUS: "auto"}})
cyc = [l for l in lines if l.startswith("hl.") and "SUPER + L" in l]
check("none: auto cycle = Super+L, unbind-then-bind, not desktop-guarded (J4/A18)",
      cyc == ["hl.unbind('SUPER + L')",
              "hl.bind('SUPER + L', hl.dsp.exec_cmd('/x/hd-layout-cycle'), { description = 'Cycle workspace layout' })"], repr(cyc))
check("none: auto focus binds only inside hyprdrive_omarchy()",
      all(l.startswith("    ") for l in lines if ("hl.bind(" in l or "hl.unbind(" in l) and "SUPER + L" not in l)
      and any("SUPER + LEFT" in l for l in lines))
lines = om.mosaic_lua({"keys": {om.MOSAIC_ON: True}})
check("omarchy: the cycle bind is unchanged (Super+L -> the script beside hdpanel)",
      "hl.bind('SUPER + L', hl.dsp.exec_cmd('/x/hd-layout-cycle'), { description = 'Cycle workspace layout' })" in lines)
store = {"animSnapshot": [
    {"name": "global", "enabled": True, "speed": 8.0, "bezier": "default", "style": ""},
    {"name": "windows", "enabled": True, "speed": 4.0, "bezier": "snappy", "style": "popin 80%"},
]}
off, _ = na.compositor_anim_lua(False, store)
check("none: off disables global + the user's own leaves",
      "leaf = 'global', enabled = false" in off and "leaf = 'windows', enabled = false" in off
      and "easeOutQuint" not in off and "fadeLayersIn" not in off)
on, restored = na.compositor_anim_lua(True, store)
check("none: on restores the snapshot, not looknfeel",
      restored and "bezier = 'snappy'" in on and "style = 'popin 80%'" in on and "easeOutQuint" not in on)
check("none: windowsMove comes back explicitly", "leaf = 'windowsMove', enabled = true" in on)
_, restored = na.compositor_anim_lua(True, {})
check("none: no snapshot -> reload asked for", restored is False)
with tempfile.TemporaryDirectory() as d:
    na.FRAGDIR = pathlib.Path(d)
    na.NATIVE_LAYOUTS = na.FRAGDIR / "45-workspace-layouts.lua"
    na.write_native_layouts({"10": "scrolling", "2": "mosaic"})
    check("none: 45-workspace-layouts.lua round-trips", na.native_layouts() == {"10": "scrolling", "2": "mosaic"})
    t = na.NATIVE_LAYOUTS.read_text()
    check("none: layouts sorted by workspace number", t.index('"2"') < t.index('"10"'))
os.environ["PATH"] = path_save


# ------------------------------------------------- the launcher on Omarchy
# A forced-Omarchy desktop whose panel does not answer (no Omarchy shell
# running) used to exit 0 having opened nothing; it must fall back to the
# standalone app. A fake `qs` records every call and answers like 0.3.1:
# 255 for "No running instances", 0 when the panel is there.
def launch(panel_answers, *args):
    with tempfile.TemporaryDirectory() as d:
        log = pathlib.Path(d) / "qs.log"
        qs = pathlib.Path(d) / "qs"
        qs.write_text('#!/bin/sh\necho "$*" >> "%s"\n'
                      'case "$*" in\n'
                      '  *"ipc call dragos.hyprdrive"*) [ "$PANEL" = 1 ] && exit 0; exit 255 ;;\n'
                      '  *"ipc call hyprdrive-settings"*) exit 255 ;;\n'
                      'esac\nexit 0\n' % log)
        qs.chmod(0o755)
        env = {"PATH": "%s:/usr/bin:/bin" % d, "HOME": d, "HYPRDRIVE_INTEGRATION": "omarchy",
               "PANEL": "1" if panel_answers else "0"}
        r = subprocess.run(["sh", str(ROOT / "settings" / "hyprdrive-settings")] + list(args),
                           env=env, capture_output=True, text=True, timeout=20)
        return r.returncode, (log.read_text().splitlines() if log.exists() else [])


rc, calls = launch(True)
check("omarchy, panel up: the panel opens, nothing else",
      rc == 0 and len(calls) == 1 and "ipc call dragos.hyprdrive open" in calls[0], repr(calls))
rc, calls = launch(False)
check("omarchy, no shell: falls back to the standalone app",
      rc == 0 and calls and "ipc call dragos.hyprdrive open" in calls[0]
      and calls[-1].startswith("-n -p ") and calls[-1].endswith("settings/shell.qml"), repr(calls))
rc, calls = launch(False, "--pane", "dock")
check("omarchy, no shell: the deep link reaches the standalone app",
      rc == 0 and calls and calls[-1].startswith("-n -p "), repr(calls))
rc, calls = launch(False, "--close")
check("omarchy, no shell: close starts nothing",
      rc == 0 and not any(c.startswith("-n -p ") for c in calls), repr(calls))

# ---------------------------------------------------------------- Keybinds
meta = {m["key"]: m for m in na.KEY_META}
check("keybinds: the scroll keys rebind (reload), in their own group",
      all(meta[na.PLUGIN + k].get("reload") and meta[na.PLUGIN + k]["group"] == "keybinds" for k in ("binds:scroll_desktops", "binds:scroll_desktops_mods")))
check("keybinds: power profiles never change binds", "keybinds" in na.PROFILE_SKIP and not na.profile_key(na.PLUGIN + "binds:scroll_desktops"))
check("animation: the two desktop-change toggles, on by default",
      all(meta[na.PLUGIN + "animation:" + k]["default"] is True and meta[na.PLUGIN + "animation:" + k]["group"] == "animation" for k in ("desktop_keyboard", "desktop_focus")))
check("keybinds: modmask names", na.mods_text(64) == "SUPER" and na.mods_text(72) == "SUPER + ALT" and na.mods_text(0) == "")
check("keybinds: chord text", na.chord_text("SUPER", "mouse_down") == "SUPER + mouse_down" and na.chord_text("", "mouse:272") == "mouse:272")
opts = [o["value"] for o in na.chord_options(na.SCROLL_MODS, "CTRL + SUPER")]
check("keybinds: scroll modifier choices keep a hand-set chord", opts[0] == "SUPER" and "CTRL + SUPER" in opts)
# The Keybinds section's rows each name a known control and bind row.
schema = (ROOT / "omarchy-plugin" / "Schema.js").read_text()
check("schema: a keybinds section", 'id: "keybinds", title: "Keybinds"' in schema)
check("schema: every bind row id is one hdpanel fills",
      set(re.findall(r'bind: "(\w+)"', schema)) <= set(na.BIND_ROWS.values()) | {"overview", "layout_cycle", "other"})

# The switches that BIND (the panel used to show these rows with nothing to
# press: "Not bound by default: bind ... in your config").
check("keybinds: every toggle row is an hdpanel bind switch",
      set(re.findall(r'toggle: "(\w+)"', schema)) == set(na.BIND_SWITCHES))
check("keybinds: bind switches off by default -> no binds", na.keybinds_lua({}) == [])
txt = "\n".join(na.keybinds_lua({"binds": {"minimize": True, "settings": True}}))
check("keybinds: minimize on = guarded unbind-then-bind of Super+H",
      "pcall(function() return hl.plugin.hyprdrive.minimize('window') end)" in txt
      and "hl.unbind('SUPER + H')" in txt and "hl.bind('SUPER + H', a0, { description = 'Minimize window' })" in txt)
check("keybinds: settings on = Super+Comma", "hl.bind('SUPER + COMMA', a0, { description = 'Hyprdrive settings' })" in txt)
txt = "\n".join(na.keybinds_lua({"keys": {na.HOT_KEYS: True}}))
check("keybinds: dock hotkeys on = Super+1..0 to hotkey()",
      "hl.unbind('SUPER + code:10')" in txt and "hl.plugin.hyprdrive.hotkey('10')" in txt and txt.count("hl.bind(") == 10)
check("keybinds: dock hotkeys rebind (reload)", meta[na.HOT_KEYS].get("reload") is True)
with tempfile.TemporaryDirectory() as d:
    na.FRAGDIR = pathlib.Path(d)
    na.STORE = pathlib.Path(d) / "panel.json"
    reloads = []
    na.hyprctl = lambda *a: reloads.append(a) or ""
    na.cmd_bind_set(["minimize", "on"])
    frag = (pathlib.Path(d) / na.PANEL_FRAG).read_text()
    check("bind-set minimize on: 40-panel.lua binds it under hyprdrive_loaded(), reloads",
          "if hyprdrive_loaded and hyprdrive_loaded() then" in frag and "hl.bind('SUPER + H'" in frag and ("reload",) in reloads)
    check("bind-set: the dump reports it", na.bind_switches(na.load_store()) == {"minimize": True, "settings": False})
    reloads.clear()
    na.cmd_bind_set(["minimize", "off"])
    check("bind-set minimize off: gone, and reloads",
          "SUPER + H" not in (pathlib.Path(d) / na.PANEL_FRAG).read_text() and ("reload",) in reloads)

# ------------------------------------------------------- the chord editor
# Settings -> Keybinds edits chords: click a key, press the new one (the QML),
# which lands as `hdpanel bind-set ID CHORD`; `bind-check` says who holds a
# chord; `capture on|off` parks Hyprland in an almost empty submap meanwhile.
for text, want in [("SUPER SHIFT, K", "SUPER + SHIFT + K"), ("super+alt+j", "SUPER + ALT + J"),
                   ('{"mods": ["ctrl", "super"], "key": "comma"}', "SUPER + CTRL + COMMA"),
                   ("SUPER + code:20", "SUPER + code:20"), ("F9", "F9")]:
    try:
        got = na.canon_chord(text)
    except ValueError as e:
        got = str(e)
    check("chord %r -> %r" % (text, want), got == want, got)
for text in ("K", "SHIFT + K", "SUPER", "SUPER + mouse:272", "SUPER + K'", "Escape"):
    try:
        na.canon_chord(text)
        check("chord %r refused" % text, False)
    except ValueError:
        check("chord %r refused" % text, True)


def bnd(mask, key, desc, submap=""):
    return {"modmask": mask, "key": key, "keycode": 0, "submap": submap, "description": desc,
            "dispatcher": "__lua", "arg": "", "mouse": key.startswith("mouse"), "catch_all": False}


BINDS = [bnd(64, "K", "Keybindings"), bnd(64, "comma", "Dismiss notification"), bnd(64, "", "Switch to workspace 3"),
         bnd(64, "H", "Minimize window"), bnd(64, "mouse_down", "Next desktop (empty ones too)"),
         bnd(64, "mouse_up", "Previous desktop (empty ones too)"), bnd(72, "LEFT", "Move left"),
         bnd(64, "L", "Cycle workspace layout"), bnd(64, "R", "x", submap="hyprdrive")]
OURS = [{"mods": "SUPER", "key": "H", "dispatcher": "minimize", "submap": ""},
        {"mods": "SUPER", "key": "mouse_down", "dispatcher": "desktop", "submap": ""}]
SUBMAP = ["default"]
CALLS = []


def fake_hyprctl(*a):
    CALLS.append(a)
    if a[:2] == ("binds", "-j"):
        return json.dumps(BINDS)
    if a[:2] == ("hyprdrive-binds", "-j"):
        return json.dumps(OURS)
    if a == ("submap",):
        return SUBMAP[0] + "\n"
    return ""


def fake_eval(code):
    CALLS.append(("eval", code))
    SUBMAP[0] = "default" if "submap('reset')" in code else (na.CAPTURE_SUBMAP if "hl.dsp.submap(" in code else SUBMAP[0])
    return True


def answer(fn, args):
    import io
    import contextlib
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        fn(args)
    return json.loads(buf.getvalue())


na.hyprctl = fake_hyprctl
na.eval_lua = fake_eval
na.apply_live_many = lambda pairs, store=None: True
c = na.check_chord({}, "settings", "SUPER + K")
check("bind-check: someone else's bind", [o["description"] for o in c["owners"]] == ["Keybindings"], c)
c = na.check_chord({}, "settings", "SUPER + COMMA")
check("bind-check: key names match case-insensitively", len(c["owners"]) == 1, c)
c = na.check_chord({}, "settings", "SUPER + 3")
check("bind-check: Super+3 hits a keyless code:12 workspace bind", len(c["owners"]) == 1, c)
c = na.check_chord({}, "settings", "SUPER + H")
check("bind-check: hyprdrive's own row (hyprdrive-binds), named",
      c["owners"] == [{"kind": "hyprdrive", "id": "minimize", "description": "Minimize window",
                       "chord": "SUPER + H", "row": "Minimize"}], c)
check("bind-check: the row itself is self", na.check_chord({}, "minimize", "SUPER + H")["self"])
check("bind-check: the layout cycle by its description", na.check_chord({}, "settings", "SUPER + L")["owners"][0]["id"] == "layout_cycle")
c = na.check_chord({}, "focus", "SUPER + ALT + ARROWS")
check("bind-check: MODS + ARROWS checks all four arrows", [o["description"] for o in c["owners"]] == ["Move left"], c)
c = na.check_chord({}, "desktop", "SUPER + mouse_down")
check("bind-check: the scroll row's own wheel is self, both directions", c["self"] and not c["owners"], c)
check("bind-check: a submap bind does not count", not na.check_chord({}, "settings", "SUPER + R")["owners"])
check("bind-check: a bad chord answers ok=false", answer(na.cmd_bind_check, ["K"])["ok"] is False)
with tempfile.TemporaryDirectory() as d:
    na.FRAGDIR = pathlib.Path(d)
    na.STATE = pathlib.Path(d)
    na.STORE = pathlib.Path(d) / "panel.json"
    na.CAPTURE_TOKEN = pathlib.Path(d) / "capture.token"
    frag = lambda: (pathlib.Path(d) / na.PANEL_FRAG).read_text()
    CALLS.clear()
    a = answer(na.cmd_bind_set, ["settings", "SUPER SHIFT, S"])
    st = na.load_store()
    check("bind-set CHORD: stored, row on, reloads", st["bindChords"]["settings"] == "SUPER + SHIFT + S"
          and st["binds"]["settings"] is True and ("reload",) in CALLS, st)
    check("bind-set CHORD: 40-panel.lua binds it, action before unbind",
          "hl.bind('SUPER + SHIFT + S', a0, { description = 'Hyprdrive settings' })" in frag()
          and frag().index("hl.plugin.hyprdrive.settings()") < frag().index("hl.unbind('SUPER + SHIFT + S')"))
    a = answer(na.cmd_bind_set, ["settings", "SUPER + K"])
    check("bind-set over a config bind takes it and says so", a["took"] == ["Keybindings"] and "hl.unbind('SUPER + K')" in frag(), a)
    answer(na.cmd_bind_set, ["settings", "off"])
    check("bind-set off keeps the chord", na.load_store()["bindChords"]["settings"] == "SUPER + K" and "description = 'Hyprdrive settings'" not in frag())
    answer(na.cmd_bind_set, ["minimize", "on"])
    a = answer(na.cmd_bind_set, ["settings", "SUPER + H", "--replace"])
    st = na.load_store()
    check("--replace turns hyprdrive's own owner off", a.get("freed") == ["minimize"] and st["binds"]["minimize"] is False
          and "hl.bind('SUPER + H', a0, { description = 'Hyprdrive settings' })" in frag(), a)
    a = answer(na.cmd_bind_set, ["layout_cycle", "SUPER ALT, M"])
    check("bind-set layout_cycle CHORD = the cycle_bind key", na.load_store()["keys"][na.MOSAIC_CYCLE] == "SUPER + ALT + M", a)
    answer(na.cmd_bind_set, ["focus", "super ctrl"])
    check("bind-set focus MODS", na.load_store()["keys"][na.MOSAIC_FOCUS] == "SUPER + CTRL")
    answer(na.cmd_bind_set, ["desktop", "alt super"])
    check("bind-set desktop MODS = the scroll modifiers", na.load_store()["keys"][na.SCROLL_MODS] == "SUPER + ALT")
    answer(na.cmd_bind_set, ["layout_cycle", "none"])
    check("bind-set layout_cycle none", na.load_store()["keys"][na.MOSAIC_CYCLE] == "none")
    for bad in (["desktop", "SHIFT"], ["layout_cycle", "K"], ["hotkeys", "on"]):
        try:
            answer(na.cmd_bind_set, bad)
            check("bind-set %r refused" % (bad,), False)
        except SystemExit:
            check("bind-set %r refused" % (bad,), True)
    CALLS.clear()
    na.cmd_reset(["keybinds"])
    st = na.load_store()
    check("reset keybinds: chords, switches and Mosaic's chords back", "bindChords" not in st and "binds" not in st
          and not any(k in st.get("keys", {}) for k in (na.MOSAIC_CYCLE, na.MOSAIC_FOCUS, na.SCROLL_MODS))
          and na.bind_chords(st) == na.CHORD_DEFAULTS and ("reload",) in CALLS, st)
    popen = []
    real_popen = subprocess.Popen
    subprocess.Popen = lambda *a, **k: popen.append(a[0])
    a = answer(na.cmd_capture, ["on"])
    subprocess.Popen = real_popen
    check("capture on: defines + enters the capture submap, starts its watchdog",
          a["ok"] and SUBMAP[0] == na.CAPTURE_SUBMAP and popen and popen[0][-2] == "watchdog"
          and any(c[0] == "eval" and "non_consuming = true" in c[1] for c in CALLS))
    a = answer(na.cmd_capture, ["off"])
    check("capture off: back to default", a["left"] and SUBMAP[0] == "default")

# Model.js: a Qt key event -> the same chord hdpanel parses (node, if any).
node = shutil.which("node")
if node:
    js = r"""
const fs = require("fs"), vm = require("vm"); const c = {}; vm.createContext(c);
vm.runInContext(fs.readFileSync(process.argv[1], "utf8").replace(".pragma library", ""), c);
const M = 0x10000000, S = 0x02000000, A = 0x08000000;
console.log(JSON.stringify([c.chordFromEvent(M, 0x4b, 45).chord, c.chordFromEvent(M | S, 0x21, 10).chord,
  c.chordFromEvent(M | A, 0x2c, 59).chord, c.chordFromEvent(0, 0x4b, 45).chord, c.chordPretty("SUPER + COMMA"),
  c.heldMods(0, 0x01000022, true)]));
"""
    r = subprocess.run([node, "-e", js, str(ROOT / "omarchy-plugin" / "Model.js")], capture_output=True, text=True)
    try:
        o = json.loads(r.stdout)
    except ValueError:
        o = None
    check("Model.js: key events -> chords hdpanel accepts",
          o == ["SUPER + K", "SUPER + SHIFT + 1", "SUPER + ALT + COMMA", "", "Super + Comma", ["SUPER"]]
          and all(na.canon_chord(x) == x for x in o[:3]), o or r.stderr)

print("settings_app_test: %s" % ("OK" if not fails else "%d FAILED" % fails))
sys.exit(1 if fails else 0)
