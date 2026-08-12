"""G1 gate. Runs on the HOST -- the guest has no numpy or PIL.

    g1_gate.py <tag> [FRAMES_DIR]

Every assertion is a frame diff, because G1's claim is about a keystroke that
must change nothing. Two of the six frames MUST move, and they are what stops a
frozen output from passing: an output that hands back one frame forever fails
20-typed and 40-k_x rather than sailing through the no-op checks.

WHY THIS IS NOT A WHOLE-FRAME PIXEL COUNT ANY MORE (2026-08-12)
---------------------------------------------------------------
It used to be `(|a-b| > 8).sum() <= 400` over the whole frame, no mask and no
blob -- and this desktop is not still. Two things tick under the overview:

  * the quickshell BAR (a layer surface at the top of the output): its clock and
    its CPU/RAM/temperature readouts;
  * the ii DESKTOP CLOCK widget, which is drawn inside the fullscreen
    `quickshell:background` layer and shows through the overview. It ticks once
    a MINUTE, and a minute boundary landing inside the measured window is worth
    ~2000 changed pixels on its own -- five times the old floor.

So the old gate's verdict was decided by whether a clock edge fell in the
window, which is a function of WHEN it ran, not of the build: green when g1 ran
first after a compositor restart (quickshell's widgets are not up yet), red
mid-suite. Measured both ways on the same build; see zrig/danglingA/g1/.

The standing pixel doctrine replaces it:

  MASK    the chrome that is not the plugin. Every non-fullscreen layer-shell
          surface on the graded output comes out of `hyprctl layers -j`, which
          the rig dumps next to the frames -- the bar and the screen corners
          are found, not guessed. The desktop clock lives INSIDE the fullscreen
          background layer, so layers.json cannot describe it; its box is
          measured and pinned below. A mask big enough to hide a real change is
          a broken gate rather than a passing one, so both halves are leashed:
          the hand-written box at 1.5% of the frame and the whole mask at 8%
          (the bar alone is 3.9% of this output).
  DILATE  the change mask, so one real change is one component and not a
          hundred speckles.
  BLOB    grade the LARGEST 4-CONNECTED COMPONENT, never the total count and
          never a bounding box: a bbox spans the screen the moment one clock
          digit ticks in a corner.

The thresholds are set OUTSIDE the measured noise, not next to it. Measured on
HEAD 7b32fd6 at 2560x1600 (zrig/danglingA/g1/measurements.txt), with the mask
DISABLED so the numbers are worst-case:

    desktop clock, one minute tick .......  4224 -  5888 px blob
    'k' starts a search (ctrlA vs typed) . 1120496 px blob
    space types inside a query (kx/k_x) ..  130576 px blob

QUIET is 25000 px -- four times the worst noise ever measured here and five
times under the smallest real change. With the mask on, every quiet row scores
0. LOUD is 50000 px, which no noise source in this session can reach.
"""
import json
import pathlib
import sys

import numpy as np
from PIL import Image

S = 4        # downsample for the label pass [diffblob.py:32]
DILATE = 2   # in downsampled cells, ~8px [diffblob.py:33]

QUIET = 25000    # largest blob a "this changed nothing" row may show
LOUD = 50000     # largest blob a "this had to change" row must beat

# The ii desktop clock widget, measured at 2560x1600 on 2026-08-12: its minute
# tick is a 92x92..116x104 blob at (1284..1312, 376..388). Padded generously --
# it is a mask, not a locator, and the QUIET threshold above is set so the gate
# is still right if this box misses the widget entirely.
CLOCK_BOX = (1244, 336, 200, 184)   # x, y, w, h
CLOCK_REF = (2560, 1600)            # the frame size that box was measured on


def load(out, tag, name):
    return np.asarray(Image.open(out / f"{tag}-{name}.png").convert("RGB")).astype(np.int16)


def dilate(mask, n):
    out = mask.copy()
    for _ in range(n):
        p = np.pad(out, 1, constant_values=False)
        out = (p[:-2, 1:-1] | p[2:, 1:-1] | p[1:-1, :-2] | p[1:-1, 2:] | p[1:-1, 1:-1])
    return out


def largest(mask):
    """Area in cells of the biggest 4-connected component, plus its box."""
    seen = np.zeros_like(mask)
    best, best_n = None, 0
    for sy, sx in zip(*np.where(mask)):
        if seen[sy, sx]:
            continue
        stack, comp = [(sy, sx)], []
        seen[sy, sx] = True
        while stack:
            y, x = stack.pop()
            comp.append((y, x))
            for ny, nx in ((y - 1, x), (y + 1, x), (y, x - 1), (y, x + 1)):
                if 0 <= ny < mask.shape[0] and 0 <= nx < mask.shape[1] \
                        and mask[ny, nx] and not seen[ny, nx]:
                    seen[ny, nx] = True
                    stack.append((ny, nx))
        if len(comp) > best_n:
            best, best_n = comp, len(comp)
    if best is None:
        return 0, (0, 0, 0, 0)
    a = np.array(best)
    return best_n, (int(a[:, 1].min()) * S, int(a[:, 0].min()) * S,
                    int(a[:, 1].max() - a[:, 1].min() + 1) * S,
                    int(a[:, 0].max() - a[:, 0].min() + 1) * S)


def build_mask(out, shape):
    """True where a pixel is CHROME THAT TICKS and must not decide this gate."""
    h, w = shape
    m = np.zeros((h, w), bool)
    notes = []

    # Layer-shell surfaces, from the compositor rather than from memory. The
    # fullscreen background layer is skipped: it IS the wallpaper the overview
    # is drawn over, and masking it would mask the whole claim.
    lp = out / "layers.json"
    if lp.exists():
        for mon, v in json.loads(lp.read_text()).items():
            for lvl, surfaces in v.get("levels", {}).items():
                for s in surfaces:
                    if s["w"] * s["h"] >= 0.5 * w * h:
                        continue
                    x0, y0 = max(0, s["x"]), max(0, s["y"])
                    x1, y1 = min(w, s["x"] + s["w"]), min(h, s["y"] + s["h"])
                    if x1 > x0 and y1 > y0:
                        m[y0:y1, x0:x1] = True
                        notes.append(f"{s['namespace']} {s['w']}x{s['h']}@{s['x']},{s['y']}")
    else:
        notes.append("NO layers.json -- only the pinned clock box is masked")

    cx, cy, cw, ch = CLOCK_BOX
    sx, sy = w / CLOCK_REF[0], h / CLOCK_REF[1]
    x0, y0 = int(cx * sx), int(cy * sy)
    x1, y1 = min(w, int((cx + cw) * sx)), min(h, int((cy + ch) * sy))
    m[y0:y1, x0:x1] = True
    notes.append(f"desktop clock {x1-x0}x{y1-y0}@{x0},{y0}  (PINNED, hand-written)")
    return m, notes, (x1 - x0) * (y1 - y0)


def grade(out, fr, rows, label):
    """Mask, dilate, blob, one table. True iff every row passed.

    `rows` are (claim, frame-label, a, b, "quiet"|"loud"). This is shared with
    gates/g1/g1c_grade.py rather than transcribed into it: the compose arm was
    still diffing whole unmasked frames against a 400 px floor on 2026-08-12,
    which is the same defect this file was rewritten to remove, and a doctrine
    that exists in two copies drifts back apart. One implementation, two arms.
    """
    h, w = fr[rows[0][2]].shape[:2]
    mask, notes, pinned = build_mask(out, (h, w))
    pct = 100.0 * mask.sum() / (h * w)
    ppct = 100.0 * pinned / (h * w)
    print(f"frame {w}x{h}   mask {mask.sum()} px = {pct:.2f}%  (pinned {ppct:.2f}%)")
    for n in notes:
        print(f"  masked: {n}")
    # Two ceilings, and the tight one is on the hand-written box. The layer-shell
    # part is the compositor's own report of what another process is drawing on
    # this output and is as big as the bar is; the pinned part is the only place
    # a mask could be grown to hide a failure, so that is where the leash goes.
    if ppct > 1.5:
        print(f"MASK     the pinned clock box is {ppct:.2f}% of the frame -- a hand-written "
              "mask that big can hide the very change this gate exists to catch")
        print(f"{label}: FAIL (MASK)")
        return False
    if pct > 8.0:
        print(f"MASK     {pct:.2f}% of the frame is masked -- too much of the output is "
              "somebody else's chrome for this measurement to mean anything")
        print(f"{label}: FAIL (MASK)")
        return False

    keep = ~mask

    def measure(a, b):
        ident = bool(np.array_equal(fr[a], fr[b]))
        d = np.abs(fr[a] - fr[b]).max(axis=2)
        raw = (d > 8)
        m = raw & keep
        cells, box = largest(dilate(m[::S, ::S], DILATE))
        return {"identical": ident, "raw": int(raw.sum()), "changed": int(m.sum()),
                "blob": cells * S * S, "box": box}

    cw = max(len(r[0]) for r in rows)
    fw = max(len(r[1]) for r in rows)
    print()
    print(f"{'claim':{cw}} {'frames':{fw}} {'raw':>8} {'masked':>8} {'blob':>9}  verdict")
    ok_all = True
    for claim, flabel, a, b, kind in rows:
        r = measure(a, b)
        if kind == "quiet":
            ok = r["blob"] <= QUIET
            why = "" if ok else f"  <- blob {r['blob']} at {r['box']} exceeds QUIET={QUIET}"
        else:
            # A frozen output hands back byte-identical frames; that is an
            # explicit failure of a must-move row, never a silent zero.
            ok = (not r["identical"]) and r["blob"] >= LOUD
            why = "" if ok else ("  <- IDENTICAL FRAMES" if r["identical"]
                                 else f"  <- blob {r['blob']} under LOUD={LOUD}")
        ok_all &= ok
        print(f"{claim:{cw}} {flabel:{fw}} {r['raw']:>8} {r['changed']:>8} {r['blob']:>9}  "
              f"{'PASS' if ok else 'FAIL'}{why}")

    print()
    print(f"{label}: PASS" if ok_all else f"{label}: FAIL")
    return ok_all


def main(argv):
    tag = argv[1] if len(argv) > 1 else "post"
    out = pathlib.Path(argv[2]) if len(argv) > 2 else pathlib.Path("/home/dragos/hyprvm/share/g1")

    names = ["00-ctrlA", "01-ctrlB", "10-space", "20-typed", "30-kx", "40-k_x", "50-nostart"]
    fr = {n: load(out, tag, n) for n in names}

    rows = [
        ("SPACE on an empty query is a no-op", "ctrlA vs 10-space", "00-ctrlA", "10-space", "quiet"),
        ("no drift between two idle frames", "ctrlA vs 01-ctrlB", "00-ctrlA", "01-ctrlB", "quiet"),
        ("LIVENESS: 'k' does start a search", "ctrlA vs 20-typed", "00-ctrlA", "20-typed", "loud"),
        ("SPACE types once a search is active", "30-kx vs 40-k_x", "30-kx", "40-k_x", "loud"),
        ("TAB/BACKSPACE/F5 start no search", "ctrlA vs 50-nostart", "00-ctrlA", "50-nostart", "quiet"),
    ]
    return 0 if grade(out, fr, rows, "G1 GATE") else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
