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
if MODE in ('z4', 'z5'):
    assert len(frames) > 30, f'only {len(frames)} frames -- film too short to judge'

def green_count(p):
    im = np.asarray(Image.open(p).convert('RGB')).astype(int)
    m = (im[:, :, 1] > 150) & (im[:, :, 0] < 110) & (im[:, :, 2] < 110)
    return int(m.sum())

if MODE == 'z4':
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
    print(f'z4 {"FAIL" if holes else "PASS"}: steady={steady:.0f}px holes={holes[:5]}')
    sys.exit(1 if holes else 0)

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
        if l.startswith('draw '):
            m = _re.findall(r'-?\d+\.?\d*', l)
            draws.append((i, float(m[1]), float(m[2]), float(m[3]), float(m[4])))
        elif l.startswith('reverse') and 'found=1' in l:
            reversals.append(i)
    assert len(reversals) >= 2, f'only {len(reversals)} reversals -- spam did not hit mid-flight'
    worst = 0.0
    for r in reversals:
        before = [d for d in draws if d[0] < r]
        after  = [d for d in draws if d[0] > r]
        assert before and after, 'reversal without draws around it'
        b, a = before[-1], after[0]
        dc = ((b[1]+b[3]/2 - (a[1]+a[3]/2))**2 + (b[2]+b[4]/2 - (a[2]+a[4]/2))**2) ** 0.5
        worst = max(worst, dc)
    print(f'z5log {'FAIL' if worst > 150 else 'PASS'}: {len(reversals)} reversals, worst centre discontinuity {worst:.1f}px (limit 150)')
    sys.exit(1 if worst > 150 else 0)

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
