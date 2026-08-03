#!/usr/bin/env python3
"""Did the overview stay open across a dock click?

Two controls, one measured frame. post.png must sit nearer the overview-open
control than the desktop control. Byte-identical controls mean the capture
stalled on Virtual-1 rather than that the states match, so that is an explicit
FAIL, not a pass.
"""
import pathlib
import sys

import numpy as np
from PIL import Image

OUT = pathlib.Path("/mnt/host/x24d")


def load(name):
    return np.asarray(Image.open(OUT / name).convert("RGB"), dtype=np.float32)


desktop, ovopen, post = load("desktop.png"), load("ovopen.png"), load("post.png")

if desktop.shape != ovopen.shape or desktop.shape != post.shape:
    sys.exit("FAIL: frame sizes differ")

ctrl = float(np.abs(ovopen - desktop).mean())
d_ov = float(np.abs(post - ovopen).mean())
d_desk = float(np.abs(post - desktop).mean())

print(f"control separation (ovopen vs desktop) = {ctrl:.2f}")
print(f"post vs ovopen  = {d_ov:.2f}")
print(f"post vs desktop = {d_desk:.2f}")

if ctrl < 1.0:
    sys.exit("FAIL: the two controls are effectively identical -- the capture "
             "stalled, so nothing here can be believed")

if d_ov >= d_desk:
    sys.exit("FAIL: post frame is nearer the DESKTOP control -- the overview "
             "closed, so the dock click fell through to the tile underneath")

print("PASS: the overview stayed open across the dock click")
