# insist.py W H SECONDS OUT: an X11 window of a FIXED size (WM_NORMAL_HINTS min ==
# max) that, like Wine's Battle.net login, asks for that size again on every
# ConfigureNotify it gets -- real or synthetic. Counts ConfigureNotify per second.
import sys, time
from Xlib import display, X, Xutil
W, H, secs, out = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
GROW_AT = float(sys.argv[5]) if len(sys.argv) > 5 else -1  # change its fixed size then (+100x+50)
grown = False
d = display.Display()
s = d.screen()
win = s.root.create_window(100, 100, W, H, 0, s.root_depth, X.InputOutput, X.CopyFromParent,
                           background_pixel=s.white_pixel, event_mask=X.StructureNotifyMask | X.ExposureMask)
win.set_wm_name("insist")
win.set_wm_class("hdtest.insist", "hdtest.insist")
win.set_wm_normal_hints(flags=Xutil.PMinSize | Xutil.PMaxSize, min_width=W, min_height=H, max_width=W, max_height=H)
win.map()
d.flush()
counts, sizes = {}, {}
start = time.time()
with open(out, "w", buffering=1) as f:
    while time.time() - start < secs:
        while d.pending_events():
            e = d.next_event()
            if e.type == X.ConfigureNotify and e.window == win:
                sec = int(time.time() - start)
                counts[sec] = counts.get(sec, 0) + 1
                sizes.setdefault(sec, set()).add((e.width, e.height))
                win.configure(width=W, height=H)   # insist, every time
                d.flush()
        if GROW_AT >= 0 and not grown and time.time() - start >= GROW_AT:
            W, H, grown = W + 100, H + 50, True
            win.set_wm_normal_hints(flags=Xutil.PMinSize | Xutil.PMaxSize, min_width=W, min_height=H, max_width=W, max_height=H)
            win.configure(width=W, height=H)
            d.flush()
        time.sleep(0.0005)
    for sec in range(secs):
        f.write("t=%2ds configure=%6d sizes=%s\n" % (sec, counts.get(sec, 0), sorted(sizes.get(sec, set()))[:3]))
    f.write("done\n")
