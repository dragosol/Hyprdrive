#!/usr/bin/env python3
"""Z4/Z5 film gates, on the HOST (guest has no numpy).

z4: no hole at restore landing. Once the green area first exceeds 50% of its
final steady value, it must never fall below 25% of steady until the film ends.
The pre-fix build erased the proxy a frame before the real window drew, which
reads as exactly such a dip.

z5: continuity under spam. The largest green blob's centroid must never jump
more than JUMP_PX between consecutive frames it exists in -- the pre-fix build
restarted a reversed flight from the icon, a ~700px teleport. The dock's own
live preview of the fixture is excluded first; it is a second green image of the
same window and the crown passing to it is not motion (see the z5 block).

z5log: the same claim, on the instrument that can actually carry it -- the
plugin's own drawn-box log. Pixels cannot separate a 400ms EASE_OUT_EXPO from a
teleport at 30fps; the log can, and it is what proves a reversal CONTINUES the
old flight rather than restarting it.
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
    #
    # The plugin's zdbg writes $XDG_RUNTIME_DIR/ovdbg.log in the guest
    # (DebugPaths.hpp; /tmp/ovdbg.log from builds before it, or with no
    # runtime dir). The host path last is where this arm used to be read from
    # when the grader ran host-side; kept as a fallback so a host-side replay of
    # a copied log still works. FLIGHT_LOG overrides them all, which is what the
    # mutation control uses.
    import os as _os
    import re as _re
    _cands = [p for p in (_os.environ.get('FLIGHT_LOG'),
                          _os.path.join(_os.environ.get('XDG_RUNTIME_DIR', '/run/user/%d' % _os.getuid()), 'ovdbg.log'),
                          '/tmp/ovdbg.log',
                          '/home/dragos/hyprvm/share/zrig/ovdbg.log') if p]
    _log = next((p for p in _cands if _os.path.exists(p)), None)
    assert _log, 'no flight log: %s -- dock:flight_log was never on' % (_cands,)
    lines = open(_log).read().splitlines()
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

if MODE == 'z5phase':
    # The same clicks again, read as a STATE MACHINE rather than as boxes.
    # FlightController writes a typed transition for every flight it creates,
    # advances, lands or aborts, so the claims below are read off the log
    # directly instead of being inferred from what was drawn:
    #
    #   1. every flight that is armed is ACCOUNTED FOR -- it either reaches Done
    #      (it landed, or something aborted it, and either way the landing ran)
    #      or it is superseded by a named successor, which is what a reversal
    #      does: the old flight hands its drawn box and its hidden lease to the
    #      new one and stops existing. A flight that is neither is the strand
    #      class (Z9/Z18: a window left hidden, stashed, or mid-geometry) and
    #      there is no phase for it. Three flights per z5 run, two of them
    #      superseded, one landing -- that is what a spam of three clicks IS;
    #   2. every landing runs the invariant and passes it (value == goal, and on
    #      a floating window the layout target too) -- Z18b was exactly this
    #      check failing silently on the second cycle;
    #   3. no reversal is a silent bail: a reverse that FOUND a flight either
    #      swaps it (a new flight seeded from the old one) or completes it on the
    #      spot. Both bails that used to live there ended in the wrong state.
    import os as _os
    import re as _re
    _cands = [p for p in (_os.environ.get('FLIGHT_LOG'),
                          _os.path.join(_os.environ.get('XDG_RUNTIME_DIR', '/run/user/%d' % _os.getuid()), 'ovdbg.log'),
                          '/tmp/ovdbg.log',
                          '/home/dragos/hyprvm/share/zrig/ovdbg.log') if p]
    _log = next((p for p in _cands if _os.path.exists(p)), None)
    assert _log, 'no flight log: %s -- dock:flight_log was never on' % (_cands,)
    lines = open(_log).read().splitlines()

    armed, done, lands, bad_land = {}, set(), {}, []
    superseded = set()   # flights a reversal consumed, by the successor's own line
    reversals, unresolved = [], []
    for i, l in enumerate(lines):
        if l.startswith('phase '):
            m = _re.search(r'id=(\d+).*?(?:(\w+)->)?(Armed|Flying|LandingBridge|Done)\b', l)
            if not m:
                continue
            fid, to = int(m.group(1)), m.group(3)
            if to == 'Armed':
                armed[fid] = i
                old = _re.search(r'reason=reversal-of-(\d+)', l)
                if old:
                    superseded.add(int(old.group(1)))
            elif to == 'Done':
                done.add(fid)
        elif l.startswith('land '):
            m = _re.search(r'id=(\d+)', l)
            if m:
                fid = int(m.group(1))
                lands[fid] = l
                if 'ok=0' in l:
                    bad_land.append(l)
        elif l.startswith('reverse') and 'found=1' in l:
            reversals.append(i)

    for r in reversals:
        # what the reversal did, in the two lines after it
        window = '\n'.join(lines[r + 1:r + 3])
        if 'reason=reversal-of-' in window or 'reason=reversed-while-landing' in window:
            continue
        unresolved.append(lines[r])

    stranded = sorted(set(armed) - done - superseded)
    ok = bool(armed) and bool(reversals) and not stranded and not bad_land and not unresolved
    print(f'z5phase {"PASS" if ok else "FAIL"}: {len(armed)} flights armed, {len(done)} landed, '
          f'{len(superseded)} superseded by a reversal, {len(stranded)} unaccounted for; '
          f'{len(reversals)} reversals ({len(unresolved)} that neither swapped nor completed), '
          f'{len(lands)} landings ({len(bad_land)} failed their invariant)')
    for l in bad_land[:3]:
        print('  landing invariant FAILED: ' + l)
    for l in unresolved[:3]:
        print('  reversal neither swapped nor completed: ' + l)
    if stranded:
        print('  armed, never landed, never superseded: %s' % stranded[:8])
    if not armed:
        print('  no flights in the log at all -- flight_log off, or the clicks missed')
    if not reversals:
        print('  no reversal found -- the spam did not land inside a flight, so this proves nothing')
    sys.exit(0 if ok else 1)

if MODE == 'z5':
    MIN_AREA = 15000   # ignore dock-cell-sized blobs: identity flips to the
                       # dock cell are legit (fade-out done), not teleports

    # THE LIMIT IS THE CURVE'S OWN WORST FRAME, not a round number.
    #
    # 350px was one, and the shipping animation goes through it every time it is
    # sampled slightly late: the flight is EASE_OUT_EXPO over dock:minimize_ms
    # (400ms, spec 13.14 Y5), the film is 30fps (z_rig.sh's wf-recorder -r 30),
    # so ONE frame at the start of a flight covers E(1/30 / 0.4) = 1 - 2^(-0.83)
    # = 0.44 of the whole distance. Measured 2026-08-12 on four runs of two
    # builds -- 216px, 281px, 295px, 401px, every one of them at the second
    # frame of the FIRST minimize and none of them a reversal -- and the 401 is
    # frame 91->92 of B2: box (640,376,756,472) -> (916,888,264,248), a proxy
    # shrinking 756px wide to 264 while its centre falls 400px. That is the
    # animation working.
    #
    # So the limit is derived per run from what the film itself shows: the
    # distance the flight has to cover (rest centre -> the dock's own preview,
    # both already located below) times the curve's first-frame share, with half
    # again for sampling jitter. On this fixture that is ~610px, and the defect
    # this arm exists to catch -- a reversal RESTARTING FROM THE ICON, which is
    # the whole distance in one frame -- is ~920px, so the gap is real. The arm
    # that carries the claim precisely is z5log, on the plugin's own boxes;
    # pixels at 30fps cannot separate a fast curve from a jump on their own.
    FILM_FPS      = 30.0    # z_rig.sh: wf-recorder -f ... -r 30
    FLIGHT_MS     = 400.0   # Config.cpp dock:minimize_ms, the shipping default
    JITTER_FACTOR = 1.5

    # ...and MIN_AREA was not enough, because the dock cell is not what the dock
    # draws. A MINIMIZED window is drawn LIVE in the pill (X25 SPreview), and on
    # this fixture that preview is 212x132 = 27952px of fixture green -- nearly
    # twice the floor. Measured 2026-08-12 on 3d5281c: the flying proxy fades
    # out at frame 111 and `largest_green` hands the crown to that still preview
    # at (1282,1430); the flight's last centre was (1000,550); the distance
    # between them is 924px, which is the number this arm had been reporting as
    # a teleport. Same class of fault as x24's, whose flight gate was reading
    # the hover PREVIEW PANEL (f7fe954) -- one green fixture, several dock
    # surfaces showing it.
    #
    # So the dock's own preview is excluded. Its rectangle is MEASURED off the
    # film rather than predicted: the rig asserts the film ends with the fixture
    # minimized, so the tail of every z5 film is the dock holding a still image
    # of it, and a box that is identical across the last TAIL frames is that
    # image by construction. If the tail is NOT still the film did not end where
    # the rig says it did, and this says so instead of measuring the wrong thing.
    TAIL, PAD = 20, 8
    tail = [largest_green(p) for p in frames[-TAIL:]]
    assert all(b is not None for b in tail), \
        'no fixture green in the last %d frames -- the film does not end on a minimized fixture' % TAIL
    assert max(max(abs(int(b[k]) - int(tail[-1][k])) for k in range(4)) for b in tail) <= 4, \
        'the last %d frames are not still (%s) -- nothing to identify the dock preview by' % (TAIL, set(tail))
    _b = tail[-1]
    DOCKPREVIEW = (int(_b[0]) - PAD, int(_b[1]) - PAD, int(_b[2]) + 2 * PAD, int(_b[3]) + 2 * PAD)
    print(f'z5: dock live preview excluded from the green search: {DOCKPREVIEW}')

    # The flight's own length, off this film: where the fixture rests before the
    # first click (the biggest blob outside the dock) to where it is going (the
    # dock preview located above).
    rest = max((largest_green(p, DOCKPREVIEW) for p in frames[:20]), key=lambda b: (b[2] * b[3]) if b else -1)
    assert rest, 'no fixture green before the first click -- the film does not start on a window'
    DIST = (((rest[0] + rest[2] / 2.0) - (_b[0] + _b[2] / 2.0)) ** 2 + ((rest[1] + rest[3] / 2.0) - (_b[1] + _b[3] / 2.0)) ** 2) ** 0.5
    FIRST_FRAME_SHARE = 1.0 - 2.0 ** (-10.0 * (1000.0 / FILM_FPS) / FLIGHT_MS)
    JUMP_PX = JITTER_FACTOR * DIST * FIRST_FRAME_SHARE
    print(f'z5: the flight covers {DIST:.0f}px, one film frame is {FIRST_FRAME_SHARE * 100:.0f}% of it on '
          f'EASE_OUT_EXPO at {FLIGHT_MS:.0f}ms, limit {JUMP_PX:.0f}px (x{JITTER_FACTOR} for sampling)')

    last, worst = None, (0.0, -1)
    for i, p in enumerate(frames):
        b = largest_green(p, DOCKPREVIEW)
        if b is None or b[2] * b[3] < MIN_AREA:
            last = None
            continue
        c = (b[0] + b[2] / 2.0, b[1] + b[3] / 2.0)
        if last is not None:
            d = ((c[0] - last[0]) ** 2 + (c[1] - last[1]) ** 2) ** 0.5
            if d > worst[0]:
                worst = (d, i)
        last = c
    print(f'z5 {"FAIL" if worst[0] > JUMP_PX else "PASS"}: worst jump {worst[0]:.0f}px at frame {worst[1]} (limit {JUMP_PX:.0f})')
    sys.exit(1 if worst[0] > JUMP_PX else 0)
