"""Phase 8 drag A/B grader. Runs on the HOST (the guest has no numpy).

Three questions, in the order they have to be asked:

  FACTS     the drop dump, line for line. The 16 facts and the branch taken.
            Two runs of the same build first (the noise floor for a log that
            reads live state), then the two builds.
  OUTCOME   every fixture window's workspace, position and size after each
            drop, from hyprctl. This is the drag's actual product; it does not
            depend on the instrumentation at all.
  PIXELS    largest connected changed blob, 3x3 dilated, per settled frame.
            Same-build (run1 vs run2) is the noise floor; cross-build is only
            meaningful below it. The liveness row proves the frames are not
            all the same picture, or "identical" would mean nothing.

Usage: python3 p8_diff.py [dir]
"""
import json
import sys
import pathlib

import numpy as np
from PIL import Image

S = 4
THRESH = 12
LEGS = ("local", "move", "miss", "dock")
SHOTS = ("home", "over", "post")


def changed(a, b):
    A = np.asarray(Image.open(a).convert("RGB")).astype(int)
    B = np.asarray(Image.open(b).convert("RGB")).astype(int)
    if A.shape != B.shape:
        raise SystemExit(f"shape {A.shape} vs {B.shape}")
    return np.abs(A - B).max(axis=2) > THRESH


def dilate(mask):
    out = mask.copy()
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            out |= np.roll(np.roll(mask, dy, 0), dx, 1)
    return out


def largest_blob(mask):
    small = dilate(mask)[::S, ::S]
    if not small.any():
        return 0, None
    seen = np.zeros_like(small)
    best = []
    for sy, sx in zip(*np.where(small)):
        if seen[sy, sx]:
            continue
        stack, comp = [(sy, sx)], []
        seen[sy, sx] = True
        while stack:
            y, x = stack.pop()
            comp.append((y, x))
            for ny, nx in ((y - 1, x), (y + 1, x), (y, x - 1), (y, x + 1)):
                if 0 <= ny < small.shape[0] and 0 <= nx < small.shape[1] and small[ny, nx] and not seen[ny, nx]:
                    seen[ny, nx] = True
                    stack.append((ny, nx))
        if len(comp) > len(best):
            best = comp
    ys = [p[0] for p in best]
    xs = [p[1] for p in best]
    return len(best) * S * S, (min(xs) * S, min(ys) * S, (max(xs) - min(xs) + 1) * S, (max(ys) - min(ys) + 1) * S)


def facts(d, leg):
    """The dump lines that describe the DECISION, without the per-frame noise."""
    p = d / f"{leg}.dump"
    if not p.exists():
        return ["(no dump)"]
    return [ln for ln in p.read_text().splitlines() if ln.startswith(("DROP", "BRANCH", "PLACE"))]


def last_frame(d, leg):
    """The last drawn proxy state before the button came up: the settled gesture."""
    p = d / f"{leg}.dump"
    if not p.exists():
        return "(no dump)"
    fr = [ln for ln in p.read_text().splitlines() if ln.startswith("FRAME")]
    return fr[-1] if fr else "(no frames)"


def frames(d, leg):
    p = d / f"{leg}.dump"
    return sum(1 for ln in p.read_text().splitlines() if ln.startswith("FRAME")) if p.exists() else 0


def outcome(d, leg):
    p = d / f"{leg}-clients.json"
    rows = []
    for c in sorted(json.load(open(p)), key=lambda c: c["class"]):
        if c["class"].startswith("p8"):
            rows.append(f"{c['class']} ws={c['workspace']['id']} at={c['at']} size={c['size']} hidden={c.get('hidden')}")
    return rows


def cmp(label, a, b, get):
    bad = 0
    for leg in LEGS:
        x, y = get(a, leg), get(b, leg)
        ok = x == y
        bad += not ok
        print(f"  {label:<22} {leg:<6} {'IDENTICAL' if ok else 'DIFFER'}")
        if not ok:
            print(f"      {a.name}: {x}\n      {b.name}: {y}")
    return bad


if __name__ == "__main__":
    D = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    c1, c2, p1, p2 = (D / n for n in ("child1", "child2", "parent1", "parent2"))
    bad = 0

    print("-- FACTS: the 16 drop facts and the branch taken -------------------")
    bad += cmp("child1 vs child2", c1, c2, facts)
    bad += cmp("parent1 vs parent2", p1, p2, facts)
    bad += cmp("parent2 vs child2", p2, c2, facts)

    print("-- OUTCOME: where every window ended up -----------------------------")
    bad += cmp("child1 vs child2", c1, c2, outcome)
    bad += cmp("parent1 vs parent2", p1, p2, outcome)
    bad += cmp("parent2 vs child2", p2, c2, outcome)

    print("-- SETTLED GESTURE: last drawn proxy box before the release --------")
    for leg in LEGS:
        print(f"  {leg:<6} parent2 {last_frame(p2, leg)}")
        print(f"  {leg:<6} child2  {last_frame(c2, leg)}")
        print(f"  {leg:<6} drawn frames: parent2 {frames(p2, leg)}  child2 {frames(c2, leg)}")

    print("-- PIXELS: largest connected changed blob --------------------------")
    print("  LIVENESS (must be large -- the frames are not one picture)")
    for leg in LEGS:
        n, blob = 0, 0
        m = changed(c2 / f"{leg}-home.png", c2 / f"{leg}-over.png")
        blob, box = largest_blob(m)
        print(f"    child2 {leg:<6} home vs over   {int(m.sum()):>9} px   blob {blob:>8} px  {box}")

    noise = 0
    print("  NOISE FLOOR (same build, two runs)")
    for leg in LEGS:
        for shot in SHOTS:
            m = changed(c1 / f"{leg}-{shot}.png", c2 / f"{leg}-{shot}.png")
            blob, box = largest_blob(m)
            noise = max(noise, blob)
            print(f"    child1 vs child2 {leg:<6} {shot:<5} {int(m.sum()):>9} px   blob {blob:>8} px  {box}")

    pnoise = 0
    for leg in LEGS:
        for shot in SHOTS:
            m = changed(p1 / f"{leg}-{shot}.png", p2 / f"{leg}-{shot}.png")
            blob, _ = largest_blob(m)
            pnoise = max(pnoise, blob)
    print(f"    parent1 vs parent2 worst blob {pnoise} px")

    worst = 0
    print("  A/B (two builds, second run of each)")
    for leg in LEGS:
        for shot in SHOTS:
            m = changed(p2 / f"{leg}-{shot}.png", c2 / f"{leg}-{shot}.png")
            blob, box = largest_blob(m)
            worst = max(worst, blob)
            print(f"    parent2 vs child2 {leg:<6} {shot:<5} {int(m.sum()):>9} px   blob {blob:>8} px  {box}")

    print("--------------------------------------------------------------------")
    print(f"noise floor (same build) {max(noise, pnoise)} px, worst A/B blob {worst} px, dump/outcome mismatches {bad}")
    sys.exit(1 if bad else 0)
