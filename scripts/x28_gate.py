#!/usr/bin/env python3
"""OVERVIEW_CPP_SPEC 13.9 X28 acceptance gate. Runs ON THE HOST (the guest has
no numpy/PIL), driving the guest over ./g and reading back /mnt/host/x28.

It drives rather than just scores because every click coordinate after the
first depends on geometry measured from the previous frame: the menu's row
height comes out of renderText, so the only honest way to hit a row is to make
the compositor show you where it is (hover highlight) and click that.

  P1  right-click on a dock icon draws a plate ABOVE the pill
  P2  a left press in the pill gutter dismisses it (frame returns to base)
  P3  the bottom row is Quit -- every window of the class closes
  P4  the favourites row writes then removes the app's desktop id

Rows are found from the SEPARATOR LINES the compositor drew, not from arithmetic
over MENU_ROW_PAD_Y: a row's height is whatever renderText returned, so
predicting it would only prove the gate can copy a constant. The plate's bottom
edge IS predicted (pill.y - MENU_GAP), because that one is pure layout and a
regression there should miss.

P2 doubles as P1's control: same detector, same pair of frames, no plate
expected. If the diff detector were firing on compositor noise, base-vs-
dismissed would light up too.
"""
import json
import subprocess
import sys

import numpy as np
from PIL import Image

VM = "/home/dragos/hyprvm"
OUT = VM + "/share/x28"
S = 4  # blob labelling downsample; there is no scipy here


def g(cmd, timeout=180):
    r = subprocess.run(["./g", cmd], cwd=VM, capture_output=True, text=True, timeout=timeout)
    sys.stdout.write(r.stdout)
    if r.returncode:
        sys.stdout.write(r.stderr)
    return r.stdout


def largest_diff(a, b, thresh=26):
    """(x, y, w, h, area) of the biggest changed region between two pngs."""
    A = np.asarray(Image.open(a).convert("RGB")).astype(int)
    B = np.asarray(Image.open(b).convert("RGB")).astype(int)
    mask = np.abs(A - B).max(axis=2) > thresh

    small = mask[::S, ::S]
    # Dilate on the downsample: antialiased text is speckle, and a plate split
    # into forty letter-sized components would score as forty tiny blobs.
    d = small.copy()
    for sh in (1, -1):
        d |= np.roll(small, sh, 0)
        d |= np.roll(small, sh, 1)
    small = d
    if not small.any():
        return (0, 0, 0, 0, 0)

    seen = np.zeros_like(small)
    best, best_n = None, 0
    for sy, sx in zip(*np.where(small)):
        if seen[sy, sx]:
            continue
        stack, comp = [(sy, sx)], []
        seen[sy, sx] = True
        while stack:
            y, x = stack.pop()
            comp.append((y, x))
            for ny, nx in ((y - 1, x), (y + 1, x), (y, x - 1), (y, x + 1)):
                if 0 <= ny < small.shape[0] and 0 <= nx < small.shape[1] \
                        and small[ny, nx] and not seen[ny, nx]:
                    seen[ny, nx] = True
                    stack.append((ny, nx))
        if len(comp) > best_n:
            best, best_n = comp, len(comp)

    ys, xs = np.array(best).T
    return (xs.min() * S, ys.min() * S,
            (xs.max() - xs.min() + 1) * S, (ys.max() - ys.min() + 1) * S,
            best_n * S * S)


def separators(png, cx, top, bottom):
    """y of every separator line in the plate, top-down.

    A separator is one solid row across the plate, so it lifts the row MINIMUM;
    a row of text does not, because there is background between the glyphs.
    """
    m = np.asarray(Image.open(png).convert("RGB")).astype(int).mean(2)
    mn = m[top:bottom, cx - 60:cx + 60].min(axis=1)
    return [top + i for i in range(3, len(mn) - 3)
            if mn[i] > mn[i - 3] + 12 and mn[i] > mn[i + 3] + 12]


def cell(target, mw, mh, clients_from="fixture-clients"):
    """Predict a dock cell. `clients_from` names WHICH client list to predict
    against, and it matters after P3: quitting both X28QUIT windows takes a
    class out of the dock, so the pill recentres and every icon moves. Measured
    2026-08-12 -- predicted against the fixture's two classes the kitty icon
    came out at x=1245 when the one-class dock puts it at 1280, so P4's
    right-click landed in the gutter, no menu opened, and an empty favourites
    file was reported as a plugin defect."""
    clients = open("%s/%s.json" % (OUT, clients_from)).read()
    r = subprocess.run([sys.executable, VM + "/share/x28_cell.py", target, str(mw), str(mh)],
                       input=clients, capture_output=True, text=True)
    if r.returncode:
        sys.exit("cell %s: %s" % (target, r.stderr.strip()))
    return [int(v) for v in r.stdout.split()]


def click(button, x, y, name):
    g("bash /mnt/host/x28_click_at.sh %s %d %d %s" % (button, x, y, name))
    return "%s/%s.png" % (OUT, name)


def nwindows(name, wmclass):
    return sum(1 for c in json.load(open("%s/clients-%s.json" % (OUT, name)))
               if c["class"] == wmclass)


def favorites(name):
    return open("%s/favorites-%s.txt" % (OUT, name)).read().split()


fails = []


def check(tag, ok, detail):
    print("%-4s %-4s %s" % (tag, "PASS" if ok else "FAIL", detail))
    if not ok:
        fails.append(tag)


out = g("bash /mnt/host/x28_fixture.sh", timeout=300)
if "X28_FIXTURE_OK" not in out:
    sys.exit("fixture did not complete")

_, MONNAME, MW, MH = open(OUT + "/monitor.txt").read().split()
MW, MH = int(MW), int(MH)
PILLX, PILLY, PILLW, PILLH = cell("pill", MW, MH)
print("monitor %s %dx%d  pill %d,%d %dx%d" % (MONNAME, MW, MH, PILLX, PILLY, PILLW, PILLH))

BASE = OUT + "/base.png"

MENU_GAP = 8  # Dock.cpp
PLATEBOT = PILLY - MENU_GAP

# ---- P1 -------------------------------------------------------------------
qx, qy = cell("X28QUIT", MW, MH)
menu = click("right", qx, qy, "menu")
x, y, w, h, area = largest_diff(BASE, menu)
check("P1", area > 8000 and w > 120 and h > 80 and y + h <= PILLY + 8,
      "plate %d,%d %dx%d area=%d (pill top y=%d)" % (x, y, w, h, area, PILLY))
if "P1" in fails:
    sys.exit("P1 failed; the rest of the gate has nothing to click")

# ---- P2 (and P1's control) ------------------------------------------------
gx, gy = cell("gutter", MW, MH)
dismiss = click("left", gx, gy, "dismiss")
_, _, dw, dh, darea = largest_diff(BASE, dismiss)
# "NO PLATE IS THERE", by P1's own definition of a plate, rather than "less than
# an eighth of one". The eighth was a straddler: the residual is the pointer's
# own hover highlight sitting in the gutter where the dismiss press left it, and
# it measured 608 px on one run and 2720 px on the next against a 2448 px line
# (2026-08-12). Neither is a plate -- P1 requires area > 8000 AND w > 120 AND
# h > 80 -- and failing that test is the thing this phase means.
notplate = not (darea > 8000 and dw > 120 and dh > 80)
check("P2", notplate and darea < area // 2,
      "residual after dismiss %dx%d area=%d vs plate %d -- %s"
      % (dw, dh, darea, area, "no plate" if notplate else "STILL A PLATE"))

# ---- P3 -------------------------------------------------------------------
click("right", qx, qy, "menu2")
click("left", qx, PLATEBOT - 8, "quit")
check("P3", nwindows("quit", "X28QUIT") == 0,
      "X28QUIT windows left = %d" % nwindows("quit", "X28QUIT"))

# ---- P4 -------------------------------------------------------------------
# A FRESH base, because P3 just closed both X28QUIT windows. The overview
# relaid out around the two it lost, so diffing the kitty menu against the
# ORIGINAL base returns the whole card -- measured 2026-08-12: "kitty plate
# 556,444 1452x1156" for a plate that is 176x112. The separator hunt then ran
# over the whole overview, the favourites row was clicked 400px off, and P4
# reported an empty favourites file as a plugin defect. A gutter press is the
# swallowed no-op P2 already relies on, so it captures the new resting frame
# without changing anything.
# The GUTTER moves too. With both X28QUIT windows gone the pill is 82px wide at
# x1239, and the gutter predicted off the two-class fixture (x1206) is outside
# the dock altogether -- a press there is a press on the overview, not a
# swallowed one, and the frame it captures is not a resting dock.
gx2, gy2 = cell("gutter", MW, MH, "clients-quit")
BASE2 = click("left", gx2, gy2, "base2")

kx, ky = cell("kitty", MW, MH, "clients-quit")
km = click("right", kx, ky, "kmenu")
kxx, kyy, kww, khh, karea = largest_diff(BASE2, km)
seps = separators(km, kx, kyy + 4, PLATEBOT)
print("     kitty plate %d,%d %dx%d separators %r" % (kxx, kyy, kww, khh, seps))
if not seps:
    sys.exit("no separator found in the kitty menu; cannot locate the favourites row")
FAVY = seps[-1] - 12  # just above the last separator band == the Favorites row

# The store is compared against ITSELF BEFORE THE TOGGLE, not against empty.
# The fixture deletes $RIG_FAV, and an absent store does not mean "no
# favourites" -- the plugin seeds the session's defaults into it, so this read
# "after add=['org.gnome.Nautilus', 'org.gnome.TextEditor', 'org.gnome.Ptyxis',
# 'kitty']" and called a working toggle a failure. What the clause actually
# claims is that the row ADDS the app's desktop id and the same row REMOVES it,
# leaving everything else where it was.
# The two STORES are compared with each other, not with "empty". The fixture
# deletes $RIG_FAV and an absent store does not mean "no favourites": the plugin
# holds the session's defaults and only WRITES the file once something is
# toggled, so the read before the toggle is [] while the dock is showing three.
# The clause is that the row adds the app's desktop id and the same row takes it
# away again, leaving everything else alone -- which is exactly the difference
# between these two files.
click("left", kx, FAVY, "fav1")
added = favorites("fav1")
click("right", kx, ky, "kmenu2")
click("left", kx, FAVY, "fav2")
removed = favorites("fav2")
gone = set(added) - set(removed)
check("P4",
      len(gone) == 1 and "kitty" in gone.copy().pop().lower() and set(removed) < set(added),
      "after add=%r after remove=%r (the row toggled %r)" % (added, removed, sorted(gone)))

print("\nX28 GATE: %s" % ("PASS" if not fails else "FAIL " + ",".join(fails)))
sys.exit(1 if fails else 0)
