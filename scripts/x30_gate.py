#!/usr/bin/env python3
"""OVERVIEW_CPP_SPEC 13.9 X30 gate. Runs on the HOST -- the guest has no numpy.

Measures the dock pill's POSITION in frames captured by scripts/x30_rig.sh. The
pill is 0.19-alpha frost, so it is found by an A/B against a control frame, the
way the X27 gate finds it, not by colour.

Every measured blob must also MATCH THE PILL'S SHAPE -- the width and centre
taken from the `dock-fixed` reference frame. That is what stops a blinking
caret or a repainting window from passing as a revealed dock, and it does the
job a noise mask does in X27 without needing control frames in the phases
(overview, fullscreen) where the whole screen repaints anyway.
"""
import sys

import numpy as np
from PIL import Image

D = "/home/dragos/hyprvm/share/x30"
BAND = 240  # the pill lives in the bottom of the monitor; everything above is noise
THRESH = 8

results = []


def load(name):
    return np.asarray(Image.open(f"{D}/{name}.png").convert("RGB")).astype(int)


def largest_blob(mask, anchored=False):
    """Biggest connected region, as (top, left, height, width, pixels).

    The bbox of every surviving pixel is not a shape: two unrelated specks give
    a box the size of the screen. The dock is one solid rectangle.

    `anchored` keeps only components that REACH THE BOTTOM of the band. The pill
    emerges from the bottom edge, so its blob always touches it; X47's hover
    preview panel floats a gap ABOVE the pill and never does. The pointer P6
    holds against the barrier is also sitting on the icon, so the panel rises
    mid-burst -- 310x152 at top=1412, 47007px, LARGER than the 502x64 pill it
    was covering -- and the two frames in the middle of the travel came back
    shape-mismatched, i.e. the one phase that measures the slide could not see
    it (measured 2026-08-13, zrig/danglingC/x30-slide-blobs.log).
    """
    seen = np.zeros_like(mask)
    best = []
    for seed in zip(*np.nonzero(mask)):
        if seen[seed]:
            continue
        stack, px = [seed], []
        seen[seed] = True
        while stack:
            y, x = stack.pop()
            px.append((y, x))
            for ny, nx in ((y - 1, x), (y + 1, x), (y, x - 1), (y, x + 1)):
                if 0 <= ny < mask.shape[0] and 0 <= nx < mask.shape[1] and mask[ny, nx] and not seen[ny, nx]:
                    seen[ny, nx] = True
                    stack.append((ny, nx))
        if anchored and max(p[0] for p in px) < mask.shape[0] - 8:
            continue
        if len(px) > len(best):
            best = px

    if not best:
        return (0, 0, 0, 0, 0)

    ys = [p[0] for p in best]
    xs = [p[1] for p in best]
    return (min(ys), min(xs), max(ys) - min(ys) + 1, max(xs) - min(xs) + 1, len(best))


def blob(frame, control, noise=None, anchored=False):
    """The largest changed region in the bottom band, in FULL-frame coords."""
    a = load(frame)[-BAND:]
    b = load(control)[-BAND:]
    mask = np.abs(a - b).sum(axis=2) > THRESH
    if noise is not None:
        mask &= ~noise
    top, left, h, w, n = largest_blob(mask, anchored)
    return (top + load(frame).shape[0] - BAND, left, h, w, n)


def noise_mask(controls):
    """Whatever moves while the dock is AWAY cannot be the dock."""
    frames = [load(c)[-BAND:] for c in controls]
    mask = np.zeros(frames[0].shape[:2], dtype=bool)
    for i in range(1, len(frames)):
        mask |= np.abs(frames[i] - frames[i - 1]).sum(axis=2) > THRESH
    # Churn does not land on the same pixel twice, so an exact mask leaks a
    # fringe. Grow it; the pill is hundreds of px of solid change and does not
    # care. (Same dilation as the X27 gate, same reason.)
    for _ in range(3):
        mask[1:] |= mask[:-1]
        mask[:-1] |= mask[1:]
        mask[:, 1:] |= mask[:, :-1]
        mask[:, :-1] |= mask[:, 1:]
    return mask


def check(name, ok, detail):
    results.append((name, ok, detail))
    print(f"{name}  {'PASS' if ok else 'FAIL'}  {detail}")


NOISE = noise_mask(["off1", "off2", "off3"])
print(f"noise mask (dock away, frame to frame): {int(NOISE.sum())} px excluded")

# The reference pill: autohide off, so it is simply out.
FTOP, FLEFT, FH, FW, FN = blob("fixed", "off2", NOISE)
print(f"reference pill (dock-fixed): top={FTOP} left={FLEFT} {FW}x{FH} ({FN}px)")
if FH < 20 or FW < 60:
    print("FAIL the dock never drew even with autohide off -- nothing to measure against")
    sys.exit(1)

FCX = FLEFT + FW / 2


def is_pill(b, tag, min_frac, max_frac):
    """Shape-matched against the reference pill, and how far out it is.

    A blob that does not match the pill's shape is not the pill -- a cursor, a
    caret -- so the dock is out by nothing. That reads the same way in both
    directions: it can never satisfy a 0.9-1.1 check, and it does not stop a
    "the dock is away" check from passing.
    """
    top, left, h, w, n = b
    shaped = h > 0 and w >= FW * 0.9 and abs((left + w / 2) - FCX) <= 12
    frac = h / FH if shaped else 0.0
    print(f"  {tag}: top={top} left={left} {w}x{h} ({n}px) out={frac:.2f}" + ("" if shaped or h == 0 else "  [SHAPE MISMATCH -> not the dock]"))
    return min_frac <= frac <= max_frac


# P1. Hidden by default. `fixed` above proves the same binary DOES draw a pill,
# so a pass here cannot come from a dock that is simply broken.
b = blob("off1", "off2", NOISE)
check("P1", is_pill(b, "idle", 0.0, 0.02), "autohide on: no pill on an idle desktop")

# P2a. require-pressure-to-show: sitting on the barrier is not enough.
b = blob("weak", "off2", NOISE)
check("P2a", is_pill(b, "weak push", 0.0, 0.02), "a sub-threshold push does NOT reveal")

# P2b. The SAME push with the threshold dropped under it. Without this pair the
# suite could not tell an enforced threshold from a hard-coded amount of shoving.
b = blob("lowthresh", "off2", NOISE)
ok = is_pill(b, "weak push, threshold 20", 0.9, 1.1) and abs(b[0] - FTOP) <= 4
check("P2b", ok, "the same push DOES reveal once pressure-threshold is lowered under it")

# P2c. ...and a real shove clears the stock threshold.
b = blob("strong", "off2", NOISE)
ok = is_pill(b, "strong push", 0.9, 1.1) and abs(b[0] - FTOP) <= 4
check("P2c", ok, f"a push past pressure-threshold reveals the pill at the reference y ({FTOP})")

# P3. hide-delay: leave and it goes away.
b = blob("leave", "off2", NOISE)
check("P3", is_pill(b, "pointer left", 0.0, 0.02), "the pill hides again once the pointer leaves")

# P4. Pinned in the overview despite autohide, with no pressure applied.
b = blob("ov_on", "ov_off")
ok = is_pill(b, "overview", 0.9, 1.1) and abs(b[0] - FTOP) <= 4
check("P4", ok, "the overview pins the dock out (clause 6) without a barrier push")

# P5. autohide-in-fullscreen: the barrier still works under a fullscreen window.
FSNOISE = noise_mask(["fs_ctl1", "fs_ctl2"])
b = blob("fs_on", "fs_ctl2", FSNOISE)
ok = is_pill(b, "fullscreen", 0.9, 1.1) and abs(b[0] - FTOP) <= 4
check("P5", ok, "pressure reveals the dock OVER a fullscreen window")

# P6. It slides. A teleport would show only 0.00 and 1.00 and never a frame in
# between -- which is exactly what this asks for, on a deliberately slowed
# animation so the transient can be photographed at all.
fracs = []
for i in range(1, 13):
    top, left, h, w, n = blob(f"slide{i}", "off2", NOISE, anchored=True)
    shaped = h == 0 or (w >= FW * 0.9 and abs((left + w / 2) - FCX) <= 12)
    fracs.append(h / FH if shaped else -1.0)
print("  slide fractions: " + " ".join(f"{f:.2f}" for f in fracs))
mid = [f for f in fracs if 0.15 <= f <= 0.85]
check("P6", len(mid) >= 2, f"{len(mid)} frame(s) caught mid-slide -- the pill travels, it does not teleport")

print()
failed = [n for n, ok, _ in results if not ok]
print(f"X30: {len(results) - len(failed)}/{len(results)} pass" + (f"  FAILED: {', '.join(failed)}" if failed else ""))
sys.exit(1 if failed else 0)
