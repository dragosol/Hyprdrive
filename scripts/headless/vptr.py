#!/usr/bin/env python3
"""Synthesized pointer for the headless harness (wlr-virtual-pointer-v1).

Usage: vptr.py XEXT YEXT move X Y | click [left|right|middle]
                         | down [btn] | up [btn] | scroll DY | drag X1 Y1 X2 Y2 [steps]

X/Y are layout coordinates; XEXT/YEXT the layout bounding box (hl.sh passes
it). Events go through Hyprland's real pointer path (keybinds, plugin input
hooks), unlike hl.dsp.cursor.move, which only warps. Needs the bindings that
hl.sh generates with pywayland.scanner into $PYTHONPATH/hlproto.
"""
import os
import sys
import time

from pywayland.client import Display
from hlproto.wayland import WlSeat
from hlproto.wlr_virtual_pointer_unstable_v1 import ZwlrVirtualPointerManagerV1

BTN = {"left": 0x110, "right": 0x111, "middle": 0x112}


def ms():
    return int(time.monotonic() * 1000) & 0xFFFFFFFF


def main(argv):
    xext, yext, cmd, args = int(argv[1]), int(argv[2]), argv[3], argv[4:]
    d = Display()
    d.connect()
    reg = d.get_registry()
    found = {}

    def on_global(_reg, name, iface, ver):
        found.setdefault(iface, (name, ver))  # must return None (cffi callback)

    reg.dispatcher["global"] = on_global
    d.roundtrip()
    if "zwlr_virtual_pointer_manager_v1" not in found:
        sys.exit("vptr: compositor has no zwlr_virtual_pointer_manager_v1")
    seat = reg.bind(found["wl_seat"][0], WlSeat, 1)
    mgr = reg.bind(found["zwlr_virtual_pointer_manager_v1"][0], ZwlrVirtualPointerManagerV1, 1)
    vp = mgr.create_virtual_pointer(seat)
    d.roundtrip()

    def move(x, y):
        x = max(0, min(int(float(x)), xext - 1))
        y = max(0, min(int(float(y)), yext - 1))
        vp.motion_absolute(ms(), x, y, xext, yext)
        vp.frame()
        d.flush()

    def button(b, pressed):
        vp.button(ms(), BTN.get(b, BTN["left"]), 1 if pressed else 0)
        vp.frame()
        d.flush()

    if cmd == "move":
        move(args[0], args[1])
    elif cmd == "click":
        b = args[0] if args else "left"
        button(b, True)
        d.roundtrip()
        time.sleep(0.05)
        button(b, False)
    elif cmd in ("down", "up"):
        button(args[0] if args else "left", cmd == "down")
    elif cmd == "scroll":
        vp.axis_source(0)  # wheel
        vp.axis(ms(), 0, float(args[0]))  # vertical
        vp.frame()
        d.flush()
    elif cmd == "drag":
        x1, y1, x2, y2 = map(float, args[:4])
        steps = int(args[4]) if len(args) > 4 else 30
        move(x1, y1)
        d.roundtrip()
        button("left", True)
        for i in range(1, steps + 1):
            time.sleep(1 / 120)
            move(x1 + (x2 - x1) * i / steps, y1 + (y2 - y1) * i / steps)
        d.roundtrip()
        button("left", False)
    else:
        sys.exit(f"vptr: unknown command {cmd}")
    d.roundtrip()
    vp.destroy()
    d.roundtrip()
    d.disconnect()


if __name__ == "__main__":
    main(sys.argv)
    os._exit(0)  # skip pywayland finalizers (they can SEGV at teardown)
