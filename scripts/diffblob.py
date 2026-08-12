#!/usr/bin/env python3
"""Largest connected blob of CHANGE between two frames. The pixel doctrine, once.

Every A/B in this harness asks the same question -- did anything move, and was it
one thing or noise everywhere -- and the three ways of getting it wrong are also
always the same:

  a bounding box over all changed pixels spans the screen the moment one clock
  digit ticks in a corner, so it measures the corner and reports the middle
  (blob.py's header, learned the same way);
  an undilated mask breaks one real change into a hundred speckles, and the
  largest of those is smaller than the noise;
  and two identical frames give zero change, which reads as a clean PASS to any
  check phrased as "less than N" -- a frozen capture must FAIL, loudly.

So: per-pixel max-channel delta over a threshold, dilated, largest 4-connected
component, area in whole pixels. No scipy in the guest, so the label pass runs on
a downsample -- the same trick and the same constant blob.py uses.

    diffblob.py A.png B.png [--thresh 12] [--region x,y,w,h] [--json]

Prints "area wxh at x,y" or, with --json, everything including the identical-frame
flag so a caller cannot forget to look at it.
"""
import argparse
import json
import sys

import numpy as np
from PIL import Image

S = 4          # downsample for the label pass [blob.py:12]
DILATE = 2     # in downsampled cells, so ~8px -- enough to join a smear


def load(path, region):
    im = np.asarray(Image.open(path).convert("RGB")).astype(np.int16)
    if region:
        x, y, w, h = region
        im = im[y:y + h, x:x + w]
    return im


def dilate(mask, n):
    out = mask.copy()
    for _ in range(n):
        p = np.pad(out, 1, constant_values=False)
        out = (p[:-2, 1:-1] | p[2:, 1:-1] | p[1:-1, :-2] | p[1:-1, 2:] | p[1:-1, 1:-1])
    return out


def largest(mask):
    """(area_in_cells, x, y, w, h) of the biggest 4-connected component."""
    seen = np.zeros_like(mask)
    best, best_n = None, 0
    ys, xs = np.where(mask)
    for sy, sx in zip(ys, xs):
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
        return 0, 0, 0, 0, 0
    a = np.array(best)
    return best_n, int(a[:, 1].min()), int(a[:, 0].min()), \
        int(a[:, 1].max() - a[:, 1].min() + 1), int(a[:, 0].max() - a[:, 0].min() + 1)


def measure(a_path, b_path, thresh=12, region=None):
    a, b = load(a_path, region), load(b_path, region)
    if a.shape != b.shape:
        raise SystemExit("diffblob: %s and %s are different sizes" % (a_path, b_path))
    identical = bool(np.array_equal(a, b))
    d = np.abs(a - b).max(axis=2)
    mask = d > thresh
    small = dilate(mask[::S, ::S], DILATE)
    cells, x, y, w, h = largest(small)
    return {
        "a": a_path, "b": b_path,
        "identical": identical,
        "changed_px": int(mask.sum()),
        "blob_px": cells * S * S,
        "blob": [x * S, y * S, w * S, h * S],
        "mean_delta": float(d.mean()),
    }


def main(argv):
    ap = argparse.ArgumentParser(description="largest connected blob of change")
    ap.add_argument("a"); ap.add_argument("b")
    ap.add_argument("--thresh", type=int, default=12)
    ap.add_argument("--region", help="x,y,w,h -- measure only inside this box")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv[1:])
    region = [int(v) for v in a.region.split(",")] if a.region else None
    r = measure(a.a, a.b, a.thresh, region)
    if a.json:
        print(json.dumps(r))
    else:
        print("%d px blob %dx%d at %d,%d (changed %d, mean %.2f)%s"
              % (r["blob_px"], r["blob"][2], r["blob"][3], r["blob"][0], r["blob"][1],
                 r["changed_px"], r["mean_delta"], "  IDENTICAL FRAMES" if r["identical"] else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
