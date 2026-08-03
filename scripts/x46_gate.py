"""X46 gate: the dock pill must not change when a window is minimized.

Runs on the HOST. Reports the pill's horizontal extent by finding the columns
that differ from the wallpaper -- the pill is the only lit thing in the strip.
"""
import sys
import numpy as np
from PIL import Image

OUT = "/home/dragos/hyprvm/share/x46"
TAG = sys.argv[1]


def extent(name):
    """(left, right, width) of the lit pill in this strip."""
    im = np.asarray(Image.open(f"{OUT}/{TAG}-{name}.png").convert("RGB")).astype(int)
    # The pill is markedly brighter than the dark wallpaper behind the strip.
    lit = im.max(axis=2) > 60
    cols = np.where(lit.any(axis=0))[0]
    if cols.size == 0:
        return None
    return int(cols.min()), int(cols.max()), int(cols.max() - cols.min() + 1)


def diff(a, b):
    A = np.asarray(Image.open(f"{OUT}/{TAG}-{a}.png").convert("RGB")).astype(int)
    B = np.asarray(Image.open(f"{OUT}/{TAG}-{b}.png").convert("RGB")).astype(int)
    return int((np.abs(A - B).max(axis=2) > 8).sum())


before, idle, cycle, after = extent("0-before"), extent("1-idle"), extent("2-cycle"), extent("3-after")
print(f"tag={TAG}")
for label, e in (("before", before), ("idle", idle), ("open/close cycle", cycle), ("after minimize", after)):
    print(f"  {label:16} left={e[0]:5} right={e[1]:5} width={e[2]:5}" if e else f"  {label:16} NO PILL")

drift = diff("0-before", "1-idle")
cyc = diff("0-before", "2-cycle")
change = diff("0-before", "3-after")
print(f"  idle drift        {drift:8} px")
print(f"  open/close cycle  {cyc:8} px changed")
print(f"  after minimize    {change:8} px changed")

ok_cycle = before and cycle and before[2] == cycle[2] and before[0] == cycle[0]
ok_width = before and after and before[2] == after[2] and before[0] == after[0]
# The strip must be capable of changing at all, or this gate proves nothing --
# but the pill itself must not. Icon CONTENT may legitimately differ (a running
# dot goes away), so width/position is the assertion and the pixel diff is
# reported for context rather than gated on.
print()
print(f"  open/close moves nothing  {'PASS' if ok_cycle else 'FAIL'}")
print(f"  pill width unchanged      {'PASS' if ok_width else 'FAIL'}")
print(f"  pill left edge unchanged  {'PASS' if (before and after and before[0] == after[0]) else 'FAIL'}")
sys.exit(0 if (ok_width and ok_cycle) else 1)
