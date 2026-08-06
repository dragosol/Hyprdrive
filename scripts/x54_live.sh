#!/bin/bash
# X54 live gate. Opening the overview must warm the search providers, so the
# keystrokes after it get their rows without waiting on a GTK app to start,
# and refining must reuse the metas it already has instead of asking again.
# WARM=0 skips the open (types into an already-open overview) for the A side.
key() { ydotool key "$1:1" "$1:0" 2>/dev/null; sleep 0.09; }

echo "--- idle 50s so the provider apps exit ---"
sleep 50
echo -n "provider buses before open: "
busctl --user list --acquired | grep -cE 'Characters|clocks|Settings.SearchProvider'

MARK=$(date +%s)
hyprctl eval "return hl.dispatch(hl.plugin.scrolloverview.overview([[on]]))" >/dev/null
sleep 0.6
echo -n "provider buses 0.6s after open: "
busctl --user list --acquired | grep -cE 'Characters|clocks|Settings.SearchProvider'

for K in 35 18 30 19 20; do key $K; done   # h e a r t
sleep 3
hyprctl eval "return hl.dispatch(hl.plugin.scrolloverview.overview([[off]]))" >/dev/null
echo "--- trace since open ---"
journalctl --user --since "@$MARK" --no-pager -o cat 2>/dev/null | grep '\[sp\]'
