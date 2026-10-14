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
    reload is asked for instead of Omarchy's curves.
"""
import os
import pathlib
import re
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
txt = "\n".join(na.mosaic_lua({"keys": {na.MOSAIC_ON: True, na.MOSAIC_CYCLE: "auto", na.MOSAIC_FOCUS: "auto"}}))
check("none: auto chords only inside hyprdrive_omarchy()",
      all(l.startswith("    ") for l in txt.splitlines() if "hl.bind(" in l or "hl.unbind(" in l))
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

print("settings_app_test: %s" % ("OK" if not fails else "%d FAILED" % fails))
sys.exit(1 if fails else 0)
