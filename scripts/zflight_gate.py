#!/usr/bin/env python3
"""Z4/Z5 film gates, on the HOST (guest has no numpy).

z4: no hole at restore landing. Once the green area first exceeds 50% of its
final steady value, it must never fall below 25% of steady until the film ends.
The pre-fix build erased the proxy a frame before the real window drew, which
reads as exactly such a dip.

z5: continuity under spam. The largest green blob's centroid must never jump
more than JUMP_PX between consecutive frames it exists in -- the pre-fix build
restarted a reversed flight from the icon, a ~700px teleport.
"""
import glob, sys
sys.path.insert(0, '/home/dragos/hyprvm')  # blob.py copied here
from blob import largest_green
import numpy as np
from PIL import Image

MODE = sys.argv[1]
frames = sorted(glob.glob(f'/tmp/zrig/{MODE}-*.png'))
if MODE in ('z4', 'z4t', 'z5'):
    assert len(frames) > 30, f'only {len(frames)} frames -- film too short to judge'

def green_count(p):
    im = np.asarray(Image.open(p).convert('RGB')).astype(int)
    m = (im[:, :, 1] > 150) & (im[:, :, 0] < 110) & (im[:, :, 2] < 110)
    return int(m.sum())

if MODE in ('z4', 'z4t'):
    counts = [green_count(p) for p in frames]
    steady = max(np.mean(counts[-8:]), 1.0)
    assert steady > 50000, f'steady={steady:.0f}px is a dock cell, not a restored window -- the restore click missed; rig fault'
    started = False
    holes = []
    for i, c in enumerate(counts):
        if not started and c > 0.5 * steady:
            started = True
        elif started and c < 0.25 * steady:
            holes.append((i, c))
    assert started, 'restore never reached 50% of steady -- rig fault, not a pass'

    # Z17 flash detector: a landing hand-off seam is one frame that differs
    # sharply from BOTH neighbours while the neighbours agree (the proxy->real
    # swap measured 3.2M luminance delta). Motion itself never trips this: in
    # motion the neighbours disagree with each other too.
    grey = [np.asarray(Image.open(p).convert('L')).astype(int) for p in frames[-60:]]
    flashes = []
    for i in range(1, len(grey) - 1):
        d1 = int(np.abs(grey[i] - grey[i-1]).sum())
        d2 = int(np.abs(grey[i+1] - grey[i]).sum())
        d3 = int(np.abs(grey[i+1] - grey[i-1]).sum())
        if min(d1, d2) > 800_000 and (d1 + d2) / 2 > 1.5 * max(d3, 1):
            flashes.append((len(frames) - 60 + i, d1, d2, d3))
    ok = not holes and not flashes
    print(f'{MODE} {"PASS" if ok else "FAIL"}: steady={steady:.0f}px holes={holes[:3]} flashes={flashes[:3]}')
    sys.exit(0 if ok else 1)

if MODE == 'z5log':
    # The drawn-box log is the instrument: at every reversal, the first box the
    # reversed flight draws must sit where the old flight's last box was. The
    # pre-fix build restarted from the icon (~700px away); a screenshot metric
    # cannot make this call because a 400ms EASE_OUT_EXPO legitimately moves
    # ~900px between two 30fps film frames.
    import re as _re
    lines = open('/home/dragos/hyprvm/share/zrig/ovdbg.log').read().splitlines()
    draws, reversals = [], []
    for i, l in enumerate(lines):
        if l.startswith('draw ') or l.startswith('drive '):
            m = _re.findall(r'-?\d+\.?\d*', l)
            draws.append((i, float(m[1]), float(m[2]), float(m[3]), float(m[4])))
        elif l.startswith('reverse') and 'found=1' in l:
            reversals.append(i)
    assert len(reversals) >= 2, f'only {len(reversals)} reversals -- spam did not hit mid-flight'
    # Timing-immune: a fixed pixel limit tripped on frame starvation (a 248px
    # first step is just expo across a 2-3 frame gap). The invariant that
    # separates a CONTINUED flight from a RESTARTED one: the first draw after
    # a reversal is never FARTHER from the new motion's endpoint than the last
    # draw before it -- a restart jumps back toward the far end.
    worst = -1e9
    for r in reversals:
        before = [d for d in draws if d[0] < r]
        after  = [d for d in draws if d[0] > r]
        assert before and after, 'reversal without draws around it'
        seg_end = next((i for i in reversals if i > r), None)
        seg     = [d for d in after if seg_end is None or d[0] < seg_end]
        end     = seg[-1]
        ec      = (end[1] + end[3] / 2, end[2] + end[4] / 2)
        def dist(d):
            return ((d[1] + d[3] / 2 - ec[0]) ** 2 + (d[2] + d[4] / 2 - ec[1]) ** 2) ** 0.5
        regress = dist(after[0]) - dist(before[-1])
        worst   = max(worst, regress)
    verdict = 'FAIL' if worst > 40 else 'PASS'
    print(f'z5log {verdict}: {len(reversals)} reversals, worst regression toward the far end {worst:.1f}px (limit 40; continuation is negative)')
    sys.exit(1 if worst > 40 else 0)

if MODE == 'z5':
    JUMP_PX = 350
    MIN_AREA = 15000   # ignore dock-cell-sized blobs: identity flips to the
                       # dock cell are legit (fade-out done), not teleports
    last, worst = None, (0.0, -1)
    for i, p in enumerate(frames):
        b = largest_green(p)
        if b is None or b[2] * b[3] < MIN_AREA:
            last = None
            continue
        c = (b[0] + b[2] / 2.0, b[1] + b[3] / 2.0)
        if last is not None:
            d = ((c[0] - last[0]) ** 2 + (c[1] - last[1]) ** 2) ** 0.5
            if d > worst[0]:
                worst = (d, i)
        last = c
    print(f'z5 {"FAIL" if worst[0] > JUMP_PX else "PASS"}: worst jump {worst[0]:.0f}px at frame {worst[1]} (limit {JUMP_PX})')
    sys.exit(1 if worst[0] > JUMP_PX else 0)
