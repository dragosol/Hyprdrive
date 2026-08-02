#!/usr/bin/env python3
"""X24 raise gate. Runs on the HOST (the guest has no PIL).

X43's lesson is that focus and stacking are different properties and every
earlier test checked the wrong one, so this grades PIXELS: the large window is
covered before it is minimized, and must be on top after it is restored.

    python3 x24_gate.py [dir]     default: ~/hyprvm/share/x24
"""
import os
import sys

from PIL import Image

D = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/hyprvm/share/x24")

# X24BIG is 1400x800 at (200,200), X24TOP is 900x600 at (500,400).
OVERLAP = (950, 700)   # both windows
BIGONLY = (300, 300)   # only the big window


def hue(px):
    r, g, b = px[:3]
    if r > 150 and g < 100 and b < 100:
        return "red"
    if b > 150 and r < 100 and g < 100:
        return "blue"
    return "other"


def at(name, pt):
    return hue(Image.open(os.path.join(D, name)).convert("RGB").getpixel(pt))


checks = [
    # Without this the "on top afterwards" result would prove nothing.
    ("R1 covered before minimize", at("00-before.png", OVERLAP), "blue"),
    ("R2 gone while minimized", at("01-minimized.png", BIGONLY) != "red", True),
    ("R3 raised after restore", at("02-restored.png", OVERLAP), "red"),
]

bad = [n for n, got, want in checks if got != want]
for n, got, want in checks:
    print("%s %s: got %s, want %s" % ("PASS" if got == want else "FAIL", n, got, want))

print("X24_RAISE " + ("OK" if not bad else "FAILED " + ",".join(bad)))
sys.exit(1 if bad else 0)
