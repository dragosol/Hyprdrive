"""OVERVIEW_CPP_SPEC 13.2 F3-b, OUTBOUND half: grade a filmed release.

WHAT THIS MEASURES, and why it is not "does the tile appear".

The outbound tile was never missing. On 9c2742f the render-list trace shows it
drawn on EVERY frame of the release, correctly interpolated, from the moment the
match dies -- and off the monitor edge again at animated elapsed 24.4ms of a
300ms curve. Its destination is its real rect on a desktop two cards away, i.e.
thousands of pixels off screen, so the entrance curve (most of the distance
covered early) spent 92% of the animation somewhere nobody can see it. What the
user gets is one or two frames, which is exactly what F3-b-ii forbids by name.

So the number that decides this gate is HOW LONG THE TILE IS ON SCREEN, measured
in film frames, against a known anim_scale. Frames, not milliseconds: the guest's
present rate is not a constant and the film's own timebase is.

The three phases, with a control on both sides of the measured one (pixel
doctrine): SETTLED (the tile parked in its promoted slot, not moving) -> TRAVEL
(the graded phase) -> GONE (the tile off screen, and stays off). A film that
cannot show all three is a rig fault and says so rather than grading half of one.

Colour, region and blob: the fixture is magenta over the pinned greyscale
wallpaper; everything above STRIP_FLOOR is dropped because the desktop strip
draws a mini of the same window and a 76x48 cell in every frame would make
"present" true forever; and the measurement is the LARGEST CONNECTED BLOB, never
a bounding box -- the mini and the tile together span most of the screen.
"""
import sys
import os
import glob

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np
from PIL import Image

from blob import largest_of

# Below the search row + strip band at 2560x1600. The tiles live around y=660.
STRIP_FLOOR = 450
# A blob smaller than this is a sliver of chrome or a rounded corner, not a tile.
MIN_TILE_PX = 4000


def magenta(png):
    im = np.asarray(Image.open(png).convert("RGB")).astype(int)
    r, g, b = im[:, :, 0], im[:, :, 1], im[:, :, 2]
    mask = (r > 110) & (b > 110) & (g < 90) & (r - g > 60) & (b - g > 60)
    mask[:STRIP_FLOOR, :] = False
    return largest_of(mask)


def read(frames):
    out = []
    for p in sorted(glob.glob(os.path.join(frames, "*.png"))):
        blob = magenta(p)
        if blob and blob[4] >= MIN_TILE_PX:
            out.append((os.path.basename(p), blob[0], blob[4]))
        else:
            out.append((os.path.basename(p), None, 0))
    return out


def grade(frames, min_travel_frames, min_travel_px, direction=1):
    rows = read(frames)
    if not rows:
        print("FAIL no frames in %s" % frames)
        return 1

    present = [i for i, (_, x, _) in enumerate(rows) if x is not None]
    if not present:
        print("FAIL the releasing tile is in NONE of the %d frames -- rig fault, "
              "the fixture never made it into the grid" % len(rows))
        return 1

    first, last = present[0], present[-1]
    x0 = rows[first][1]

    # SETTLED: the leading run where the tile is present and has not started to
    # move. This is the control on the near side -- without it a film that began
    # after the release was over would "pass" by having no travel to grade.
    settled = 0
    for i in range(first, len(rows)):
        x = rows[i][1]
        if x is None or abs(x - x0) > 8:
            break
        settled += 1

    # TRAVEL: from the first frame that has moved, for as long as the tile keeps
    # going the same way and stays on screen. A step BACKWARDS ends it: the tile
    # must be seen leaving, not flickering.
    start = first + settled
    travel = []
    prev = x0
    for i in range(start, len(rows)):
        x = rows[i][1]
        if x is None:
            break
        if (x - prev) * direction < -12:
            break
        travel.append(x)
        prev = x

    # GONE: the tile is off screen at the end and stays off. The far-side
    # control, and the thing that proves the film outlasted the animation.
    tail = 0
    for i in range(len(rows) - 1, -1, -1):
        if rows[i][1] is not None:
            break
        tail += 1

    span = (max(travel) - min(travel)) if travel else 0
    distinct = len(set(travel))

    print("    frames %d   tile present in %d   settled %d   travel %d   gone-tail %d"
          % (len(rows), len(present), settled, len(travel), tail))
    print("    x0 %d -> %d   span %d px   distinct positions %d"
          % (x0, travel[-1] if travel else x0, span, distinct))

    fail = 0
    if settled < 5:
        print("FAIL the film never caught the tile PARKED (settled %d < 5) -- it "
              "started mid-release, so there is no near-side control" % settled)
        fail = 1
    if tail < 5:
        print("FAIL the film ended with the tile still on screen (gone-tail %d < 5) "
              "-- the release outlasted the camera, so its length is unmeasured" % tail)
        fail = 1
    if len(travel) < min_travel_frames:
        print("FAIL the release is on screen for %d frames, wanted >= %d. F3-b-ii: "
              "\"'Fast' is not a licence to drop to one or two frames\"."
              % (len(travel), min_travel_frames))
        fail = 1
    if span < min_travel_px:
        print("FAIL the tile moved %d px, wanted >= %d -- that is a fade, not the "
              "travel F3-b-i asks for" % (span, min_travel_px))
        fail = 1
    # Identical frames prove nothing (pixel doctrine). A tile redrawn at the same
    # x for the whole phase is a frozen capture wearing a long duration.
    if distinct < max(8, min_travel_frames // 8):
        print("FAIL only %d distinct tile positions across %d travel frames -- the "
              "capture is repeating frames, not filming motion" % (distinct, len(travel)))
        fail = 1

    print("PASS f3b_release" if not fail else "FAIL f3b_release")
    return fail


if __name__ == "__main__":
    FRAMES = sys.argv[1]
    MINFRAMES = int(sys.argv[2]) if len(sys.argv) > 2 else 50
    MINPX = int(sys.argv[3]) if len(sys.argv) > 3 else 600
    sys.exit(grade(FRAMES, MINFRAMES, MINPX))
