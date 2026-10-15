#!/usr/bin/env python3
"""Keep one virtual keyboard attached to the headless Hyprland's seat.

A headless Hyprland has no keyboard at all, so the seat never gives a window
keyboard focus ("BUG THIS: setKeyboardFocus without a valid keyboard set") and
a transient wtype keyboard types into nothing. hl.sh start runs this in the
background for the life of the instance.

It also TYPES, reading "<id> <command>" lines from the FIFO $HL_VKBD_FIFO
(and acking <id> in $HL_VKBD_FIFO.ack once the keys are sent):
    type <text>          US-layout text (shift handled)
    tap <Name>[+<Name>]  e.g. tap Escape, tap Super+Tab, tap Ctrl+Shift+t
    down <Name> / up <Name>
Typing through this one long-lived device matters: wtype adds a NEW keyboard
device per call, and hyprdrive's overview treats that like a fresh keyboard
(the first key of `wtype term` closed the overview, "erm" went to kitty).
Keymap: us, compiled with libxkbcommon via ctypes (no xkbcli on fedora).
"""
import ctypes
import os
import selectors
import signal
import sys
import time

from pywayland.client import Display
from hlproto.wayland import WlSeat
from hlproto.virtual_keyboard_unstable_v1 import ZwpVirtualKeyboardManagerV1

# evdev keycodes (linux/input-event-codes.h); the wire keycode is evdev.
KEYS = {"Escape": 1, "BackSpace": 14, "Tab": 15, "Return": 28, "Enter": 28, "space": 57,
        "Ctrl": 29, "Control": 29, "Shift": 42, "Alt": 56, "Super": 125, "Meta": 125,
        "Up": 103, "Left": 105, "Right": 106, "Down": 108, "Home": 102, "End": 107,
        "Page_Up": 104, "Page_Down": 109, "Delete": 111, "Insert": 110}
for i, c in enumerate("1234567890"):
    KEYS[c] = 2 + i
for row, start in (("qwertyuiop", 16), ("asdfghjkl", 30), ("zxcvbnm", 44)):
    for i, c in enumerate(row):
        KEYS[c] = start + i
for i in range(1, 11):
    KEYS[f"F{i}"] = 58 + i
KEYS.update({"F11": 87, "F12": 88})
# Keys a desktop config binds that the tests press: Print and the media keys
# (the us keymap gives them their XF86 keysyms), and the backtick.
KEYS.update({"Print": 99, "grave": 41, "XF86AudioMute": 113, "XF86AudioLowerVolume": 114,
             "XF86AudioRaiseVolume": 115, "XF86AudioNext": 163, "XF86AudioPlay": 164,
             "XF86AudioPrev": 165, "XF86Calculator": 140})
PLAIN = {"-": 12, "=": 13, "[": 26, "]": 27, ";": 39, "'": 40, "`": 41, "\\": 43,
         ",": 51, ".": 52, "/": 53, " ": 57, "\n": 28, "\t": 15}
SHIFTED = dict(zip('!@#$%^&*()', range(2, 12)))
SHIFTED.update({"_": 12, "+": 13, "{": 26, "}": 27, ":": 39, '"': 40, "~": 41, "|": 43,
                "<": 51, ">": 52, "?": 53})
# xkb modifier masks for the us keymap: Shift=1, Control=4, Mod1(Alt)=8, Mod4(Super)=64
MODMASK = {42: 1, 29: 4, 56: 8, 125: 64}


def us_keymap() -> bytes:
    xkb = ctypes.CDLL("libxkbcommon.so.0")
    xkb.xkb_context_new.restype = ctypes.c_void_p
    xkb.xkb_keymap_new_from_names.restype = ctypes.c_void_p
    xkb.xkb_keymap_new_from_names.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int]
    xkb.xkb_keymap_get_as_string.restype = ctypes.c_void_p
    xkb.xkb_keymap_get_as_string.argtypes = [ctypes.c_void_p, ctypes.c_int]

    class Names(ctypes.Structure):
        _fields_ = [(f, ctypes.c_char_p) for f in ("rules", "model", "layout", "variant", "options")]

    ctx = xkb.xkb_context_new(0)
    names = Names(None, None, b"us", None, None)
    km = xkb.xkb_keymap_new_from_names(ctx, ctypes.byref(names), 0)
    if not km:
        sys.exit("vkbd: xkb keymap compile failed")
    p = xkb.xkb_keymap_get_as_string(km, 1)  # XKB_KEYMAP_FORMAT_TEXT_V1
    s = ctypes.string_at(p)
    ctypes.CDLL(None).free(ctypes.c_void_p(p))
    return s + b"\0"


def main():
    d = Display()
    d.connect()
    reg = d.get_registry()
    found = {}

    def on_global(_reg, name, iface, ver):
        found.setdefault(iface, (name, ver))  # must return None (cffi callback)

    reg.dispatcher["global"] = on_global
    d.roundtrip()
    seat = reg.bind(found["wl_seat"][0], WlSeat, 1)
    mgr = reg.bind(found["zwp_virtual_keyboard_manager_v1"][0], ZwpVirtualKeyboardManagerV1, 1)
    kb = mgr.create_virtual_keyboard(seat)
    km = us_keymap()
    fd = os.memfd_create("hl-keymap", os.MFD_CLOEXEC)
    os.write(fd, km)
    os.lseek(fd, 0, os.SEEK_SET)
    kb.keymap(1, fd, len(km))  # WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1
    d.roundtrip()
    os.close(fd)
    print("vkbd: virtual keyboard attached", flush=True)
    # os._exit, never a normal interpreter teardown: pywayland's finalizers
    # on a dead/closing display SEGV python (one core per hl.sh stop)
    signal.signal(signal.SIGTERM, lambda *_: os._exit(0))

    mods = 0

    def ms():
        return int(time.monotonic() * 1000) & 0xFFFFFFFF

    def key(code, down):
        nonlocal mods
        kb.key(ms(), code, 1 if down else 0)
        if code in MODMASK:
            mods = (mods | MODMASK[code]) if down else (mods & ~MODMASK[code])
            kb.modifiers(mods, 0, 0, 0)
        d.flush()
        time.sleep(0.012)

    def tap(codes):
        for c in codes:
            key(c, True)
        for c in reversed(codes):
            key(c, False)

    def code_of(name):
        if name in KEYS:
            return KEYS[name]
        if name.lower() in KEYS:
            return KEYS[name.lower()]
        raise KeyError(name)

    def handle(line):
        cmd, _, arg = line.partition(" ")
        if cmd == "type":
            for ch in arg:
                if ch.isupper():
                    tap([42, KEYS[ch.lower()]])
                elif ch in SHIFTED:
                    tap([42, SHIFTED[ch]])
                elif ch in PLAIN:
                    tap([PLAIN[ch]])
                elif ch in KEYS:
                    tap([KEYS[ch]])
                else:
                    print(f"vkbd: cannot type {ch!r}", flush=True)
        elif cmd == "tap":
            tap([code_of(n) for n in arg.split("+")])
        elif cmd in ("down", "up"):
            key(code_of(arg), cmd == "down")
        else:
            print(f"vkbd: unknown command {line!r}", flush=True)

    fifo = os.environ.get("HL_VKBD_FIFO")
    sel = selectors.DefaultSelector()
    sel.register(d.get_fd(), selectors.EVENT_READ, "wl")
    buf = b""
    if fifo:
        if not os.path.exists(fifo):
            os.mkfifo(fifo, 0o600)
        ffd = os.open(fifo, os.O_RDWR | os.O_NONBLOCK)  # RDWR: never sees EOF
        sel.register(ffd, selectors.EVENT_READ, "fifo")
    while True:
        d.flush()
        for k, _ in sel.select():
            if k.data == "wl":
                if d.dispatch(block=True) == -1:
                    os._exit(0)  # compositor gone
            else:
                buf += os.read(ffd, 65536)
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    # "<id> <command>": handled synchronously, then <id> is
                    # written to $HL_VKBD_FIFO.ack so hl.sh can wait for it
                    rid, _, cmdline = line.decode().partition(" ")
                    try:
                        handle(cmdline)
                    except Exception as e:  # keep the keyboard alive
                        print(f"vkbd: {line!r}: {e}", flush=True)
                    d.roundtrip()
                    with open(fifo + ".ack.tmp", "w") as f:
                        f.write(rid)
                    os.replace(fifo + ".ack.tmp", fifo + ".ack")


if __name__ == "__main__":
    try:
        main()
    finally:
        sys.stdout.flush()
        os._exit(0)
