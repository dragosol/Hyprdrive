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


def largest_green(png):
    """(x, y, w, h) of the biggest green blob, or None."""
    im = np.asarray(Image.open(png).convert("RGB")).astype(int)
    mask = (im[:, :, 1] > 150) & (im[:, :, 0] < 110) & (im[:, :, 2] < 110)
    if not mask.any():
        return None

    small = mask[::S, ::S]
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
