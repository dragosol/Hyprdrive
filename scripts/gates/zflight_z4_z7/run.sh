#!/usr/bin/env bash
# zflight_z4_z7 -- guest-side orchestrator for all six z_rig.sh arms.
#   z7  dock click on a desktop the app has nothing on does NOT travel to it
#       (V6 superseded Z7's go-there; ws + focus + fixws)
#   z6  restore switches workspace at REQUEST time (mid-flight sample)
#   z4  no hole at restore landing            (filmed, zflight_gate.py)
#   z4t tiled restore flies to its tile       (filmed, zflight_gate.py)
#   z4c 3 cycles with a zombie overview leave geometry byte-identical
#   z5  continuity under click spam           (filmed, zflight_gate.py)
# z7/z6/z4c print their own verdict but exit 0 either way -- the verdict line
# is grepped. zflight_gate.py is host-vintage and hardcodes /tmp/zrig and
# /home/dragos/hyprvm/blob.py; both are staged here so it runs guest-side
# unmodified (frames stay on the share at /mnt/host/zrig, the grader reads a
# copy).
set -u
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$REPO"
source scripts/lib/rig.sh
rig_env || exit 1

ZRIG=/mnt/host/zrig
GRADE_DIR=/tmp/zrig            # zflight_gate.py globs this path
BLOB_DIR=/home/dragos/hyprvm   # ...and imports blob.py from this one

# z_rig.sh only ever STOPS hyprwall.timer; own the pause/resume properly here.
hyprwall_pause
trap hyprwall_resume EXIT

mkdir -p "$GRADE_DIR" "$BLOB_DIR" || exit 1
cp scripts/blob.py "$BLOB_DIR/" \
    || { echo "zflight: cannot stage blob.py at $BLOB_DIR (zflight_gate.py hardcodes that path)" >&2; exit 1; }

declare -A VERDICT
FAIL=0

run_arm() {  # self-verdicting arm: z7 z6 z4c -- exit code alone is not enough
    local arm=$1 out rc
    out=$(bash scripts/z_rig.sh "$arm" 2>&1); rc=$?
    printf '%s\n' "$out"
    alive_or_die "after $arm"
    if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q "^$arm PASS"; then
        VERDICT[$arm]=PASS
    else
        VERDICT[$arm]=FAIL; FAIL=1
    fi
}

film_arm() { # filmed arm: z4 z4t z5 -- the rig films, the gate judges
    local arm=$1
    if ! bash scripts/z_rig.sh "$arm"; then
        VERDICT[$arm]="FAIL (rig)"; FAIL=1; return
    fi
    alive_or_die "after $arm"
    if [ "$arm" = z4t ]; then
        # z_rig films z4t but leaves frame extraction to the driver (the z4 arm
        # extracts in-rig); same ffmpeg line as the z4 arm, nothing else.
        rm -f "$ZRIG"/z4t-*.png
        if ! ffmpeg -loglevel error -i "$ZRIG/z4t.mp4" "$ZRIG/z4t-%03d.png"; then
            VERDICT[$arm]="FAIL (extract)"; FAIL=1; return
        fi
    fi
    rm -f "$GRADE_DIR/$arm"-*.png
    if ! cp "$ZRIG/$arm"-[0-9]*.png "$GRADE_DIR/" 2>/dev/null; then
        VERDICT[$arm]="FAIL (no frames)"; FAIL=1; return
    fi
    if python3 scripts/zflight_gate.py "$arm"; then
        VERDICT[$arm]=PASS
    else
        VERDICT[$arm]=FAIL; FAIL=1
    fi
}

run_arm  z7
run_arm  z6
film_arm z4
film_arm z4t
run_arm  z4c
film_arm z5

# z5log rides on the z5 run: same clicks, same flights, the other instrument.
# The film says the picture was continuous; the plugin's own drawn-box log says
# the REVERSAL continued the old flight instead of restarting it, which is the
# claim, and which no 30fps pixel metric can carry (a 400ms EASE_OUT_EXPO moves
# ~900px between two frames). z_rig truncates $XDG_RUNTIME_DIR/ovdbg.log at the top of the
# z5 arm, so what it grades is this arm's flights and nothing else.
# ...and z5phase reads the same run a third way: as the FLIGHT STATE MACHINE's
# own transition log. z5/z5log both grade BOXES -- where the proxy was drawn --
# and the class of bug that produced the Z4-Z20 saga is a flight left in a state
# nobody landed: hidden, stashed, mid-geometry. That has no box at all. This arm
# asks whether every flight armed reached Done, whether every landing passed its
# invariant, and whether any reversal bailed silently.
if [ "${VERDICT[z5]}" = PASS ] || [ "${VERDICT[z5]}" = FAIL ]; then
    for arm in z5log z5phase; do
        if python3 scripts/zflight_gate.py $arm; then
            VERDICT[$arm]=PASS
        else
            VERDICT[$arm]=FAIL; FAIL=1
        fi
    done
else
    VERDICT[z5log]="SKIP (z5 rig fault)"
    VERDICT[z5phase]="SKIP (z5 rig fault)"
fi

echo
for a in z7 z6 z4 z4t z4c z5 z5log z5phase; do printf '%-8s %s\n' "$a" "${VERDICT[$a]:-SKIP}"; done
exit $FAIL
