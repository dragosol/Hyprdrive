#!/usr/bin/env bash
# lifecycle -- plugin lifecycle: cold start from the config, unload/load, exit, three times; no cores, nothing left running.
# Protects (designed behaviours, Keybinds page [10-24, 11-04]): "`hyprdrive
# load|unload|update|reload` CLI" -- every one of them is an unload and/or a load
# of the running compositor's plugin, and the owner's rule "never crash the
# compositor".
# Asserts, three rounds of: Hyprland started with a config that calls
# hl.plugin.load (the way 00-plugin.lua does), two windows, the overview opened
# and closed, then `plugin unload`, `plugin load`, overview again, exit:
#   - hyprdrive is listed after the cold start and after each load, not after the unload
#   - the compositor answers after every step; no config errors at startup
#   - stop reports no core dump of the instance
#   - (builds with the Workers owner, e2db755) no thread named hd-* survives an
#     unload; SKIPPED with the reason on a build without it (3ad1da3 has none)
# Control (--control): HYPRDRIVE_TEST_MISSING_HOOK=renderWorkspace (the
# plugin's init must refuse to start without that hook) -- "listed after the
# cold start" fails. Recorded 2026-11-11 on 3ad1da3: control FAILS as it must.
source "$(dirname "$0")/lib.sh"
gate_begin lfc
SU test -r "$SO" || { install -m644 "$SO" "$GOUT/hyprdrive.so"; SO=$GOUT/hyprdrive.so; }   # the config loads it as hyprtest
CFG=$GOUT/plugin.lua
cat > "$CFG" <<LUA
hl.monitor({ output = "HEADLESS-1", mode = "1920x1080@60", position = "0x0", scale = 1 })
hl.monitor({ output = "WL-1", mode = "1920x1080@60", position = "-1920x0", scale = 1 })
hl.config({ general = { gaps_in = 5, gaps_out = 10, border_size = 2, layout = "dwindle" },
            misc = { disable_hyprland_logo = true, disable_splash_rendering = true, force_default_wallpaper = 0 },
            xwayland = { enabled = true } })
hl.plugin.load("$SO")
LUA
chmod 644 "$CFG"
listed() { hq plugin list 2>/dev/null | grep -q '^Plugin hyprdrive' && echo 1 || echo 0; }
alive() { hq -j monitors >/dev/null 2>&1 && echo 1 || echo 0; }
hdthreads() { local p; p=$(J instances | jq -r ".[] | select(.instance == \"$SIG\") | .pid"); SU sh -c "cat /proc/$p/task/*/comm 2>/dev/null" | grep -c '^hd-'; }
WORKERS=$(grep -c 'hd-app-info' "$SO" 2>/dev/null)
envs=(); [ "$CONTROL" = 1 ] && envs=(--env HYPRDRIVE_TEST_MISSING_HOOK=renderWorkspace)
for r in 1 2 3; do
    rig_start --config "$CFG" ${envs[@]+"${envs[@]}"}
    LOADED=$SO
    check "round $r: listed after a cold start from the config" "$(listed)" "plugin list: $(hq plugin list 2>&1 | head -1)"
    check "round $r: no config errors at startup" "$(is "$(SU cat "$ST/configerrors.start" | tr -d '[:space:]')" '')" "$(SU cat "$ST/configerrors.start" | head -2)"
    kw a; kw b; $R overview >/dev/null; sleep 0.8; $R overview >/dev/null; sleep 0.6
    hq plugin unload "$LOADED" >/dev/null 2>&1; sleep 0.8
    check "round $r: unloaded: alive, not listed" "$(is "$(alive)$(listed)" 10)" "alive/listed $(alive)$(listed)"
    if [ "$WORKERS" -gt 0 ]; then check "round $r: no hd-* thread after the unload" "$(is "$(hdthreads)" 0)" "$(hdthreads) left"
    elif [ $r = 1 ]; then subskip "hd-* threads gone after unload" "this build has no Workers owner (no hd-* thread names in the .so)"; fi
    hq plugin load "$LOADED" >/dev/null 2>&1; sleep 1
    check "round $r: loaded again: alive, listed" "$(is "$(alive)$(listed)" 11)" "alive/listed $(alive)$(listed)"
    $R overview >/dev/null; sleep 0.8; $R overview >/dev/null; sleep 0.6
    check "round $r: alive after the overview" "$(alive)" "no answer"
    rig_stop
    check "round $r: exit without a core dump" "$(is "$CORES" 0)" "$(cat "$GOUT/stop.log" | head -2 | tr '\n' ' ')"
done
gate_end
