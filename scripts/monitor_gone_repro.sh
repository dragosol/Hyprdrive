#!/usr/bin/env bash
# REPRO: an overview that outlives its monitor kills the compositor.
#
# Not a gate -- a five-line reproduction of the defect that took the whole gate
# suite down on 2026-08-11, kept so the fix can be gated when someone owns it.
#
#   1. open the overview on an output
#   2. remove that output while it is still open
#   3. `overview off`
#
# Step 3 SIGSEGVs Hyprland inside CScrollOverview::close(), at
# scrollOverview.cpp:5052 -- `closeOnWindow->m_workspace == pMonitor->m_activeWorkspace`
# with pMonitor a PHLMONITORREF whose monitor is gone. Reproduced on every build
# from 1769513 (untouched parent) through 0b6782f; the plugin has no
# monitor-removed handler, so nothing tears the overview down with its output.
#
# It is not a test-only path: `hyprctl output remove` and pulling a DisplayPort
# cable arrive at the same place.
#
# Run it over ssh, never from a terminal inside the session -- it is expected to
# take the session with it. Exits 0 if the compositor SURVIVED (i.e. fixed), 1
# if it died (i.e. still broken), 2 if the rig could not set the scene up.
set -u
cd "$(dirname "$0")/.."
source scripts/lib/rig.sh
rig_env || exit 2

SIG0=$(rig_sig)
echo "instance before: $SIG0"

ov off; sleep 1.2

# One headless output, and the overview opened ON it.
for m in $(hyprctl monitors all -j | python3 -c "
import json,sys
print(' '.join(m['name'] for m in json.load(sys.stdin) if m['name'].startswith('HEADLESS')))"); do
    hyprctl output remove "$m" >/dev/null 2>&1; sleep 0.4
done
hyprctl output create headless >/dev/null 2>&1; sleep 1.5
HL=$(hyprctl monitors -j | python3 -c "
import json,sys
hs=[m['name'] for m in json.load(sys.stdin) if m['name'].startswith('HEADLESS')]
print(hs[0] if len(hs)==1 else '')")
[ -n "$HL" ] || { echo "REPRO ABORT: no headless output"; exit 2; }

hyprctl eval "return hl.monitor({output = [[Virtual-1]], disabled = true})" >/dev/null 2>&1; sleep 1.5
ov on; sleep 2.5
echo "overview open on $HL"

# Put the real output back and delete the one the overview is standing on --
# exactly what rig.sh's headless_off used to do while a rig had left it open.
hyprctl eval "return hl.monitor({output = [[Virtual-1]], disabled = false})" >/dev/null 2>&1; sleep 1.5
hyprctl output remove "$HL" >/dev/null 2>&1; sleep 1.5
echo "removed $HL from under the open overview"

ov off; sleep 3
NOW=$(rig_sig)
echo "instance after:  ${NOW:-gone}"
if [ "$NOW" = "$SIG0" ]; then
    echo "SURVIVED -- the overview outliving its monitor no longer kills close()"
    exit 0
fi
echo "DIED -- compositor restarted; see ~/.cache/hyprland/hyprlandCrashReport*.txt"
exit 1
