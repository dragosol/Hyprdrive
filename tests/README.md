# Tests

| what | how | needs |
| --- | --- | --- |
| host tests (unit tests, config/schema/manifest checks, the CLIs) | `make check` (also part of `make`) | the SDK env only |
| **behaviour gates** on a headless Hyprland | `make gates` | the rig (below), ~6 min |
| rig cases written for a human/agent tester | `tests/rig/*/README.md` | the rig |

## Behaviour gates (`tests/gates/`)

Automated checks of the behaviours the owner designed on purpose (Mosaic,
hybrid tiling, fullscreen desktops, focus, dock, overview, the speed setting),
so a refactor can be held against them. `tests/gates/COVERAGE.md` maps every
designed behaviour to its gate, or says why it has none.

```sh
source ~/sdk/hyprland-0.56.2/env.sh && make     # the gates test the .so already built
make gates                                       # every gate, one line each
make gates GATES="fs_trip mosaic"               # some
tests/gates/run.sh --so /abs/other/hyprdrive.so  # another build (e.g. a known-bad one)
tests/gates/run.sh --control --control-so /abs/8bb258c/hyprdrive.so   # every CONTROL: all must "fail as they must"
tests/gates/run.sh --list
```

Output: `PASS|FAIL|KNOWN-FAIL|SKIP <gate> <seconds> <reason>`; the run exits
non-zero on any FAIL. KNOWN-FAIL is a check the gate believes is right that
fails on the current build -- the reason names the evidence; drop the mark
when it passes. Logs of gates that did not pass stay in `/tmp/hdg-run.<pid>/`.

Needs: passwordless `sudo -n -u hyprtest` (the rig user), `mutter`, `kitty`,
`jq`, `xprop`, the xcb headers (x11_state builds its client), python3 with
PIL/numpy/scipy (pixel compares). Not part of `make`/`make check` for that reason.

### Writing a gate

`tests/gates/<name>.sh`, sourcing `tests/gates/lib.sh`:

- header: what it protects (the dated line of the designed-behaviours list),
  what it asserts, and its **control** -- the same checks with the feature's
  option off (`GATE_CONTROL=1`) or against a build with the bug (`--so`) --
  with the date it was seen to FAIL. A gate that cannot fail is worthless.
- `gate_begin <tag>` (instance `g<tag>`, cleanup trap), `rig_start`, then
  `check "name" "$(is A B)" "detail"`; `gate_end` stops the rig, fails on a core
  dump and prints the verdict. A 4th argument to `check` marks a known failure.
- fixtures are kitty with explicit sizes (`kw CLASS W H`, or `kexec` to launch
  through the compositor, which counts as a window the user asked for); wait
  by condition (`wait_for`, `settle`), not fixed sleeps, where a condition exists.
- `hq` is hyprctl pinned to the instance's runtime dir and signature, run as
  hyprtest: it can never reach the owner's session. Never bare hyprctl/grim/wtype.
- keep each gate under ~60 s; /tmp is RAM, so captures stay small and are
  deleted when the gate passes.
