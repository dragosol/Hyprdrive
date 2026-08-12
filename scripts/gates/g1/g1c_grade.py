#!/usr/bin/env python3
"""g1c grade -- G1's last clause (compose), under the standing pixel doctrine.

    g1c_grade.py <framedir> <tag>

  no drift                00-ctrlA vs 01-ctrlB        quiet
  the sequence COMPOSES   10-compose vs 20-raw        loud   (identical would
                          mean `Compose ' e` passed through as the raw "'e")
  compose TYPED at all    00-ctrlA vs 10-compose      loud   (a swallowed
                          sequence leaves the query empty and 10 == ctrlA)
  Compose alone ACTIVATES 30-desktop vs 40-composeEsc loud   (the first ESC
                          only CLEARS, so frame 40 must still look OPEN)
  ESC-close control       30-desktop vs 50-escClose   quiet  (with no search
                          active the first ESC closes; 50 must look like desktop)

WHY THIS IS NOT A WHOLE-FRAME PIXEL COUNT ANY MORE (2026-08-12)
---------------------------------------------------------------
g1_gate.py was rewritten on 2026-08-12 because it diffed whole frames against an
absolute 400 px floor, and this desktop is not still: the quickshell bar's clock
and readouts tick, and the ii desktop clock widget shows through at a minute
boundary. This file was the same scheme, transcribed -- and it inherited the
same defect, on the frames where it hurts most. Its ESC-close control compares
two DESKTOP frames about ten seconds apart, which is precisely when the desktop
clock is visible and unobscured: measured at 7911 px between two frames that
differ by nothing but the time, twenty times its own 400 px floor. That is the
g1 FAIL-in-B / PASS-in-C straddle, in the compose arm.

The repair is not a bigger floor, it is g1_gate.grade: mask the chrome that
ticks (layer surfaces from `hyprctl layers -j`, plus the pinned clock box),
dilate, and grade the LARGEST 4-CONNECTED BLOB. Imported, not transcribed --
transcribing it is what produced this bug.

The thresholds come with it, and the margin they leave on THIS arm's frames is
wider than on g1's own (measured 2026-08-12, zrig/danglingA2/g1c-measurements.txt):

    quiet rows, unmasked whole-frame ......      40 -   221 px   (masked: 0)
    desktop clock, one minute tick ........    4224 -  5888 px blob
    compose vs raw passthrough ............ 1143134 px blob
    compose vs empty query ................ 1290863 px blob
    overview-open vs desktop .............. 2272427 px blob

QUIET is 25000 and LOUD is 50000: four times the worst noise this session can
produce, and twenty times under the smallest change any must-move row here has
to see.
"""
import pathlib
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))
from g1_gate import grade                                          # noqa: E402


def load(out, tag, name):
    return np.asarray(Image.open(out / f"{tag}-{name}.png").convert("RGB")).astype(np.int16)


def main(argv):
    out = pathlib.Path(argv[1])
    tag = argv[2]

    names = ["00-ctrlA", "01-ctrlB", "10-compose", "20-raw",
             "30-desktop", "40-composeEsc", "50-escClose"]
    fr = {n: load(out, tag, n) for n in names}

    rows = [
        ("no drift between two idle frames", "ctrlA vs 01-ctrlB",
         "00-ctrlA", "01-ctrlB", "quiet"),
        ("compose differs from raw passthrough", "10-compose vs 20-raw",
         "10-compose", "20-raw", "loud"),
        ("compose typed something at all", "ctrlA vs 10-compose",
         "00-ctrlA", "10-compose", "loud"),
        ("Compose alone leaves ESC a query to clear", "30-desktop vs 40-composeEsc",
         "30-desktop", "40-composeEsc", "loud"),
        ("control: no search -> first ESC closes", "30-desktop vs 50-escClose",
         "30-desktop", "50-escClose", "quiet"),
    ]
    return 0 if grade(out, fr, rows, "G1C GRADE") else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
