#!/usr/bin/env python3
"""Every plugin config key, snapshotted and restored. Used by gate_slate.

    slate_keys.py snapshot          -> "path<TAB>type<TAB>value" for every key
    slate_keys.py lua < snapshot    -> the one hl.config call that restores them

WHY A SNAPSHOT AND NOT "THE REGISTERED DEFAULTS"
------------------------------------------------
gate_slate used to put back the seven dock options and anim_scale that gates
were known to write, and its own comment said the eighth would be found out the
hard way. The obvious repair -- force every registered key to its Config.cpp
default -- is wrong on this machine: the rice CONFIGURES the plugin. wp17's
matugen fragment sets col_highlight and dock:background_opacity, 10-theme sets
wallpaper/blur/render_power, 20-layout sets workspace_gap, and scale is 0.82 and
not the registered 0.9. A slate that forced defaults would quietly re-theme the
session between gates and every pixel gate would then be measuring a
configuration nobody ships.

So the baseline is THE SESSION'S OWN VALUES, read once per compositor instance
before any gate has run, and restored before each gate after that. It is
"put it back the way the suite found it", which is what a slate is for.

Colours are read and compared but not written: nothing in the suite writes a
plugin colour, and a gradient is not round-trippable through hl.config without
re-deriving its syntax. gate_slate reports drift in one instead of hiding it.
"""
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from configkeys import parse                                   # noqa: E402

NS = os.environ.get("RIG_NS", "hyprdrive")
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WRITABLE = {"int", "float", "bool", "string"}
FIELD = {"int": "int", "float": "float", "bool": "bool", "string": "str"}


def keys():
    return parse(os.path.join(REPO, "Config.cpp"))


def snapshot():
    ks = keys()
    # One hyprctl call for all seventy-nine: seventy-nine processes is four
    # seconds of every slate, and the slate runs before every gate.
    batch = " ; ".join("getoption plugin:%s:%s" % (NS, k.path) for k in ks)
    r = subprocess.run(["hyprctl", "-j", "--batch", batch], capture_output=True, text=True)
    if r.returncode:
        sys.exit("slate_keys: hyprctl batch failed: %s" % r.stderr.strip())
    # --batch -j answers one JSON object per query, separated by blank lines.
    chunks = [c for c in r.stdout.split("\n\n") if c.strip()]
    if len(chunks) != len(ks):
        sys.exit("slate_keys: asked for %d options, got %d answers" % (len(ks), len(chunks)))
    out = []
    for k, chunk in zip(ks, chunks):
        o = json.loads(chunk)
        if k.type in WRITABLE:
            v = o.get(FIELD[k.type])
            if v is None:
                sys.exit("slate_keys: %s came back without a %s field" % (k.path, FIELD[k.type]))
            out.append("%s\t%s\t%s" % (k.path, k.type, v))
        else:
            out.append("%s\t%s\t%s" % (k.path, k.type, o.get("gradient", o.get("color", ""))))
    return "\n".join(out)


def _parse(lines):
    out = {}
    for line in lines:
        if not line.strip():
            continue
        path, typ, value = line.rstrip("\n").split("\t", 2)
        out[path] = (typ, value)
    return out


def restore(baseline_path):
    """Lua that puts back ONLY the keys that have drifted from the baseline.

    Writing all seventy-nine every time is wrong in a way that took a suite run
    to find: `hyprctl getoption` reports `set: true` for anything the session has
    ever assigned, and x53_compat_alias's A control requires its five probe keys
    to be UNSET -- "already set by this config, the copy would be skipped by the
    precedence rule and A would pass for free". A slate that assigns every key
    turns that control red on a build with nothing wrong with it. A slate that
    only puts back what moved leaves an untouched key untouched.
    """
    base = _parse(open(baseline_path).read().split("\n"))
    now = _parse(snapshot().split("\n"))
    drift = ["%s\t%s\t%s" % (k, base[k][0], base[k][1])
             for k in base if k in now and now[k][1] != base[k][1]]
    return lua(drift), [k.split("\t")[0] for k in drift]


def lua(lines):
    """One nested hl.config table for every writable key in the list."""
    tree = {}
    for line in lines:
        if not line.strip():
            continue
        path, typ, value = line.rstrip("\n").split("\t", 2)
        if typ not in WRITABLE:
            continue
        node, parts = tree, path.split(":")
        for p in parts[:-1]:
            node = node.setdefault(p, {})
        if typ == "bool":
            node[parts[-1]] = "true" if value in ("true", "1", "True") else "false"
        elif typ == "string":
            node[parts[-1]] = "[[%s]]" % value
        else:
            node[parts[-1]] = value

    if not tree:
        return ""

    def render(d):
        return "{" + ", ".join(
            "%s = %s" % (k, render(v) if isinstance(v, dict) else v)
            for k, v in d.items()) + "}"

    return "hl.config({plugin = {%s = %s}}) return 0" % (NS, render(tree))


def main(argv):
    what = argv[1] if len(argv) > 1 else "snapshot"
    if what == "snapshot":
        print(snapshot())
    elif what == "lua":
        print(lua(sys.stdin.read().split("\n")))
    elif what == "restore":
        code, names = restore(argv[2])
        if names:
            print("# drifted since the baseline: %s" % " ".join(names), file=sys.stderr)
        print(code)
    else:
        sys.exit("usage: slate_keys.py snapshot|lua|restore BASELINE")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
