#!/usr/bin/env python3
"""Does this window class own a dock icon?

The Y8 hop moves the ICON's draw box and only that (Dock.cpp:3284; the running
dot and the badge are deliberately left where they are), so a fixture whose
class resolves to no desktop entry has no moving part: the dock cell is an empty
square with a dot under it and the band reads zero however the bounce behaves.
Three rounds of "the pill never moved" -- peaks 43, 20 and 0 px -- were that.

The rule mirrors AppSearch::entryIndexForClass (AppSearch.cpp:931): a match on
StartupWMClass, on the desktop id, on the id's trailing component, or on Name,
all case-insensitively; and the dirs are AppSearch::appDirs (AppSearch.cpp:141).
It is a check, not a lookup -- the plugin still does its own.

usage: y8_icon_check.py <wmClass>   -> prints the entry and the icon, exit 0
"""
import os
import sys


def app_dirs():
    dirs = []
    home = os.environ.get("XDG_DATA_HOME") or os.path.join(os.path.expanduser("~"), ".local/share")
    dirs.append(os.path.join(home, "applications"))
    for part in (os.environ.get("XDG_DATA_DIRS") or "/usr/local/share:/usr/share").split(":"):
        if part:
            dirs.append(os.path.join(part, "applications"))
    return dirs


def entries():
    seen = set()
    for d in app_dirs():
        if not os.path.isdir(d):
            continue
        for root, _, files in os.walk(d):
            for fn in files:
                if not fn.endswith(".desktop"):
                    continue
                path = os.path.join(root, fn)
                eid = os.path.relpath(path, d).replace("/", "-")[:-len(".desktop")]
                if eid in seen:
                    continue
                seen.add(eid)
                vals = {}
                try:
                    with open(path, errors="replace") as f:
                        for line in f:
                            for k in ("Name", "Icon", "StartupWMClass", "NoDisplay"):
                                if line.startswith(k + "=") and k not in vals:
                                    vals[k] = line.split("=", 1)[1].strip()
                except OSError:
                    continue
                yield eid, vals


def main():
    want = sys.argv[1].lower()
    for eid, v in entries():
        tail = eid.rsplit(".", 1)[-1]
        if want in (v.get("StartupWMClass", "").lower(), eid.lower(), tail.lower(), v.get("Name", "").lower()):
            icon = v.get("Icon", "")
            if not icon:
                print("%s matches %s.desktop, which declares no Icon" % (sys.argv[1], eid))
                return 1
            print("%s -> %s.desktop, icon %s" % (sys.argv[1], eid, icon))
            return 0
    print("%s matches no desktop entry" % sys.argv[1])
    return 1


if __name__ == "__main__":
    sys.exit(main())
