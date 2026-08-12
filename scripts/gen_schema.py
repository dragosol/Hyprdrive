#!/usr/bin/env python3
"""Join the three sources into docs/schema.json -- what the settings app reads.

THE SCHEMA IS DATA. The settings app has one pane component and one row
component; which panes exist, which rows are on them, what widget a row draws
and how a change is applied are all read out of this file at runtime. Adding an
option to the app is therefore adding a row here, not adding QML -- which is the
contract Phase 12 is asked to keep and the reason this generator exists at all.

THREE SOURCES, TWO GENERATED AND ONE CURATED:

    Config.cpp             -> 79 plugin keys, via scripts/lib/configkeys.py.
                              The SAME parser docs/CONFIG.md is generated with,
                              on purpose: a second regex over the same file is a
                              second thing to forget on the day a key is added.
    hyprland-descriptions  -> 353 compositor options, snapshotted from a live
                              `hyprctl descriptions -j` (it already carries type,
                              default, min, max, description and enum maps -- so
                              nothing here has to know what an option means).
    curated.json           -> panes, routes, per-key overrides, the ii knobs and
                              the wallpaper/monitor pseudo-entries. Hand-written.

DRIFT. docs/schema.json is committed and `--check` regenerates and diffs, exactly
as gen_keys_table.sh does for docs/CONFIG.md, and for the same reason: a mirror
of Config.cpp that nobody is forced to refresh is a mirror that lies. Add a key
to Config.cpp and this check goes red until the schema is regenerated. It goes
red a second way too -- a plugin key that no route claims is a hard error rather
than a silently-unreachable option.

    scripts/gen_schema.py                     rewrite docs/schema.json
    scripts/gen_schema.py --check             exit 1 if it is stale
    scripts/gen_schema.py --refresh-hyprland  re-snapshot from a live compositor
"""
import argparse
import fnmatch
import json
import os
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts" / "lib"))
from configkeys import parse as parse_plugin_keys  # noqa: E402

PLUGIN_PREFIX = "plugin:hyprdrive:"
SCHEMA = ROOT / "docs" / "schema.json"
CURATED = ROOT / "config" / "schema" / "curated.json"
HYPRDESC = ROOT / "config" / "schema" / "hyprland-descriptions.json"


def route(table, tail):
    for r in table:
        if fnmatch.fnmatchcase(tail, r["match"]):
            return r
    return None


def widget_for(kind, lo, hi, choices=None):
    if choices:
        return "choice"
    if kind == "bool":
        return "switch"
    if kind in ("int", "float"):
        return "slider" if lo is not None and hi is not None else "number"
    if kind.startswith("color"):
        return "color"
    return "text"


def hyprland_type(d):
    v = d.get("default")
    if isinstance(v, bool):
        return "bool"
    if isinstance(v, int):
        return "int"
    if isinstance(v, float):
        return "float"
    if isinstance(v, list):
        return "vec2"
    # A colour is a string default that reads back as a gradient/int; hyprctl
    # does not label it, and the name is the only honest signal there is.
    name = d["name"]
    if "col." in name or name.endswith("_color") or name.endswith(":color"):
        return "color"
    return "string"


def build():
    curated = json.loads(CURATED.read_text())
    overrides = curated["overrides"]
    panes = curated["panes"]
    pane_ids = {p["id"] for p in panes}

    entries = []
    problems = []

    # ------------------------------------------------------------ plugin keys --
    for k in parse_plugin_keys(str(ROOT / "Config.cpp")):
        key = PLUGIN_PREFIX + k.path
        r = route(curated["plugin_routes"], k.path)
        if r is None:
            problems.append("no plugin_route claims %s -- it would be unreachable in the app" % key)
            continue
        o = overrides.get(key, {})
        lo = o.get("ui", {}).get("min", k.min)
        hi = o.get("ui", {}).get("max", k.max)
        e = {
            "key": key,
            "source": "plugin",
            "pane": o.get("pane", r["pane"]),
            "apply": o.get("apply", r["apply"]),
            "type": k.type,
            "default": k.default,
            "description": k.description,
        }
        if lo is not None:
            e["min"] = float(lo) if k.type == "float" else lo
        if hi is not None:
            e["max"] = float(hi) if k.type == "float" else hi
        if o.get("choices"):
            e["choices"] = o["choices"]
        e["widget"] = o.get("widget", widget_for(k.type, lo, hi, o.get("choices")))
        for extra in ("note", "locked", "derived", "follows"):
            if extra in o:
                e[extra] = o[extra]
        entries.append(e)

    # -------------------------------------------------------- hyprland options --
    desc = json.loads(HYPRDESC.read_text())
    for d in desc["options"]:
        name = d["name"]
        r = route(curated["hyprland_routes"], name)
        if r is None:
            problems.append("no hyprland_route claims %s" % name)
            continue
        o = overrides.get(name, {})
        kind = hyprland_type(d)
        lo = o.get("ui", {}).get("min", d.get("min"))
        hi = o.get("ui", {}).get("max", d.get("max"))
        choices = o.get("choices")
        if d.get("map"):
            # hyprctl gives enums as [{"name": value}, ...], newest first.
            choices = [list(m.keys())[0] for m in reversed(d["map"])]
        e = {
            "key": name,
            "source": "hyprland",
            "pane": o.get("pane", r["pane"]),
            "apply": o.get("apply", r["apply"]),
            "type": kind,
            "default": d.get("default"),
            "description": d.get("description", ""),
        }
        if lo is not None:
            e["min"] = lo
        if hi is not None:
            e["max"] = hi
        if choices:
            e["choices"] = choices
            e["choice_values"] = [list(m.values())[0] for m in reversed(d["map"])] if d.get("map") else None
        e["widget"] = o.get("widget", widget_for(kind, lo, hi, choices))
        for extra in ("note", "locked", "derived", "follows"):
            if extra in o:
                e[extra] = o[extra]
        entries.append(e)

    # ----------------------------------------------------------------- curated --
    for x in curated["extra"]:
        e = dict(x)
        e["source"] = "curated"
        entries.append(e)

    for e in entries:
        if e["pane"] not in pane_ids:
            problems.append("%s routes to pane '%s', which does not exist" % (e["key"], e["pane"]))

    if problems:
        for p in problems:
            print("gen_schema: " + p, file=sys.stderr)
        raise SystemExit(1)

    counts = {}
    for e in entries:
        counts[e["pane"]] = counts.get(e["pane"], 0) + 1

    return {
        "_note": "GENERATED by scripts/gen_schema.py. Do not edit -- edit Config.cpp or config/schema/curated.json.",
        "generator": "scripts/gen_schema.py",
        "hyprland_version": desc.get("version"),
        "counts": {
            "plugin": sum(1 for e in entries if e["source"] == "plugin"),
            "hyprland": sum(1 for e in entries if e["source"] == "hyprland"),
            "curated": sum(1 for e in entries if e["source"] == "curated"),
            "total": len(entries),
            "per_pane": counts,
        },
        "panes": panes,
        "monitor_fields": curated["monitor_fields"],
        "entries": entries,
    }


def refresh_hyprland():
    env = dict(os.environ)
    run = env.get("XDG_RUNTIME_DIR") or "/run/user/%d" % os.getuid()
    d = pathlib.Path(run) / "hypr"
    sigs = sorted((p for p in d.glob("*") if (p / ".socket.sock").exists()),
                  key=lambda p: p.stat().st_mtime, reverse=True) if d.is_dir() else []
    if not sigs:
        raise SystemExit("gen_schema: --refresh-hyprland needs a live compositor")
    env["HYPRLAND_INSTANCE_SIGNATURE"] = sigs[0].name
    env["XDG_RUNTIME_DIR"] = run
    opts = json.loads(subprocess.run(["hyprctl", "descriptions", "-j"], capture_output=True,
                                     text=True, env=env, check=True).stdout)
    ver = subprocess.run(["hyprctl", "version"], capture_output=True, text=True, env=env).stdout
    ver = ver.split()[1] if ver else "?"
    for o in opts:
        # `current` is session state, not schema: committing it would make this
        # file diff on every run of every gate.
        o.pop("current", None)
    old = json.loads(HYPRDESC.read_text())
    old["version"] = ver
    old["options"] = opts
    HYPRDESC.write_text(json.dumps(old, indent=1) + "\n")
    print("gen_schema: snapshotted %d Hyprland %s options" % (len(opts), ver))


def main(argv):
    ap = argparse.ArgumentParser(description="generate the settings schema")
    ap.add_argument("--check", action="store_true", help="exit 1 if docs/schema.json is stale")
    ap.add_argument("--refresh-hyprland", action="store_true", help="re-snapshot hyprctl descriptions")
    a = ap.parse_args(argv[1:])

    if a.refresh_hyprland:
        refresh_hyprland()
        return 0

    body = json.dumps(build(), indent=1) + "\n"

    if a.check:
        have = SCHEMA.read_text() if SCHEMA.exists() else ""
        if have != body:
            print("docs/schema.json is out of date -- run scripts/gen_schema.py", file=sys.stderr)
            if have:
                import difflib
                for line in list(difflib.unified_diff(have.splitlines(), body.splitlines(),
                                                      "committed", "generated", lineterm=""))[:40]:
                    print(line, file=sys.stderr)
            return 1
        n = json.loads(body)["counts"]
        print("docs/schema.json is current (%d entries: %d plugin, %d hyprland, %d curated)"
              % (n["total"], n["plugin"], n["hyprland"], n["curated"]))
        return 0

    SCHEMA.parent.mkdir(parents=True, exist_ok=True)
    SCHEMA.write_text(body)
    n = json.loads(body)["counts"]
    print("wrote %s -- %d entries (%d plugin, %d hyprland, %d curated) over %d panes"
          % (SCHEMA, n["total"], n["plugin"], n["hyprland"], n["curated"], len(n["per_pane"])))
    for pane, c in sorted(n["per_pane"].items()):
        print("    %-12s %3d" % (pane, c))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
