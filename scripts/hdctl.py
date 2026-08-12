#!/usr/bin/env python3
"""The settings app's whole back end. One durable write path, and this is it.

WHY A CLI AND NOT QML. The app is QML and QML must not learn the fragment
contract: the moment it can compose a fragment itself there are two
implementations of "how a value becomes config", and the second one is the one
that loses somebody's raw block. So the app draws rows and this file writes
files -- every durable write in the product goes through `hdctl set`, which goes
through scripts/fragment.py, which is the single implementation of the marker
contract. It is also why this is testable without a display: every round-trip
gate in scripts/gates/ drives THIS, not the QML.

PREVIEW IS NOT A WRITE. `hdctl preview` is `hyprctl keyword` and it is
deliberately not durable, because Phase 10 measured both reasons it cannot be:
a live keyword is discarded by the next `hyprctl reload` (theme-sync issues one
on every wallpaper change), and it lands AFTER the config parse, so it would beat
a pin -- and pin > derived > default is the only precedence the fragment layer
has. A slider drag is therefore preview; letting go is `set`.

WHERE VALUES LIVE. Two places, on purpose:

    ~/.local/state/hyprdrive/settings.json   what the APP owns, per pane.
    the fragment files themselves            what the SESSION reads.

The second is generated from the first, and the displayed value comes from
neither -- it comes from `hyprctl getoption`, the live truth, which already
accounts for the raw block, for a pin in some other fragment, and for a value
the user typed by hand. The store answers a different question: is this key
OURS. That is the same question as "is it pinned", which is why the pin toggle in
the Dock pane is `set`/`unset` and not a new mechanism.

    hdctl.py schema                 the schema, with live values merged in
    hdctl.py get KEY...             live values only
    hdctl.py preview KEY VALUE      hyprctl keyword -- instant, temporary
    hdctl.py set KEY VALUE          durable: fragment write + reload
    hdctl.py unset KEY              stop owning it (back to derived/default)
    hdctl.py raw PANE               the pane fragment's raw block
    hdctl.py raw-write PANE         stdin -> that raw block, then reload
    hdctl.py ii-set PATH VALUE      illogical-impulse's config.json + qs restart
    hdctl.py wallpaper PATH         the rice's rotation (regenerates the palette)
    hdctl.py reload                 apply whatever is on disk
"""
import argparse
import json
import os
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FRAGMENT = ROOT / "scripts" / "fragment.py"
SCHEMA = ROOT / "docs" / "schema.json"

STATE = pathlib.Path(os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state"))) / "hyprdrive"
STORE = STATE / "settings.json"
FRAGDIR = pathlib.Path(os.environ.get("HYPRDRIVE_FRAGMENTS", os.path.expanduser("~/.config/hypr/hyprdrive")))
IICONF = pathlib.Path(os.path.expanduser("~/.config/illogical-impulse/config.json"))

PLUGIN_PREFIX = "plugin:hyprdrive:"

# The one fragment this tool may never write. It is machine-derived from the
# wallpaper's palette by theme-sync, and a settings app that regenerates it would
# be overwriting the theme with a snapshot of the theme. To override a derived
# value you PIN it -- which means writing it in a pane fragment, all of which
# sort after 05, so the pin wins by load order. That is `set` on a derived key.
DERIVED_FRAGMENT = "05-theme-derived.lua"


# ---------------------------------------------------------------- compositor --
def _env():
    env = dict(os.environ)
    run = env.get("XDG_RUNTIME_DIR") or "/run/user/%d" % os.getuid()
    sig = env.get("HYPRLAND_INSTANCE_SIGNATURE")
    # An inherited signature is a hint, not an answer [theme-sync.py:126].
    if not sig or not (pathlib.Path(run) / "hypr" / sig / ".socket.sock").exists():
        d = pathlib.Path(run) / "hypr"
        sigs = sorted((p for p in d.glob("*") if (p / ".socket.sock").exists()),
                      key=lambda p: p.stat().st_mtime, reverse=True) if d.is_dir() else []
        if not sigs:
            return None
        env["HYPRLAND_INSTANCE_SIGNATURE"] = sigs[0].name
    env["XDG_RUNTIME_DIR"] = run
    return env


def hyprctl(*args, check=False):
    env = _env()
    if env is None:
        return None
    try:
        r = subprocess.run(["hyprctl", *args], capture_output=True, text=True, timeout=20, env=env)
    except (OSError, subprocess.SubprocessError):
        return None
    if check and r.returncode != 0:
        return None
    return r.stdout


def getoption(key):
    """Live value of one option, typed. None when there is no compositor."""
    out = hyprctl("getoption", key, "-j")
    if not out:
        return None
    try:
        d = json.loads(out)
    except ValueError:
        return None
    # 0.56 answers with exactly one typed field: bool/int/float/str/gradient/
    # vec2/custom. `set` says whether anything ever assigned it. Take the first
    # typed field that is present -- False and 0 are values, so this cannot test
    # truthiness.
    for k in ("bool", "int", "float", "str", "gradient", "vec2", "css", "custom", "data"):
        if k in d:
            return d[k]
    return None


# --------------------------------------------------------------------- store --
def load_store():
    if STORE.exists():
        try:
            return json.loads(STORE.read_text())
        except ValueError:
            pass
    return {"panes": {}}


def save_store(s):
    STATE.mkdir(parents=True, exist_ok=True)
    tmp = STORE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(s, indent=1, sort_keys=True) + "\n")
    os.replace(tmp, STORE)


def schema():
    return json.loads(SCHEMA.read_text())


def entry_for(sch, key):
    for e in sch["entries"]:
        if e["key"] == key:
            return e
    return None


def pane_of(sch, key):
    e = entry_for(sch, key)
    return e["pane"] if e else None


def fragment_of(sch, pane):
    for p in sch["panes"]:
        if p["id"] == pane:
            return p["fragment"]
    return None


# ------------------------------------------------------------ lua rendering --
def lua_value(v, kind):
    if kind == "bool":
        if isinstance(v, str):
            v = v.strip().lower() in ("1", "true", "yes", "on")
        return "true" if v else "false"
    if kind in ("int", "float"):
        return str(v)
    if kind == "vec2":
        if isinstance(v, (list, tuple)):
            return "{%s}" % ", ".join(str(x) for x in v)
        return "{%s}" % str(v).strip("{}")
    if kind.startswith("color"):
        s = str(v).strip()
        # 0xAARRGGBB stays a number; rgba(...)/rgb(...) and anything else is the
        # string form Hyprland's own parser takes.
        return s if re.match(r"^0[xX][0-9a-fA-F]+$", s) else '"%s"' % s
    s = str(v)
    # Long brackets: no escaping rules to get wrong, and the fragments already
    # use them for every path and selector they carry.
    return "[[%s]]" % s if "]]" not in s else '"%s"' % s.replace("\\", "\\\\").replace('"', '\\"')


def nest(pairs):
    """[('decoration:blur:size', '8')] -> {'decoration': {'blur': {'size': '8'}}}"""
    tree = {}
    for path, rendered in pairs:
        cur = tree
        parts = path.split(":")
        for p in parts[:-1]:
            cur = cur.setdefault(p, {})
        cur[parts[-1]] = rendered
    return tree


def render_tree(tree, indent):
    out = []
    pad = " " * indent
    for k in sorted(tree):
        v = tree[k]
        if isinstance(v, dict):
            out.append("%s%s = {" % (pad, k))
            out += render_tree(v, indent + 4)
            out.append("%s}," % pad)
        else:
            out.append("%s%s = %s," % (pad, k, v))
    return out


def render_fragment(sch, pane, values):
    """The machine half of a pane's fragment, from the values the app owns."""
    p = next(x for x in sch["panes"] if x["id"] == pane)
    plugin_pairs, hypr_pairs = [], []
    for key, val in sorted(values.items()):
        e = entry_for(sch, key)
        kind = e["type"] if e else "string"
        rendered = lua_value(val, kind)
        if key.startswith(PLUGIN_PREFIX):
            plugin_pairs.append((key[len(PLUGIN_PREFIX):], rendered))
        else:
            hypr_pairs.append((key, rendered))

    L = ["-- hyprdrive fragment %s -- the %s pane of the settings app." % (p["fragment"][:-4], p["title"]),
         "--",
         "-- MACHINE-OWNED above the raw-snippet marker; USER-OWNED below it. This half",
         "-- is regenerated wholesale from ~/.local/state/hyprdrive/settings.json every",
         "-- time the app commits a value, so do not hand-edit it -- type below the",
         "-- BEGIN line instead, where Lua's last-assignment-wins makes your line the",
         "-- one that takes effect.",
         "--",
         "-- %s" % p["blurb"],
         "--",
         "-- It sorts after 05-theme-derived.lua, so anything set here PINS the derived",
         "-- value: to go back to inheriting the wallpaper's palette, unset the row in",
         "-- the app and this file stops carrying the key.",
         ""]

    if not plugin_pairs and not hypr_pairs:
        L.append("-- (nothing set on this pane yet)")
        return "\n".join(L) + "\n"

    if hypr_pairs:
        L.append("hl.config({")
        L += render_tree(nest(hypr_pairs), 4)
        L.append("})")
        L.append("")
    if plugin_pairs:
        # The guard: plugin:hyprdrive:* does not exist until the .so has
        # registered it, and an unguarded block throws on every boot [00-plugin].
        L.append("if hyprdrive_loaded() then")
        L.append("    hl.config({")
        L.append("        plugin = {")
        L.append("            hyprdrive = {")
        L += render_tree(nest(plugin_pairs), 16)
        L.append("            },")
        L.append("        },")
        L.append("    })")
        L.append("end")
    return "\n".join(L) + "\n"


def write_fragment(sch, pane, quiet=False):
    frag = fragment_of(sch, pane)
    if not frag:
        raise SystemExit("hdctl: pane %s is not fragment-backed" % pane)
    if frag == DERIVED_FRAGMENT:
        raise SystemExit("hdctl: refusing to write %s -- it is theme-sync's" % frag)
    body = render_fragment(sch, pane, load_store()["panes"].get(pane, {}))
    r = subprocess.run([sys.executable, str(FRAGMENT), "write", str(FRAGDIR / frag)],
                       input=body, text=True, capture_output=True)
    if r.returncode != 0:
        sys.stderr.write(r.stderr)
        raise SystemExit(1)
    if not quiet:
        print(r.stdout.strip())
    return FRAGDIR / frag


def reload_compositor():
    ok = hyprctl("reload") is not None
    print("hdctl: %s" % ("reloaded" if ok else "no compositor -- the fragment is on disk and applies at next parse"))
    return ok


# ------------------------------------------------------------------ commands --
def cmd_schema(a):
    sch = schema()
    if a.live:
        for e in sch["entries"]:
            if e["source"] in ("plugin", "hyprland"):
                e["current"] = getoption(e["key"])
        store = load_store()["panes"]
        for e in sch["entries"]:
            e["owned"] = e["key"] in store.get(e["pane"], {})
    json.dump(sch, sys.stdout, indent=1)
    print()
    return 0


def cmd_get(a):
    for key in a.keys:
        print("%s = %s" % (key, getoption(key)))
    return 0


def cmd_preview(a):
    """Instant, and gone at the next reload. That is the point.

    NOT `hyprctl keyword`: this session's config is Lua, and 0.56 answers a
    keyword with "keyword can't work with non-legacy parsers. Use eval."
    (measured 2026-08-12). So a preview is the same one-shot `hl.config` write
    the gates' cfg_dock already uses [lib/rig.sh:121] -- which lands after the
    parse, exactly like keyword would have, and is discarded by the next reload
    for exactly the same reason. `hyprctl eval` never returns a value, so the
    read-back is a separate getoption rather than this call's output."""
    sch = schema()
    e = entry_for(sch, a.key)
    kind = e["type"] if e else "string"
    rendered = lua_value(a.value, kind)
    if a.key.startswith(PLUGIN_PREFIX):
        tree = nest([("plugin:hyprdrive:" + a.key[len(PLUGIN_PREFIX):], rendered)])
    else:
        tree = nest([(a.key, rendered)])
    body = "hl.config({\n" + "\n".join(render_tree(tree, 4)) + "\n}) return 0"
    if hyprctl("eval", body) is None:
        print("hdctl: no compositor", file=sys.stderr)
        return 1
    print("preview %s = %s (live only -- the next reload discards it)" % (a.key, getoption(a.key)))
    return 0


def cmd_set(a):
    sch = schema()
    e = entry_for(sch, a.key)
    if e is None:
        raise SystemExit("hdctl: %s is not in the schema (run scripts/gen_schema.py)" % a.key)
    if e.get("locked") and not a.force:
        raise SystemExit("hdctl: %s is locked -- %s" % (a.key, e["locked"]))
    if e["source"] == "curated":
        raise SystemExit("hdctl: %s is a curated pseudo-entry; use ii-set or wallpaper" % a.key)
    store = load_store()
    store["panes"].setdefault(e["pane"], {})[a.key] = a.value
    save_store(store)
    write_fragment(sch, e["pane"])
    if not a.no_apply:
        reload_compositor()
    return 0


def cmd_unset(a):
    sch = schema()
    e = entry_for(sch, a.key)
    if e is None:
        raise SystemExit("hdctl: %s is not in the schema" % a.key)
    store = load_store()
    if store["panes"].get(e["pane"], {}).pop(a.key, None) is None:
        print("hdctl: %s was not owned by the app" % a.key)
        return 0
    save_store(store)
    write_fragment(sch, e["pane"])
    if not a.no_apply:
        reload_compositor()
    return 0


def cmd_owned(a):
    store = load_store()["panes"]
    for pane in sorted(store):
        for k in sorted(store[pane]):
            print("%-12s %s = %s" % (pane, k, store[pane][k]))
    return 0


def _frag_path(pane):
    sch = schema()
    frag = fragment_of(sch, pane)
    if not frag:
        raise SystemExit("hdctl: pane %s is not fragment-backed" % pane)
    return FRAGDIR / frag


def cmd_raw(a):
    p = _frag_path(a.pane)
    if not p.exists():
        return 0
    r = subprocess.run([sys.executable, str(FRAGMENT), "raw", str(p)], capture_output=True, text=True)
    sys.stdout.write(r.stdout)
    return r.returncode


def cmd_raw_write(a):
    p = _frag_path(a.pane)
    body = sys.stdin.read()
    r = subprocess.run([sys.executable, str(FRAGMENT), "raw-write", str(p)],
                       input=body, text=True, capture_output=True)
    if r.returncode != 0:
        sys.stderr.write(r.stderr)
        return 1
    print(r.stdout.strip())
    if not a.no_apply:
        reload_compositor()
    return 0


def cmd_ii_set(a):
    """illogical-impulse's own config.json. Not a fragment: quickshell owns it,
    and quickshell reloads itself when it changes -- no compositor involved."""
    d = json.loads(IICONF.read_text())
    cur = d
    parts = a.path.split(".")
    for p in parts[:-1]:
        cur = cur.setdefault(p, {})
    old = cur.get(parts[-1])
    val = a.value
    if isinstance(old, bool):
        val = val.strip().lower() in ("1", "true", "yes", "on")
    elif isinstance(old, int) and not isinstance(old, bool):
        val = int(float(val))
    elif isinstance(old, float):
        val = float(val)
    cur[parts[-1]] = val
    tmp = IICONF.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(d, indent=2) + "\n")
    os.replace(tmp, IICONF)
    print("ii: %s = %s (was %s)" % (a.path, val, old))
    return 0


def cmd_wallpaper(a):
    env = _env() or dict(os.environ)
    env["WALL"] = a.path
    env["THEME"] = "1" if a.theme else "0"
    r = subprocess.run(["bash", str(ROOT / "scripts" / "hyprwall-rotate.sh")],
                       env=env, capture_output=True, text=True)
    sys.stdout.write(r.stdout)
    sys.stderr.write(r.stderr)
    return r.returncode


def cmd_reload(a):
    return 0 if reload_compositor() else 1


def main(argv):
    ap = argparse.ArgumentParser(description="hyprdrive settings back end")
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("schema"); s.add_argument("--live", action="store_true"); s.set_defaults(fn=cmd_schema)
    s = sub.add_parser("get"); s.add_argument("keys", nargs="+"); s.set_defaults(fn=cmd_get)
    s = sub.add_parser("preview"); s.add_argument("key"); s.add_argument("value"); s.set_defaults(fn=cmd_preview)
    s = sub.add_parser("set"); s.add_argument("key"); s.add_argument("value")
    s.add_argument("--force", action="store_true", help="write a locked key anyway")
    s.add_argument("--no-apply", action="store_true"); s.set_defaults(fn=cmd_set)
    s = sub.add_parser("unset"); s.add_argument("key")
    s.add_argument("--no-apply", action="store_true"); s.set_defaults(fn=cmd_unset)
    s = sub.add_parser("owned"); s.set_defaults(fn=cmd_owned)
    s = sub.add_parser("raw"); s.add_argument("pane"); s.set_defaults(fn=cmd_raw)
    s = sub.add_parser("raw-write"); s.add_argument("pane")
    s.add_argument("--no-apply", action="store_true"); s.set_defaults(fn=cmd_raw_write)
    s = sub.add_parser("ii-set"); s.add_argument("path"); s.add_argument("value"); s.set_defaults(fn=cmd_ii_set)
    s = sub.add_parser("wallpaper"); s.add_argument("path")
    s.add_argument("--theme", action="store_true"); s.set_defaults(fn=cmd_wallpaper)
    s = sub.add_parser("reload"); s.set_defaults(fn=cmd_reload)

    a = ap.parse_args(argv[1:])
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
