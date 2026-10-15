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
import os
import pathlib
import re
import subprocess
import sys
import tempfile
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
    m = SourceFileLoader("hdpanel_" + integration, str(ROOT / "omarchy-plugin" / "bin" / "hdpanel")).load_module()
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

print("settings_app_test: %s" % ("OK" if not fails else "%d FAILED" % fails))
sys.exit(1 if fails else 0)
