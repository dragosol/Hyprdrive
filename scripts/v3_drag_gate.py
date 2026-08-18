"""V3 graders: where the strip cards are, and whether the cancelled icon FLEW.

Two modes, and they answer two different kinds of question.

  strip   WHERE. The gate has to aim a drag at one named desktop's card, and it
          may not ask the plugin where it drew one (a rig that asks the code it
          is testing cannot catch a layout bug). So the card is found the way
          z3_position_memory finds its minis: a MAGENTA fixture is put on that
          desktop and its mini inside the card is located by colour in the
          strip band. Two filters, and the first run of this gate is why there
          are two: a bare saturation mask found the shell's blue clock widget
          (188x184 px, right below the band) and aimed the drag at it. The hue
          window excludes anything that is not magenta; the size cap excludes
          anything too big to be a cell.

  flight  WHETHER. A near-miss drop is claimed to send the icon home, and
          "nothing spawned" does not say that -- doing nothing at all also
          spawns nothing. The film is graded the house way: a control frame on
          BOTH sides of the measured one, a dilated diff, and the LARGEST
          CONNECTED BLOB rather than a bounding box.
             P  parked   0.25 s before the button comes up: the icon is sitting
                         under the pointer at the drop point.
             M  mid      0.60 and 0.85 of the return's own duration after it:
                         the icon is between the drop point and the dock, and
                         further along in the second than in the first.
             E  ended    3 s after: nothing of it is left anywhere.
          PARKED grades P against E inside a box at the drop point -- that is
          the ghost existing at all, and it is the arm the parent build fails
          (it draws nothing under the pointer, so P and E are the same frame
          there). TRAVEL grades both M frames against BOTH controls and
          requires the blob to be inside the corridor between the two ends and
          to have MOVED between them: an icon that vanished and reappeared in
          its cell would satisfy "gone from the drop point" and must not
          satisfy this.

Identical frames are an explicit FAIL in both modes: a frozen capture proves
nothing, and this guest's output is exactly the one that hands back stale ones.
"""
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from blob import largest_of  # noqa: E402

# A pixel counts as "changed" at this much difference on any channel. Below ~24
# the overview's own dither and the film's compression are inside the mask.
DIFF = 26
# The dock cell is ~64 px square at this output, so a blob smaller than this is
# not an icon whatever else it is.
FLOOR = 500


def _rgb(path):
    return np.asarray(Image.open(path).convert("RGB")).astype(int)


def _changed(a, b):
    return np.abs(a - b).max(axis=2) > DIFF


def _dilate(mask, r=3):
    """Grow the mask by r px. Doctrine: an undilated diff of a moving texture is
    a ring of edges with a hole in it, and the largest CONNECTED blob of a ring
    is a fragment of the ring."""
    out = mask.copy()
    for _ in range(r):
        g = out.copy()
        g[1:, :] |= out[:-1, :]
        g[:-1, :] |= out[1:, :]
        g[:, 1:] |= out[:, :-1]
        g[:, :-1] |= out[:, 1:]
        out = g
    return out


def _magenta(im):
    """The fixture's background and nothing else. A bare saturation mask is NOT
    enough and this is measured, not defensive: on an unpinned run the shell's
    blue clock widget floats right below the strip and scored a 188x184 blob,
    which the locator then aimed the drag at (zrig/v3/gate, first run). A hue
    window excludes it, and no wallpaper this rig has met is magenta."""
    return (im[:, :, 0] > 150) & (im[:, :, 2] > 150) & (im[:, :, 1] < 100)


def strip(png, want_y_max=500, max_w=420, max_h=220):
    """Print 'x y' -- the centre of the fixture's mini inside its strip card.

    The size cap is the second half of the discrimination, and it is a fact
    about the strip rather than a tuned number: a mini is a whole desktop
    scaled into one cell, so it is a fraction of the size the same window is
    drawn at in the main area. A magenta blob bigger than a cell is a TILE, and
    aiming at a tile would be aiming at the main area."""
    im = _rgb(png)
    mask = _magenta(im)
    mask[want_y_max:, :] = False
    found = largest_of(mask)
    if not found or found[4] < 200:
        print("STRIP-LOCATE FAIL: no magenta mini in the top %d rows (largest %s)" % (want_y_max, found), file=sys.stderr)
        return 1
    x, y, w, h, area = found
    if w > max_w or h > max_h:
        print("STRIP-LOCATE FAIL: the magenta blob is %dx%d, too big for a strip cell -- that is a tile, not a mini" % (w, h), file=sys.stderr)
        return 1
    print("%d %d" % (x + w // 2, y + h // 2))
    print("  strip mini %dx%d at %d,%d (%d px)" % (w, h, x, y, area), file=sys.stderr)
    return 0


def flight(filmdir, fps, rel_s, dropx, dropy, dockx, docky, flight_ms):
    import glob

    frames = sorted(glob.glob(filmdir + "/f*.png"))
    if not frames:
        print("FLIGHT FAIL: no frames in %s" % filmdir)
        return 1

    def at(offset_s):
        i = int(round((rel_s + offset_s) * fps))
        return frames[min(max(i, 0), len(frames) - 1)], i

    pth_p, ip = at(-0.25)
    pth_m, im_ = at(flight_ms * 0.60 / 1000.0)
    pth_e, ie = at(3.0)
    print("  frames %d  release@%.2fs %.1ffps  P=%d M=%d E=%d" % (len(frames), rel_s, fps, ip, im_, ie))

    if len({pth_p, pth_m, pth_e}) != 3:
        print("FLIGHT FAIL: the three sample frames are the same frame -- the film is too short")
        return 1

    P, M, E = _rgb(pth_p), _rgb(pth_m), _rgb(pth_e)
    fails = 0

    # PARKED -- the icon under the pointer, before the release and not after.
    # A box around the drop point twice a dock cell wide, so a ghost drawn with
    # any plausible grab offset is inside it and nothing else is.
    #
    # GRADED FIRST, ahead of the frozen-capture guard below, and that order was
    # earned: on the parent build the guard fired first and reported "M/E are
    # pixel-identical", which is true and is the WRONG HEADLINE -- the reason
    # they are identical is that nothing is drawn under the pointer at all.
    # This way the log always carries the number (0 px against a 500 px floor)
    # and the guard is the second line rather than the only one.
    R = 90
    y0, y1 = max(0, dropy - R), dropy + R
    x0, x1 = max(0, dropx - R), dropx + R
    parked = _dilate(_changed(P[y0:y1, x0:x1], E[y0:y1, x0:x1]))
    got = largest_of(parked)
    area = got[4] if got else 0
    print("  PARKED  blob %d px in the %dx%d box at the drop point (floor %d)" % (area, 2 * R, 2 * R, FLOOR))
    if area < FLOOR:
        print("FAIL PARKED -- nothing is drawn under the pointer while the drag is held: there is no icon to send home")
        fails = 1

    for name, a, b in (("P/M", P, M), ("M/E", M, E), ("P/E", P, E)):
        if not _changed(a, b).any():
            print("FLIGHT FAIL: %s are pixel-identical -- a frozen capture proves nothing, and neither does a build that draws nothing" % name)
            return 1 if fails == 0 else fails

    # TRAVEL -- the icon between the two ends, in frames both controls bracket.
    #
    # TWO of them, not one, and the second must be strictly FURTHER along than
    # the first: one sample says "something was somewhere", two say it moved,
    # which is what "flies home" claims. They are taken at 0.60 and 0.85 of the
    # return rather than at its middle because the curve is the house ACCEL --
    # the exit law -- so at half the duration the icon has barely left the
    # pointer and would still be inside the box PARKED already measured
    # (measured: 47 px of travel at t=0.5, inside the 90 px exclusion).
    #
    # The two ends are cut out of the mask: the drop point is PARKED's, and the
    # dock cell is where the icon is going and where the pill's own contents
    # move when it arrives.
    lo_x, hi_x = sorted((dropx, dockx))
    lo_y, hi_y = sorted((dropy, docky))
    seen = []
    for frac in (0.60, 0.85):
        pth, idx = at(flight_ms * frac / 1000.0)
        F = _rgb(pth)
        mid = _dilate(_changed(F, P) & _changed(F, E))
        for ex, ey in ((dropx, dropy), (dockx, docky)):
            mid[max(0, ey - R):ey + R, max(0, ex - R):ex + R] = False
        got = largest_of(mid)
        if not got:
            print("FAIL TRAVEL -- nothing between the drop point and the dock at t=%.2f (frame %d)" % (frac, idx))
            return 1

        bx, by, bw, bh, barea = got
        cx, cy = bx + bw // 2, by + bh // 2
        inside = lo_x - R <= cx <= hi_x + R and lo_y - R <= cy <= hi_y + R
        travelled = abs(cy - dropy) + abs(cx - dropx)
        print("  TRAVEL  t=%.2f frame %d  blob %d px at %d,%d  %d px from the drop point  corridor=%s" % (frac, idx, barea, cx, cy, travelled, inside))
        if barea < FLOOR:
            print("FAIL TRAVEL -- the blob at t=%.2f is %d px, under the %d px floor" % (frac, barea, FLOOR))
            fails = 1
        if not inside:
            print("FAIL TRAVEL -- the blob at t=%.2f is outside the corridor between the drop point and the dock" % frac)
            fails = 1
        seen.append(travelled)

    if len(seen) == 2 and seen[1] <= seen[0]:
        print("FAIL TRAVEL -- %d px then %d px from the drop point: the icon is not travelling, it is sitting somewhere" % (seen[0], seen[1]))
        fails = 1

    return fails


if __name__ == "__main__":
    MODE = sys.argv[1]
    if MODE == "strip":
        sys.exit(strip(sys.argv[2]))
    if MODE == "flight":
        sys.exit(
            flight(sys.argv[2], float(sys.argv[3]), float(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6]), int(sys.argv[7]), int(sys.argv[8]), float(sys.argv[9]))
        )
    print("usage: v3_drag_gate.py strip PNG | flight FILMDIR FPS REL_S DROPX DROPY DOCKX DOCKY FLIGHT_MS", file=sys.stderr)
    sys.exit(2)
