#!/usr/bin/env python3
"""Import a hyprland.conf-style theme: map what the schema knows, keep the rest.

WHY THIS IS A HUNDRED LINES OF PARSER AND NOT A HYPRLANG IMPLEMENTATION. The
question a theme file has to answer is "which of these lines is a setting I
already have a row for", and the schema knows every legal key -- all 442 of
them. So the parser's whole job is to turn a file into (key path, value) pairs
plus a pile of leftovers, and hyprlang's shape makes that four rules:

    name {          open a category; the path is the categories joined by ':'
    }               close it
    key = value     an assignment at the current path
    $var = value    a variable, substituted into later values

Everything else is a leftover, and so is any assignment whose key the schema does
not have. That includes every directive -- bind, exec-once, windowrule, monitor,
source, animation, bezier -- which is correct rather than a limitation: those are
not settings, they are statements, and a settings importer that started
interpreting them would be a config translator wearing a costume.

THE LEFTOVERS ARE KEPT VERBATIM, AND THEY ARE INERT. That is the honest half of
this feature and it deserves to be said plainly rather than discovered. This
session's config is Lua (hyprland.lua, and hyprctl's keyword parser answers
"can't work with non-legacy parsers"), the fragments are Lua files, and there is
no hl.keyword or hl.source in the 0.56 API to hand a hyprlang line to -- checked
against /usr/share/hypr/stubs/hl.meta.lua. So a `bind = ...` line pasted straight
into a fragment is a syntax error that takes the whole config down with it.

They therefore land inside a Lua long-bracket string in the raw-snippet block:
byte-identical between the brackets, visible in the app's raw editor, carried
across every regeneration, and doing nothing until a person turns one into a
`hl.bind(...)`. Nothing is lost and nothing is silently mistranslated. The
alternative -- a hyprlang-to-Lua dispatcher table -- is exactly the "invent a
full parser" this was asked not to be, and it would fail on the first theme with
a dispatcher nobody thought of.

APPLY IS ALWAYS BEHIND A SNAPSHOT. hdprof.snapshot_before runs first, every time,
and the pending record it leaves means an import killed halfway is undone by the
next `hdprof check` rather than left as a half-theme.

    hdimport.py preview FILE [--json]   what it would change, per key, old -> new
    hdimport.py apply FILE              snapshot, write, reload
    hdimport.py parse FILE --json       the parse only (what the gate diffs)
"""
import argparse
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import hdctl  # noqa: E402
import hdprof  # noqa: E402

# Where the leftovers go. The Hyprland pane, because a leftover is by definition
# a compositor directive rather than a dock or blur value -- and because that
# pane already draws a raw-snippet editor, so an imported line is somewhere a
# person can see it and edit it without being told which file to open.
VERBATIM_PANE = "hyprland"

BEGIN_MARK = "-- >>> imported verbatim from %s"
END_MARK = "-- <<< end of import"


class Line:
    __slots__ = ("n", "text", "kind", "key", "value")

    def __init__(self, n, text, kind, key=None, value=None):
        self.n, self.text, self.kind, self.key, self.value = n, text, kind, key, value


def parse(text):
    """-> (assignments, variables, leftovers). Leftovers keep their original text."""
    stack, variables = [], {}
    assignments, leftovers = [], []

    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue

        # A category closes. Hyprlang allows a trailing comment after it.
        if line.startswith("}"):
            if stack:
                stack.pop()
            else:
                leftovers.append(Line(n, raw, "stray-brace"))
            continue

        # A category opens: everything before the brace is its name. Nested
        # categories are just this rule applied again, which is why the path is
        # a stack and not a special case.
        if line.endswith("{"):
            name = line[:-1].strip()
            if name:
                stack.append(name)
            continue

        if "=" not in line:
            leftovers.append(Line(n, raw, "not-an-assignment"))
            continue

        key, _, value = line.partition("=")
        key, value = key.strip(), value.strip()

        if key.startswith("$"):
            # A variable. It is ALSO a leftover on purpose: the verbatim block
            # has to stand on its own, and a `bind = $mainMod, ...` kept without
            # its definition is a line that reads as broken.
            variables[key] = subst(value, variables)
            leftovers.append(Line(n, raw, "variable", key, variables[key]))
            continue

        path = ":".join(stack + [key]) if stack else key
        assignments.append(Line(n, raw, "assignment", path, subst(value, variables)))

    return assignments, variables, leftovers


def subst(value, variables):
    """$name -> its definition. Longest name first so $mainMod is not eaten by
    a $main that happens to exist."""
    for name in sorted(variables, key=len, reverse=True):
        value = value.replace(name, variables[name])
    return value


def strip_comment(value):
    """hyprlang takes a trailing `# ...` comment on a value line. Colours are
    written rgba()/0x here, so a `#` mid-value is a comment rather than a hex
    colour -- but only when something separates it from the value."""
    return re.split(r"\s+#", value, maxsplit=1)[0].strip()


def same_value(old, new, kind):
    """Is the theme asking for what the system already has?

    Typed, not textual: `hyprctl getoption` answers a bool with True and a theme
    writes `true`, and a diff preview that calls those two different is a preview
    that tells the user to expect eleven changes when there are nine. Anything
    that will not compare numerically or as a bool falls back to text, which is
    the honest answer for gradients and paths."""
    if old is None:
        return False
    if kind == "bool":
        t = ("1", "true", "yes", "on")
        return (str(old).strip().lower() in t) == (str(new).strip().lower() in t)
    if kind in ("int", "float"):
        try:
            return abs(float(old) - float(new)) < 1e-9
        except (TypeError, ValueError):
            pass
    return str(old).strip() == str(new).strip()


# ------------------------------------------------------------------- report --
def report(path):
    text = pathlib.Path(path).read_text()
    assignments, variables, leftovers = parse(text)
    sch = hdctl.schema()
    by_key = {e["key"]: e for e in sch["entries"]}

    mapped, unchanged, unknown = [], [], []
    for a in assignments:
        e = by_key.get(a.key)
        if e is None:
            unknown.append(a)
            continue
        new = strip_comment(a.value)
        old = hdctl.getoption(a.key) if e["source"] in ("plugin", "hyprland") \
            else hdctl.curated_current(e)
        row = {"key": a.key, "pane": e["pane"], "apply": e.get("apply", "reload"),
               "type": e["type"], "line": a.n, "old": old, "new": new,
               "locked": e.get("locked")}
        (unchanged if same_value(old, new, e["type"]) else mapped).append(row)

    # An assignment the schema has no row for is a leftover like any other, and
    # it goes in the verbatim block with them, IN FILE ORDER -- the first cut
    # listed these in the preview and then wrote only the non-assignments, which
    # would have dropped `vibrancy_darkness = 0.55` on the floor while telling
    # the user it had been kept.
    verbatim = sorted(leftovers + unknown, key=lambda l: l.n)
    return {
        "file": str(path),
        "lines": len(text.splitlines()),
        "mapped": mapped,
        "unchanged": unchanged,
        "unknown": [{"key": a.key, "line": a.n, "value": a.value, "text": a.text}
                    for a in unknown],
        "verbatim": [{"line": l.n, "kind": l.kind, "text": l.text} for l in verbatim],
        "variables": variables,
        "counts": {
            "assignments": len(assignments),
            "mapped": len(mapped),
            "unchanged": len(unchanged),
            "unknown_keys": len(unknown),
            "verbatim": len(verbatim),
        },
    }


def print_report(r):
    c = r["counts"]
    print("%s -- %d lines, %d assignments" % (r["file"], r["lines"], c["assignments"]))
    print()
    print("WOULD CHANGE (%d)" % c["mapped"])
    for m in r["mapped"]:
        lock = "   LOCKED: %s" % m["locked"] if m["locked"] else ""
        print("  %-44s %-18s -> %s%s" % (m["key"], m["old"], m["new"], lock))
    if r["unchanged"]:
        print()
        print("ALREADY THAT VALUE (%d)" % c["unchanged"])
        for m in r["unchanged"]:
            print("  %-44s %s" % (m["key"], m["new"]))
    if r["unknown"]:
        print()
        print("NOT IN THE SCHEMA (%d) -- these are among the verbatim lines below" % c["unknown_keys"])
        for u in r["unknown"]:
            print("  line %-4d %s" % (u["line"], u["text"].strip()))
    print()
    print("VERBATIM TO THE RAW SNIPPET (%d)" % c["verbatim"])
    for v in r["verbatim"]:
        print("  line %-4d %s" % (v["line"], v["text"].strip()))


# -------------------------------------------------------------------- apply --
def verbatim_block(path, lines):
    """The leftovers, byte for byte, inside something Lua can hold.

    The long-bracket level is chosen so nothing in the payload can close it: a
    theme containing `]]` would otherwise end the string early and turn the rest
    of somebody's bind list into code."""
    body = "\n".join(lines)
    level = 0
    while ("]" + "=" * level + "]") in body:
        level += 1
    eq = "=" * level
    return "\n".join([
        BEGIN_MARK % path,
        "-- Lines this importer did not recognise, kept exactly as they were written.",
        "-- They are hyprlang and this session's config is Lua, so there is nothing to",
        "-- hand them to: they are text until somebody rewrites one as Lua (a bind",
        "-- becomes hl.bind, an exec-once becomes hl.exec_cmd). Nothing was translated",
        "-- and nothing was dropped.",
        "hyprdrive_import_verbatim = [%s[" % eq,
        body,
        "]%s]" % eq,
        END_MARK,
    ])


def apply(path, no_apply=False, quiet=False):
    r = report(path)
    sch = hdctl.schema()

    ref = hdprof.snapshot_before("theme import: %s" % pathlib.Path(path).name)
    if not quiet:
        print("hdimport: snapshot %s taken before anything is written" % ref)

    used = set()
    written = []
    for m in r["mapped"]:
        if m["locked"]:
            # A locked row is locked against an import too. The user law it
            # encodes does not become negotiable because the value arrived in a
            # file rather than through the UI.
            print("hdimport: SKIPPED %s -- %s" % (m["key"], m["locked"]))
            continue
        used.add(hdctl.set_one(sch, m["key"], m["new"]))
        written.append(m["key"])
        if not quiet:
            print("    %-44s %s -> %s" % (m["key"], m["old"], m["new"]))

    # The raw block is USER-OWNED, so this APPENDS. Replacing it would make an
    # import the one operation in the product that eats hand-written config,
    # which is the exact failure the marker contract exists to prevent.
    n_verbatim = 0
    if r["verbatim"]:
        frag = hdctl.FRAGDIR / hdctl.fragment_of(sch, VERBATIM_PANE)
        existing = raw_of(frag)
        block = verbatim_block(pathlib.Path(path).name, [v["text"] for v in r["verbatim"]])
        body = (existing.rstrip("\n") + "\n\n" + block) if existing.strip() else block
        write_raw(frag, body)
        n_verbatim = len(r["verbatim"])
        if not quiet:
            print("    %d lines kept verbatim in the %s pane's raw snippet (%s)"
                  % (n_verbatim, VERBATIM_PANE, frag.name))

    if not no_apply:
        if "reload" in used or n_verbatim:
            hdctl.reload_compositor()
        if "qs-restart" in used:
            hdprof.qs_restart()
    hdprof.finish()
    if not quiet:
        print("hdimport: %d values applied, %d lines verbatim -- `hdprof revert` undoes all of it"
              % (len(written), n_verbatim))
    return 0


def raw_of(frag):
    import subprocess
    if not frag.exists():
        return ""
    r = subprocess.run([sys.executable, str(hdctl.FRAGMENT), "raw", str(frag)],
                       capture_output=True, text=True)
    return r.stdout


def write_raw(frag, body):
    import subprocess
    r = subprocess.run([sys.executable, str(hdctl.FRAGMENT), "raw-write", str(frag)],
                       input=body, text=True, capture_output=True)
    if r.returncode != 0:
        sys.stderr.write(r.stderr)
        raise SystemExit(1)


# ----------------------------------------------------------------- commands --
def cmd_preview(a):
    r = report(a.file)
    if a.json:
        json.dump(r, sys.stdout, indent=1)
        print()
    else:
        print_report(r)
    return 0


def cmd_parse(a):
    assignments, variables, leftovers = parse(pathlib.Path(a.file).read_text())
    json.dump({"assignments": [{"line": l.n, "key": l.key, "value": l.value} for l in assignments],
               "variables": variables,
               "leftovers": [{"line": l.n, "kind": l.kind, "text": l.text} for l in leftovers]},
              sys.stdout, indent=1)
    print()
    return 0


def cmd_apply(a):
    return apply(a.file, no_apply=a.no_apply)


def main(argv):
    ap = argparse.ArgumentParser(description="import a hyprland.conf-style theme")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("preview"); s.add_argument("file")
    s.add_argument("--json", action="store_true"); s.set_defaults(fn=cmd_preview)
    s = sub.add_parser("parse"); s.add_argument("file")
    s.add_argument("--json", action="store_true"); s.set_defaults(fn=cmd_parse)
    s = sub.add_parser("apply"); s.add_argument("file")
    s.add_argument("--no-apply", action="store_true"); s.set_defaults(fn=cmd_apply)
    a = ap.parse_args(argv[1:])
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
