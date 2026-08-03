"""Tile-hover overshoot gate. Runs on the HOST (no numpy/PIL in the guest).

Reports the hovered tile's width per frame. A bounce shows up as a sample WIDER
than the width the tile settles at; a critically-damped curve never exceeds it.
"""
import sys
import glob
import os
import numpy as np
from PIL import Image

OUT = "/home/dragos/hyprvm/share/hover"
TAG = sys.argv[1]


def width(name):
    """Width in px of the fixture-green run in this band, 0 if absent."""
    im = np.asarray(Image.open(f"{OUT}/{TAG}-{name}.png").convert("RGB")).astype(int)
    mask = (im[:, :, 1] > 150) & (im[:, :, 0] < 110) & (im[:, :, 2] < 110)
    cols = np.where(mask.any(axis=0))[0]
    return 0 if cols.size == 0 else int(cols.max() - cols.min() + 1)


rest = width("rest")
settled = width("settled")
samples = [(n, width(f"s{n}")) for n in range(10) if os.path.exists(f"{OUT}/{TAG}-s{n}.png")]
peak_n, peak = max(samples, key=lambda kv: kv[1])

print(f"tag={TAG}")
print(f"  unhovered      {rest} px")
print(f"  settled hover  {settled} px   (+{settled - rest} px, {100*(settled/rest-1):.1f}%)")
print("  samples        " + " ".join(f"{v}" for _, v in samples))
print(f"  peak           {peak} px at sample {peak_n}")

# 2px of slack for edge antialiasing; the overshoot being hunted is ~5px.
overshoot = peak - settled
print(f"  OVERSHOOT      {overshoot:+d} px")

grew = settled > rest + 2
print()
print(f"  hover grows the tile          {'PASS' if grew else 'FAIL'}")
print(f"  no overshoot past settled     {'PASS' if overshoot <= 2 else 'FAIL'}")
sys.exit(0 if (grew and overshoot <= 2) else 1)
