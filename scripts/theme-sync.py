#!/usr/bin/env python3
"""Hyprdrive theme adoption: re-derive 05-theme-derived.lua from the palette.

WHAT OWNS WHAT. Phase 9 split the config surface in two: a fragment owns what a
HUMAN chooses, matugen owns what the WALLPAPER derives. This file is the third
kind and it needs its own rule, because it is machine-written like matugen's
output but lives in the fragment directory like a human's:

    pin  >  derived  >  plugin default

`derived` is this file's output, 05-theme-derived.lua. `pin` is the same key
written by a human in ANY later fragment -- 10-theme.lua's machine half, its
raw-snippet block, or a fragment of your own numbered above 05. That is the
whole of the inherit-or-pin masking: to inherit, write nothing; to pin, write
the value where you would have written it anyway.

And it is enforced by ORDERING, not by this script being clever. Fragments are
Lua, they load in filename order, Lua's last assignment wins, and 05 sorts
before 10. So a pin wins even if the scan below fails to notice it, and the
scan below can only ever be wrong about the COMMENTS it writes into the header.
That is deliberate: a masking rule that depends on a regex over somebody's Lua
is a masking rule that loses somebody's config the first time they surprise it.

THE SOURCES. Two, as Phase 10 specifies:

  1. ii's matugen palette, ~/.local/state/quickshell/user/generated/colors.json.
     This is the real one: every derived value below comes from it.
  2. The compositor's own live theme values, read back through `hyprctl
     getoption`. Measured 2026-08-12, what is actually live-readable there is
     general:col.active_border, general:col.inactive_border,
     misc:background_color and decoration:blur:* -- and every COLOUR among them
     is itself a matugen template output (hyprland/colors.lua), so as a palette
     source it is the same source once removed. It earns its place as (a) the
     FALLBACK when colors.json is missing or unreadable -- the compositor still
     knows the accent -- and (b) a corroborating dark/light vote that is logged
     when it disagrees with the palette. Anything else would be inventing a
     source; see the phase report.

FROST IS ALWAYS ON (user law). The blur keys the dock carries all default to
-1 = "follow decoration:blur:*", which is the user's own 2026-08-06 decision,
and a derived number pinned there would REPLACE that live inheritance with a
snapshot. So this script derives no blur key at all. What it does derive is the
pill's own alpha, which is the one frost value the palette genuinely moves --
and it is CLAMPED, hard, so no palette can ever push the pill to opaque and
defeat the compositor blur behind it (an opaque surface has no backdrop).

APPLY. `hyprctl reload`, which re-parses the whole chain and therefore re-applies
the precedence above by construction. A live `hl.config` write would be faster
and would not re-apply the monitor config, but it lands LAST and would beat a
pin -- the ordering guarantee only exists inside a parse. Measured 2026-08-12:
reload repaints the strip selection ring and the dock pill in place, with the
overview open, with no compositor restart (zrig/phase10/probe2,3).

AND THE REASON THIS SCRIPT IS NOT OPTIONAL. Hyprland 0.56 watches the config
files it has already sourced and reloads itself when one of them changes -- so
matugen rewriting hyprland/colors.lua ALREADY re-applied col_highlight, before
this phase existed, with nobody asking it to. That sounds like it makes a
derived fragment redundant. It is the opposite: the moment a fragment that sorts
after colors.lua carries col_highlight, that fragment WINS every one of those
automatic reloads, and if nothing regenerates it the accent stops following the
wallpaper entirely. Measured, both ways, 2026-08-12:

    05-theme-derived.lua absent   matugen -> col_highlight follows (#adc6ff -> #d9d960)
    05-theme-derived.lua stale    matugen -> col_highlight FROZEN at the fragment's value

That is exactly the trap Phase 9 named when it refused to copy col_highlight
into a fragment, and this script is what makes the fragment safe to have. It
also means the two reloads race: Hyprland's own fires on colors.lua while this
script is still being started, and it sources the previous derived values. The
`hyprctl reload` below is what settles it, ~200ms later, on the right ones.

    theme-sync.py                      derive, write, apply
    theme-sync.py --no-apply           derive and write only (install time)
    theme-sync.py --print              derive and print, touch nothing
"""
import argparse
import json
import os
import pathlib
import re
import subprocess
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
FRAGMENT = HERE / "fragment.py"
NAME = "05-theme-derived.lua"

DEFAULT_COLORS = "~/.local/state/quickshell/user/generated/colors.json"
DEFAULT_DEST = "~/.config/hypr/hyprdrive"

# key leaf -> (config path under plugin:hyprdrive:, what it paints)
DERIVED = [
    ("col_highlight", "col_highlight",
     "overview accent: strip selection ring, tile selection, search selection, dock hover"),
    ("indicator_color", "dock:indicator_color", "dock accent: the running dot under an icon"),
    ("background_color", "dock:background_color", "dock frost: the pill's hue"),
    ("background_opacity", "dock:background_opacity", "dock frost: the pill's alpha (clamped, never opaque)"),
]

# The pill may never go opaque: the dock's frost is compositor blur sampled
# through the pill, and a surface with alpha 1 has no backdrop to blur.
OPACITY_MIN, OPACITY_MAX = 0.05, 0.45


# ------------------------------------------------------------------ helpers --
def hexrgb(s):
    """'#a1d749' -> (161, 215, 73). Accepts 8-digit too, alpha discarded."""
    s = s.strip().lstrip("#")
    return tuple(int(s[i:i + 2], 16) for i in (0, 2, 4))


def luma(rgb):
    """Relative luminance, 0..1. Rec.709 on gamma-encoded values is close
    enough to decide dark-vs-light and does not need a linearisation step to
    get that answer right."""
    r, g, b = rgb
    return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0


def hyprctl(*args):
    env = dict(os.environ)
    run = env.get("XDG_RUNTIME_DIR") or "/run/user/%d" % os.getuid()
    sig = env.get("HYPRLAND_INSTANCE_SIGNATURE")
    # An inherited signature is a hint, never an answer. A path unit has no
    # session environment at all, so most runs discover it -- but Hyprland's
    # startup imports HYPRLAND_INSTANCE_SIGNATURE into the systemd user
    # environment, and that copy goes stale the moment the compositor restarts,
    # which gdm does after every crash. Trusting it then makes theme-sync write
    # fragment after fragment that nothing ever applies, silently, forever:
    # reproduced 2026-08-12, `apply=no compositor` while a live session sat
    # right there. So the socket has to exist before the name is worth using
    # [lib/rig.sh:70-78 makes the same rule for the gates].
    if not sig or not (pathlib.Path(run) / "hypr" / sig / ".socket.sock").exists():
        d = pathlib.Path(run) / "hypr"
        sigs = sorted((p for p in d.glob("*") if (p / ".socket.sock").exists()),
                      key=lambda p: p.stat().st_mtime, reverse=True) if d.is_dir() else []
        if not sigs:
            return None
        env["HYPRLAND_INSTANCE_SIGNATURE"] = sigs[0].name
        env["XDG_RUNTIME_DIR"] = run
    try:
        out = subprocess.run(["hyprctl", *args], capture_output=True, text=True, timeout=15, env=env)
    except (OSError, subprocess.SubprocessError):
        return None
    return out.stdout if out.returncode == 0 else None


def getoption(key):
    """First line of `hyprctl getoption KEY`, value only. None if unavailable."""
    out = hyprctl("getoption", key)
    if not out:
        return None
    first = out.splitlines()[0] if out.splitlines() else ""
    # 'int: 4290822076' / 'gradient data: ffdec1a9 0deg' / 'custom type: ...'
    return first.split(":", 1)[1].strip() if ":" in first else None


def border_accent():
    """The compositor's live accent, as a fallback palette of one.
    general:col.active_border reads back as a gradient: 'data: ffdec1a9 0deg'."""
    v = getoption("general:col.active_border")
    if not v:
        return None
    m = re.search(r"([0-9a-fA-F]{8})", v)
    if not m:
        return None
    argb = m.group(1)          # AARRGGBB
    return hexrgb(argb[2:])


def bg_luma():
    """misc:background_color as a dark/light vote. 'int: 4280426770'."""
    v = getoption("misc:background_color")
    if not v:
        return None
    try:
        n = int(v)
    except ValueError:
        return None
    return luma(((n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF))


# --------------------------------------------------------------- derivation --
def derive(palette, live):
    """palette: dict from colors.json (may be empty). live: dict of readbacks.
    Returns (values, notes) -- values keyed by leaf name, ready to render."""
    notes = []

    def col(name):
        v = palette.get(name)
        return hexrgb(v) if v else None

    accent = col("primary")
    if accent is None:
        accent = live.get("border_accent")
        notes.append("no palette primary -- accent fell back to general:col.active_border")
    if accent is None:
        return None, notes + ["no palette and no live border colour: nothing to derive"]

    surface = col("surface")
    if surface is not None:
        mode = "dark" if luma(surface) < 0.5 else "light"
    elif live.get("bg_luma") is not None:
        mode = "dark" if live["bg_luma"] < 0.5 else "light"
        notes.append("no palette surface -- dark/light fell back to misc:background_color")
    else:
        mode = "dark"
        notes.append("no dark/light source at all -- assuming dark")

    # The corroborating vote. Logged, never obeyed: the palette is the source of
    # truth and misc:background_color is a template output of that same palette,
    # so a disagreement means the compositor is a theme behind, not that the
    # palette is wrong.
    if surface is not None and live.get("bg_luma") is not None:
        live_mode = "dark" if live["bg_luma"] < 0.5 else "light"
        if live_mode != mode:
            notes.append("dark/light: palette says %s, live misc:background_color says %s "
                         "(compositor is a theme behind; palette wins)" % (mode, live_mode))

    # The pill takes primary_container -- Material's role for "a container that
    # carries the accent at reduced emphasis", which is exactly what a dock pill
    # is. The neutral surface_container ramp would be the other candidate and is
    # the wrong one here: across this guest's 22 wallpapers it moves by ~12 RGB
    # units end to end, which at pill alpha is under three units on screen. A
    # dock that re-themes invisibly has not re-themed.
    pill = col("primary_container") or accent

    # Frost strength. A light theme needs more of its own hue in the pill to
    # read as a surface at all; a dark one needs less or it stops looking like
    # glass. Both ends are inside the clamp by construction -- the clamp is
    # there for a palette-driven future, not for these two constants.
    opacity = 0.30 if mode == "light" else 0.22
    clamped = min(max(opacity, OPACITY_MIN), OPACITY_MAX)
    if clamped != opacity:
        notes.append("pill alpha %.2f clamped to %.2f: frost stays on, always" % (opacity, clamped))

    return {
        "mode": mode,
        "col_highlight": accent,
        "indicator_color": accent,
        "background_color": pill,
        "background_opacity": clamped,
    }, notes


# ------------------------------------------------------------- pin scanning --
PIN_RE = "(?:%s\\s*=|\\[\\s*[\"']%s[\"']\\s*\\]\\s*=)"


def find_pins(dest, leaves):
    """Which derived keys does a LATER fragment also set? Documentation only --
    the load order already decides the outcome, so a wrong answer here costs a
    comment in a generated header and nothing else. That is why it is allowed to
    be a regex over somebody's Lua at all.

    Line comments are stripped first, and that is not tidiness: a commented-out
    assignment is not a pin, and this gate's own rig fragment carries the words
    `background_opacity=1.0` in a sentence explaining an unrelated window rule.
    It was reported as a pin until this line existed. Block comments (--[[ ]])
    are not handled; they would only ever cost another spurious comment."""
    pins = {}
    for f in sorted(pathlib.Path(dest).glob("*.lua")):
        if f.name == NAME:
            continue
        try:
            text = re.sub(r"--[^\n]*", "", f.read_text())
        except OSError:
            continue
        # Fragments below 05 load BEFORE the derived one and lose to it; only a
        # later filename can mask.
        if f.name < NAME:
            continue
        for leaf in leaves:
            if re.search(PIN_RE % (leaf, leaf), text):
                pins.setdefault(leaf, []).append(f.name)
    return pins


# ------------------------------------------------------------------ render --
def render(vals, pins, palette_path, notes):
    def rgba(rgb):
        return "rgba(%02x%02x%02xff)" % rgb

    def argb(rgb):
        return "0xff%02x%02x%02x" % rgb

    L = []
    A = L.append
    A("-- hyprdrive fragment 05-theme-derived -- GENERATED, do not hand-edit above")
    A("-- the raw-snippet marker. scripts/theme-sync.py rewrites this half every")
    A("-- time ii's matugen palette changes; a systemd --user path unit fires it.")
    A("--")
    A("--     pin  >  derived  >  plugin default")
    A("--")
    A("-- DERIVED is this file. PIN is the same key set by a human in any fragment")
    A("-- that sorts AFTER this one -- 10-theme.lua, its raw-snippet block, or your")
    A("-- own. Fragments are Lua and load in filename order, so a later assignment")
    A("-- simply wins: to inherit the theme write nothing, to pin your own write it")
    A("-- where you would have written it anyway. Nothing here has to cooperate for")
    A("-- that to hold.")
    A("--")
    A("-- 05, so it lands after 00 registers the plugin and before 10 can mask it.")
    A("--")
    A("-- source: %s" % palette_path)
    A("-- theme:  %s" % vals["mode"])
    A("-- at:     %s" % time.strftime("%Y-%m-%d %H:%M:%S %Z"))
    for n in notes:
        A("-- note:   %s" % n)
    A("")
    A("if hyprdrive_loaded() then")
    A("    hl.config({")
    A("        plugin = {")
    A("            hyprdrive = {")

    def emit(indent, leaf, text, what):
        L.append("%s-- %s" % (indent, what))
        if leaf in pins:
            L.append("%s-- PINNED in %s: the derived value is not emitted, and would"
                     % (indent, ", ".join(pins[leaf])))
            L.append("%s-- lose to that fragment anyway -- it loads after this one." % indent)
        else:
            L.append("%s%s" % (indent, text))

    emit(" " * 16, "col_highlight",
         'col_highlight = "%s",' % rgba(vals["col_highlight"]),
         "overview accent: strip ring, selection, search, dock hover")
    L.append("")
    L.append(" " * 16 + "dock = {")
    emit(" " * 20, "indicator_color",
         "indicator_color    = %s," % argb(vals["indicator_color"]),
         "dock accent: the running dot")
    emit(" " * 20, "background_color",
         "background_color   = %s," % argb(vals["background_color"]),
         "dock frost: the pill's hue")
    emit(" " * 20, "background_opacity",
         "background_opacity = %.2f," % vals["background_opacity"],
         "dock frost: the pill's alpha, clamped to <= %.2f so no palette can"
         " ever push it opaque" % OPACITY_MAX)
    L.append("")
    L.append(" " * 20 + "-- NO blur key here on purpose. dock:blur_* all default to -1 =")
    L.append(" " * 20 + '-- "follow decoration:blur:*", which is the user\'s 2026-08-06')
    L.append(" " * 20 + "-- decision that every surface inherits Hyprland's own blur. A")
    L.append(" " * 20 + "-- derived number pinned here would replace that live inheritance")
    L.append(" " * 20 + "-- with a stale snapshot -- and could not make the frost better,")
    L.append(" " * 20 + "-- only later. Frost stays on, everywhere.")
    L.append(" " * 16 + "},")
    A("            },")
    A("        },")
    A("    })")
    A("end")
    return "\n".join(L) + "\n"


# -------------------------------------------------------------------- main --
def main(argv):
    ap = argparse.ArgumentParser(description="derive the hyprdrive theme fragment")
    ap.add_argument("--colors", default=DEFAULT_COLORS, help="matugen palette json")
    ap.add_argument("--dest", default=DEFAULT_DEST, help="fragment directory")
    ap.add_argument("--no-apply", action="store_true", help="write the fragment, do not reload")
    ap.add_argument("--print", dest="show", action="store_true", help="print the body, write nothing")
    a = ap.parse_args(argv[1:])

    colors = pathlib.Path(os.path.expanduser(a.colors))
    dest = pathlib.Path(os.path.expanduser(a.dest))

    palette = {}
    if colors.is_file():
        try:
            palette = json.loads(colors.read_text())
        except (OSError, ValueError) as e:
            palette = {}
            print("theme-sync: %s unreadable (%s) -- falling back to live values" % (colors, e), file=sys.stderr)

    live = {"border_accent": border_accent(), "bg_luma": bg_luma(),
            "blur": getoption("decoration:blur:enabled"),
            "blur_size": getoption("decoration:blur:size"),
            "blur_passes": getoption("decoration:blur:passes")}
    vals, notes = derive(palette, live)
    if vals is None:
        print("theme-sync: " + "; ".join(notes), file=sys.stderr)
        return 1

    leaves = [leaf for leaf, _, _ in DERIVED]
    pins = find_pins(dest, leaves) if dest.is_dir() else {}
    body = render(vals, pins, str(colors), notes)

    if a.show:
        sys.stdout.write(body)
        return 0

    # The machine half goes through fragment.py, the ONE implementation of the
    # raw-snippet contract, so a hand edit below the marker survives every
    # regeneration by construction rather than by this script remembering to.
    r = subprocess.run([sys.executable, str(FRAGMENT), "write", str(dest / NAME)],
                       input=body, text=True, capture_output=True)
    if r.returncode != 0:
        sys.stderr.write(r.stderr)
        return 1
    print(r.stdout.strip())

    applied = "skipped"
    if not a.no_apply:
        # Re-parse the whole chain: that is what re-applies pin > derived, and
        # what settles the race with the reload Hyprland's own config watch has
        # already fired on the file matugen wrote a moment ago -- that one
        # sourced the PREVIOUS derived values (see the header).
        applied = "reloaded" if hyprctl("reload") is not None else "no compositor"

    log = pathlib.Path(os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state"))) / "hyprdrive"
    log.mkdir(parents=True, exist_ok=True)
    # The second source, recorded every run. The dock's frost is not a number
    # this script derives -- dock:blur_* are -1 = follow decoration:blur:* -- so
    # the honest way to show the frost is still on is to write down what it is
    # inheriting. A `blur=off` line here is the user-law alarm: nothing in this
    # pipeline can turn compositor blur off, and nothing in it will turn it back
    # on either, so the log is where that has to become visible.
    live_note = "blur=%s/%s/%s" % (live.get("blur") or "?", live.get("blur_size") or "?",
                                  live.get("blur_passes") or "?")
    line = "%s %s accent=#%02x%02x%02x pill=#%02x%02x%02x alpha=%.2f masked=%s %s apply=%s" % (
        time.strftime("%Y-%m-%dT%H:%M:%S"), vals["mode"],
        *vals["col_highlight"], *vals["background_color"],
        vals["background_opacity"], ",".join(sorted(pins)) or "-", live_note, applied)
    if live.get("blur") == "false":
        notes.append("decoration:blur:enabled is FALSE -- the dock's frost follows it and is therefore off. "
                     "Frost is supposed to be on everywhere; this pipeline will not override it.")
    with (log / "theme-sync.log").open("a") as fh:
        fh.write(line + "\n")
    print("theme-sync: " + line)
    for n in notes:
        print("theme-sync: note: " + n)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
