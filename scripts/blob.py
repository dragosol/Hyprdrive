"""Largest connected blob of fixture green, on the host (guest has no numpy).

Shared because this is the third rig that needs it and the first two each got it
wrong the same way: the bounding box of ALL green pixels spans the main tile,
the strip mini AND the desktop card, so it is ~2300px wide in every frame and
any ratio measured off it is pinned at 1.00 whatever the compositor does -- a
check that cannot fail. Labelled on a 4x downsample; there is no scipy here.
"""
import numpy as np
from PIL import Image

S = 4


def largest_green(png, exclude=None, min_excess=None):
    """(x, y, w, h) of the biggest green blob, or None.

    `exclude` is an optional (x, y, w, h) rectangle whose pixels are dropped
    before labelling. X24's flight needs it: the dock holds its hover PREVIEW
    PANEL out for the whole flight (Dock.cpp:1240, "a flight HOLDS the dock
    out"), the panel is showing a thumbnail of the very window in flight, and
    once the shrinking proxy is smaller than the panel the largest green blob is
    the panel -- a box that does not move, in five frames running, which reads
    as a teleport.

    `min_excess` switches the mask from ABSOLUTE green to green EXCESS -- green
    is `min_excess` above both other channels, whatever the brightness. An
    absolute mask cannot follow a FADING surface: the dock flight eases the
    proxy's opacity to nothing inside the same tween as its scale, so at alpha
    0.4 a pure-green fixture reads G~110 and drops out of `G > 150` while it is
    still plainly on screen, and what the labeller then measures is the
    brightest FRAGMENT of the proxy rather than the proxy -- a box that shrinks
    faster than the animation and whose centre wanders (x24's P4/P5, measured
    2026-08-12: widths 680,588,252,192,76 for a box that eases 776 -> 54, and a
    centre y that went 1020,1062,1030,1048). Excess survives the fade because
    the pinned gate wallpaper is greyscale by design (wp17, chosen so colour
    locators cannot get a false positive off it), so anything with green in it
    over that backdrop is the fixture.
    """
    im = np.asarray(Image.open(png).convert("RGB")).astype(int)
    if min_excess is None:
        mask = (im[:, :, 1] > 150) & (im[:, :, 0] < 110) & (im[:, :, 2] < 110)
    else:
        mask = (im[:, :, 1] > im[:, :, 0] + min_excess) & (im[:, :, 1] > im[:, :, 2] + min_excess)
    if exclude:
        # One rectangle, or several: a scene can hold more than one dock surface
        # showing the same fixture (x24's flight has the hover panel AND the
        # pill's own live preview of the window that is flying).
        rects = [exclude] if isinstance(exclude[0], (int, float, np.integer)) else exclude
        for ex, ey, ew, eh in rects:
            ex, ey, ew, eh = int(ex), int(ey), int(ew), int(eh)
            mask[max(0, ey):ey + eh, max(0, ex):ex + ew] = False
    if not mask.any():
        return None

    # ...and the labelling runs on a 4x DOWNSAMPLE, so "there is green" is not
    # "there is green ON THE GRID". A sliver left over by `exclude` -- x24's
    # panel rectangle clips the dock's preview cell and leaves a few columns of
    # it -- can miss every 4th row and column, and then the loop below never
    # runs, `best` stays None, and np.array(None).T raises "iteration over a 0-d
    # array" INSIDE the gate, which reads as a crashed gate rather than an empty
    # frame. Measured 2026-08-12: that traceback is what x24's flight half had
    # been dying on, before it graded a single one of its seven predicates.
    small = mask[::S, ::S]
    if not small.any():
        return None
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
            (xs.max() - xs.min() + 1) * S, (ys.max() - ys.min() + 1) * S)
