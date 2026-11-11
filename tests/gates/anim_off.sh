#!/usr/bin/env bash
# anim_off -- with the speed setting at 0 or Hyprland's animations off, every hyprdrive frame source goes idle at once.
# Protects: the Speed setting (plugin:hyprdrive:anim_scale, "0 = snap") and
# animations:enabled = false -- nothing hyprdrive draws keeps the compositor
# repainting (designed behaviours: every motion is animated AND the user's
# speed setting stretches/snaps it; motion rules [feedback_apple_motion_rules]).
# `hyprdrive:debug frames` lists, per monitor, why it is repainting right now
# ("idle" when nothing is); `previews[...]` is the preview cache's book-keeping,
# not a frame source.
# Asserts, for anim_scale = 0 and then for animations:enabled = false (anim_scale 1):
#   150 ms after each of: overview open, overview close, the dock revealed by
#   the pointer at the bottom edge, a window minimized from the dock -- the
#   frame-source list is empty/idle, and no frame is drawn between +150 and +650 ms
# The dock reveal is not proven to happen (an idle dock reports nothing); the
# overview open and the minimize are.
# Control (--control): anim_scale = 1 with animations on -- the sources
# (scale, reflowPacer, idleRepaint, dock:*) are listed and frames are drawn,
# every check fails. Recorded 2026-11-11 on 3ad1da3: control FAILS as it must.
source "$(dirname "$0")/lib.sh"
gate_begin anm
rig_start
go 1; kw a1 700 450; kw a2 600 400; sleep 1
sources() { dbg frames | sed -n '3p' | sed -E 's/^ *[A-Z0-9-]+ \[[a-z]+\] *//; s/previews\[[^]]*\] *//; s/^idle$//; s/ *$//'; }
nframes() { dbg frames | sed -n '2p' | grep -oE '[0-9]+ frames' | grep -oE '[0-9]+' || echo 0; }
probe() { # LABEL: after the step, sources at +150 ms and frames drawn +150..+650
    sleep 0.15; local s n0 n1; s=$(sources); n0=$(nframes); sleep 0.5; n1=$(nframes)
    check "$MODE, $1: no frame source at +150 ms" "$(is "$s" '')" "sources: $s"
    check "$MODE, $1: no frame drawn +150..+650 ms" "$(is "$n1" "$n0")" "frames $n0 -> $n1"
}
run_steps() {
    $R ptr move 700 500 >/dev/null; sleep 1.2
    $R overview >/dev/null; probe "overview open"
    check "$MODE: the overview did open" "$(dbg gesture state | grep -q ' 1 overview' && echo 1)" "$(dbg gesture state | grep -o '[0-9]* overview.*')"
    $R overview >/dev/null; probe "overview close"
    $R ptr move 960 1079 >/dev/null; $R ptr hover 960 1079 400 >/dev/null; probe "dock revealed"
    $R ptr move 700 500 >/dev/null; sleep 1.2
    focus "$(addr_of a2)"; sleep 0.8; dbg activate a2 >/dev/null; probe "minimize from the dock"
    check "$MODE: a2 was minimized" "$(is "$(win a2 .workspace.name)" '"special:minimized"')" "$(win a2 .workspace.name)"
    dbg activate a2 >/dev/null; sleep 1
}
if [ "$CONTROL" = 1 ]; then
    MODE="anim_scale 1 (control)"; run_steps
else
    MODE="anim_scale 0"; cfg '{plugin={hyprdrive={anim_scale=0}}}'; run_steps
    MODE="animations off"; cfg '{plugin={hyprdrive={anim_scale=1}}, animations={enabled=false}}'; run_steps
fi
gate_end
