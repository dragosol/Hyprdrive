#!/usr/bin/env python3
"""Synthesized pointer for the headless harness (wlr-virtual-pointer-v1).

Usage: vptr.py XEXT YEXT move X Y | click [left|right|middle [N]] | tap X Y [btn]
                         | down [btn] | up [btn] | scroll DY
                         | drag X1 Y1 X2 Y2 [steps [hold_ms [btn]]]
                         | hover X Y [ms] | rel DX DY [n [interval_ms]]
                         | seq STEP [STEP...]
                         | path PAUSE_MS X1 Y1 X2 Y2 [...]

`path` visits each point in turn on ONE device with no button, resting
PAUSE_MS at each: a hand moving the same mouse there and back (a hot-corner
round trip). Separate `move` calls are separate devices.

X/Y are layout coordinates; XEXT/YEXT the layout bounding box (hl.sh passes
it). Every call is a NEW virtual pointer device, which a toolkit client (Qt
under Quickshell) treats as a fresh seat pointer: a bare `click` after a
separate `move` reaches it with no enter/motion and is dropped. `tap X Y` moves
and clicks on one device -- use it for clicks on client windows. Events go through Hyprland's real pointer path (keybinds, plugin input
hooks), unlike hl.dsp.cursor.move, which only warps. Needs the bindings that
hl.sh generates with pywayland.scanner into $PYTHONPATH/hlproto.

ONE DEVICE FOR A SEQUENCE. Hover-only UI (a reveal on enter, a tooltip after a
delay) and held drags with another button need the pointer to stay one device
for the whole gesture:
  hover X Y [ms]      arrive at X Y (a nudge, so the client sees motion) and
                      stay there ms (default 800) before the device goes
  rel DX DY [n [ms]]  RELATIVE motion, n times (default 1) every ms (default
                      16): a hand pushing against a screen edge, which an
                      absolute move clamps away (dock:require_pressure)
  drag ... [btn]      the drag with left (default), middle or right held
  seq STEP...         each STEP one quoted string, run in order on one device:
                        "move X Y [steps]"  glide there (steps>1) or jump
                        "rel DX DY [n [ms]]"  "down [btn]"  "up [btn]"
                        "click [btn]"  "scroll DY"  "wait MS"
                      e.g. seq "move 200 900 10" "wait 600" "move 200 700 10" "click"
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

    pos = [None, None]  # the last absolute position this device sent

    def move(x, y):
        x = max(0, min(int(float(x)), xext - 1))
        y = max(0, min(int(float(y)), yext - 1))
        pos[0], pos[1] = x, y
        vp.motion_absolute(ms(), x, y, xext, yext)
        vp.frame()
        d.flush()

    def glide(x, y, steps):
        steps = max(1, int(steps))
        if pos[0] is None or steps == 1:
            move(x, y)
            d.roundtrip()
            return
        x0, y0 = pos
        for i in range(1, steps + 1):
            time.sleep(1 / 120)
            move(x0 + (float(x) - x0) * i / steps, y0 + (float(y) - y0) * i / steps)
        d.roundtrip()

    def rel(dx, dy, n=1, every_ms=16):
        for i in range(int(n)):
            if i:
                time.sleep(float(every_ms) / 1000)
            vp.motion(ms(), float(dx), float(dy))
            vp.frame()
            d.flush()
        d.roundtrip()

    def arrive(x, y):
        # what tap/drag do before a press: a motion the client sees on this
        # device, then a 1 px nudge and back (see tap)
        move(x, y)
        d.roundtrip()
        time.sleep(0.05)
        move(float(x) + 1, y)
        d.roundtrip()
        move(x, y)
        d.roundtrip()

    def button(b, pressed):
        vp.button(ms(), BTN.get(b, BTN["left"]), 1 if pressed else 0)
        vp.frame()
        d.flush()

    if cmd == "move":
        move(args[0], args[1])
    elif cmd == "click":
        b = args[0] if args else "left"
        for i in range(int(args[1]) if len(args) > 1 else 1):
            if i:
                time.sleep(0.3)
            button(b, True)
            d.roundtrip()
            time.sleep(0.05)
            button(b, False)
            d.roundtrip()
    elif cmd == "tap":
        move(args[0], args[1])
        d.roundtrip()
        time.sleep(0.08)
        move(float(args[0]) + 1, args[1])  # a second motion: the client's hover
        d.roundtrip()
        time.sleep(0.05)
        b = args[2] if len(args) > 2 else "left"
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
    elif cmd == "hover":
        arrive(args[0], args[1])
        time.sleep((float(args[2]) if len(args) > 2 else 800) / 1000)
    elif cmd == "rel":
        rel(args[0], args[1], *(args[2:4]))
    elif cmd == "seq":
        for step in args:
            w = step.split()
            if not w:
                continue
            op, a = w[0], w[1:]
            if op == "move":
                glide(a[0], a[1], a[2] if len(a) > 2 else 1)
            elif op == "rel":
                rel(a[0], a[1], *(a[2:4]))
            elif op in ("down", "up"):
                button(a[0] if a else "left", op == "down")
                d.roundtrip()
            elif op == "click":
                b = a[0] if a else "left"
                button(b, True)
                d.roundtrip()
                time.sleep(0.05)
                button(b, False)
                d.roundtrip()
            elif op == "scroll":
                vp.axis_source(0)
                vp.axis(ms(), 0, float(a[0]))
                vp.frame()
                d.roundtrip()
            elif op == "wait":
                time.sleep(float(a[0]) / 1000)
            else:
                sys.exit(f"vptr: seq: unknown step {step!r}")
    elif cmd == "drag":
        x1, y1, x2, y2 = map(float, args[:4])
        steps = int(args[4]) if len(args) > 4 else 30
        # HOLD_MS: rest at (X2, Y2), button still down, before letting go --
        # what the overview's hold-to-swap (hold_to_swap_ms) waits for. The
        # inner side runs under env -i, so it is an argument, not an env var.
        hold = float(args[5]) / 1000 if len(args) > 5 else 0.0
        btn = args[6] if len(args) > 6 else "left"
        if btn not in BTN:
            sys.exit(f"vptr: drag: button {btn!r} is not left, right or middle")
        if os.environ.get("VPTR_HOVER", "1") == "1":
            # A client window (Qt) only takes a press after a motion it saw on
            # this device (see tap); a 1 px nudge and back, before the press.
            arrive(x1, y1)
            time.sleep(0.05)
        else:
            move(x1, y1)
            d.roundtrip()
        button(btn, True)
        for i in range(1, steps + 1):
            time.sleep(1 / 120)
            move(x1 + (x2 - x1) * i / steps, y1 + (y2 - y1) * i / steps)
        d.roundtrip()
        if hold > 0:
            # Keep the drag alive while it rests: a 1 px wiggle every 100 ms,
            # the way a hand never holds perfectly still.
            end = time.monotonic() + hold
            k = 0
            while time.monotonic() < end:
                time.sleep(0.1)
                k ^= 1
                move(x2 + k, y2)
                d.roundtrip()
            move(x2, y2)
            d.roundtrip()
        button(btn, False)
    elif cmd == "path":
        pause = float(args[0]) / 1000
        pts = list(map(float, args[1:]))
        for i in range(0, len(pts) - 1, 2):
            move(pts[i], pts[i + 1])
            d.roundtrip()
            time.sleep(pause)
    else:
        sys.exit(f"vptr: unknown command {cmd}")
    d.roundtrip()
    vp.destroy()
    d.roundtrip()
    d.disconnect()


if __name__ == "__main__":
    main(sys.argv)
    os._exit(0)  # skip pywayland finalizers (they can SEGV at teardown)
