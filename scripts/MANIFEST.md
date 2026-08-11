# Gate manifest

Every promoted gate, what it proves, and how to run it. `scripts/suite.sh`
runs them all (guest-side, live compositor required) and exits nonzero on any
red. A gate that cannot run green here must not be worked around — fix the
build or fix the gate, never the verdict.

## What the suite guarantees (and what it cannot)

Two properties of `suite.sh` are load-bearing. Both were added on 2026-08-11
after a run in which 25 of 27 gates were red for one reason that none of them
named (see "Suite integrity" at the end of this file):

- **SLATE.** `gate_slate` (lib/rig.sh) puts the session back to a known state
  before every gate: plugin loaded, overview closed, every toplevel killed,
  exactly one output at 2560x1600, dock options at their registered defaults,
  `anim_scale=1`, workspace 1, and the ydotool pointer scale re-MEASURED. A gate
  that cannot get a clean slate reports `SLATE` and is red — it does not run and
  then blame the build. Gates run on their own do not need it, but may call it.
- **DIED.** The compositor's instance signature is compared across every gate.
  gdm restarts Hyprland about two seconds after a crash, so a runner that only
  reads exit codes cannot tell "this build is wrong" from "the compositor I was
  measuring is gone". A gate whose signature changed is `DIED` and red whatever
  it printed. `x51_text_cache` restarts it deliberately and declares that with a
  `restarts-compositor` marker file in its gate directory; nothing else may.

Row colours: green PASS/SKIP, red FAIL/SLATE, yellow DIED.

| Gate | Flow | Proves (DoD) | Runtime |
|---|---|---|---|
| `crash_gate` | stability | dangling-listener compositor segfault ('segfault at X ip X error 14' in plugin mmap range): search open -> tight backspace loop -> mouse move must SURVIVE; 8 cl | ~4-6 min for 8 laps |
| `fade_alpha` | open-overview | Chrome fade factor actually modulates alpha: settled overview at FADE=0.5 vs FADE=1 — chrome tint and the strip's live mini previews both scale with the factor, | ~10 min incl. one rebuild |
| `g1` | search | 13.11 G1: SPACE on empty query is a no-op (GNOME whitespace rule), bracketed by must-move controls that fail on a frozen output; G1 negative half: TAB/BACKSPACE | ~2-3 min |
| `g5` | search | 13.4 G5 (per its header §13.4): two result layouts with PER-PROVIDER caps — NODRIFT, LIVE (graded on the same frames, the X47 lesson), FOUND, CAPS >=6 distinct  | ~2 min (+ x48 fixture ~1 min) |
| `hover_overshoot` | click-tile | Tile hover must not OVERSHOOT (zero-bounce spring, the standing Apple-motion rule): peak sampled width never exceeds settled width; one maximal single-window fi | ~1 min |
| `reopen` | open-overview | A tap DURING the close animation (120ms into ~300ms) brings the overview back: REVERSED must land 30x nearer OPEN than SHUT, and OPEN vs SHUT must differ (ident | ~1 min |
| `x1_stress` | stability | 13.4 X1: many windows, heavy filtering, rapid desktop switching; must not fall over, LEAK, or CORRUPT STATE (P1 rapid-toggle, P2 held-open, P3 heavy-filter, P4  | ~8-10 min incl. fixture |
| `x24` | dock-click | X24 state: minimize keeps window MAPPED on special:minimized; restore returns it to its own ws, geometry unchanged, stacked on top (pixels, not focus — x24_gate | ~5-8 min for all halves |
| `x26` | drag-strip | X26 drag overview->dock + dock polish: P1 drop on pill minimizes; P2 near-miss 28px above pill does NOT (proves the pill's own bounds); P3 proxy shrinks by the  | ~2-3 min |
| `x28` | dock-click | 13.9 X28 dock context menu: P1 right-click draws a plate above the pill; P2 gutter press dismisses (frame returns to base); P3 bottom row Quit closes every wind | ~3 min |
| `x30` | dock-hover | 13.9 X30 autohide/reveal: hidden by default, pressure-threshold reveal (weak fails / lowthresh / strong passes), leave re-hides, hidden while overview open, hid | ~4 min all phases |
| `x34_hotkeys` | dock-click | 13.9 X34: Super+1..0 (slot ten = 0 key), Shift/Ctrl families, <Super>q shortcut at 2.0s timeout — asserted as STATE (minimized sets, class counts, launches); nu | ~4-5 min |
| `x43_raise` | click-tile | X43: clicking an overview tile RAISES the window — decided by PIXELS at the geometric overlap of two flat-colour windows, never focus (closed three times on a f | ~2 min |
| `x46_pill_invariant` | minimize-restore | 13.12 X46: a minimize must not add a dock entry — the strip band is pixel-identical (pill extent unchanged) before/after a minimize; ABORTs (not passes) if noth | ~1.5 min |
| `x47_hover_preview` | dock-hover | 13.12 X47: RISES / LIVE (contents change between frames) / FOLLOWS / GRACE, two controls before + one after, dilated noise mask, largest connected blob landing  | ~3-4 min incl. both frost arms |
| `x48_results_bottom` | search | 13.12 X48 / DoD 23: selected result row's top is below the overview's half-way line; DoD 18: search row + desktop strip are fixed chrome (quiet between a0 and b | ~1.5 min |
| `x50_pill_docks` | search | 13.12 X50: search bar animates up when results appear — DOCK (pill appears under the work-area top edge, vanishes from rest), NOMATCH negative control (pill wid | ~2 min |
| `x51_text_cache` | open-overview | X51: text served from the surviving glyph cache is PIXEL-IDENTICAL to text rendered fresh (A cold after compositor restart == B cached after 4 open/close laps), | ~1 min + one compositor restart |
| `y11_crossdesk_preview` | dock-hover | 13.14 Y11 (the regression gate on X99): a non-active-desktop dock preview is NON-BLANK (fixture magenta count in the panel band) and LIVE (changed pixels betwee | ~2 min |
| `y4_click_semantics` | dock-click | 13.14 Y4: plain dock click minimizes ALL of an app's windows, second click restores all, CTRL+click cycles (never stashes) — STATE via special:minimized, not pi | ~2 min |
| `y7_drag_glow` | drag-strip | 13.14 Y7: dock glow intensity correlated to drag distance within the bottom-30% band — OFF above the band, CONTINUOUS (rungs rise in steps, none is the whole ri | ~1.5 min |
| `y8_bounce_once` | drag-strip | 13.14 Y8: on drop-to-minimize the landing icon hops ONCE, macOS-like, 'not a decaying bounce train' — IT HAPPENS / ONE PEAK (no second hump above a third of the | ~2-3 min |
| `y9_filter_reveal` | search | Y9 as revised 2026-08-06: minimized windows show in the overview ONLY when a query matches — q0 no-query magenta ABSENT, q1 'MAGWIN' magenta PRESENT, q2 cleared | ~1.5 min |
| `z1_preview_survives_swaps` | dock-hover | Z1 (user report 2026-08-07): move window to another desktop, hover its dock preview, swap desktops back and forth — preview must still draw (h0 before swaps ==  | ~1.5 min |
| `z2_preview_click_goto` | dock-click | Z2 (user report 2026-08-07): clicking the dock preview goes to that window — view lands on its desktop AND it is focused; control click at the same height but o | ~1 min |
| `z3_position_memory` | drag-strip | Z3 (user report 2026-08-07): strip moves after the first must still remember coordinates — G1 main tile -> off-screen desktop mini (always worked, keep), G2 str | ~3 min |
| `zflight_z4_z7` | minimize-restore | z4: no hole at restore landing (green area never dips below 25% of steady after first exceeding 50%); z4t: tiled window's restore flies to its tile, not the sta | ~3-4 min for all six arms |

Run one gate: `scripts/gates/<name>/run.sh`. Its stdout+stderr land in
`scripts/gates/<name>/last.log` when run through the suite.

## Tools (`scripts/` root — instruments, not gates)

- `symcheck.sh` — Undefined-symbol lazy-bind time-bomb check against the host Hyprland binary; caught three session-killing symbols in one
- `generate-plugin-version.sh` — Build-time version stamp (git short hash + -dirty) into a generated header; Makefile dependency, stays with the build.
- `filmit.sh` — wf-recorder film of an animation from inside the guest — a held screencopy session keeps the starved output rendering wh
- `slowmo.sh` — Global anim_scale slowdown (default 20x) + frame-stepped stills of a minimize; readback-verified.
- `burst.sh` — Frame-by-frame uncompressed ppm burst into tmpfs (38ms/frame), converting after; answers 'animated or snap'. NOTE: hardc
- `anim_timing.sh` — Open/close duration via a 240x120 keyhole crop polled to settle (full-screen grim is slower than the animation being tim
- `settled_shot.sh` — One settled-overview frame with the wallpaper pinned via config.json so two runs are comparable; the capture instrument 
- `blob.py` — Largest connected blob of fixture green on the host (bbox-of-all-pixels is a check that cannot fail); imported by zfligh
- `pillbox.py` — FINDS the dock pill in a screenshot (widest bright run in the bottom eighth) — deliberately the opposite of the cell pre
- `hyprwall-rotate.sh` — Wallpaper rotation driven by hyprwall.timer in the guest; deliberately not switchwall.sh so col.active_border never move
- `x52_prof.sh` — Keystroke-to-paint profiling of the search path; needs a Prof::-instrumented build + SCROLLOVERVIEW_PROFILE=1 in the com
- `x51_open.sh` — Cold vs warm overview-open cost from the Prof log (first open after fresh compositor vs second).
- `x51_opens.sh` — Cold text renders per open across N successive opens — cache convergence-to-zero instrument.
- `monitor_gone_repro.sh` — Three-step reproduction of the compositor-killer below: open the overview on an output, remove that output, `overview off`. Exit 0 = survived (fixed), 1 = died. Run over ssh; it is expected to take the session with it.

## Attic

`scripts/attic/` holds one-shot probes kept for archaeology. Nothing runs them;
delete freely — git remembers.
- `anim_ab.sh` — one-shot A/B of old (3.0/2.2) vs new (2.6/1.9) open/close speed defaults; the decision shipped, only the in-se
- `flightab.sh` — one-shot question answered: the visible minimize motion was Hyprland's workspace-move animation, not the plugi
- `searchtest.sh` — diagnostic 'does typing filter at all', built to isolate Y9's failure; that liveness control now lives inside 
- `y9_film.sh` — film-based Y9 diagnostic from before y9_rig's triple-state capture existed; superseded
- `e8f_fixture3.sh` — E8-f tiled-fixture variant; bug fixed, strip-drop coverage now owned by z3; hardcodes wayland-1
- `e8f_gate.py` — E8-f gate (post-drop strip == reopened strip); the defect it guarded is fixed and z3/x26 cover the flow
- `e8f_probe1.sh` — E8-f first-drop probe; wayland-1 hardcode; inert
- `e8f_probe2.sh` — E8-f two-drops-one-session probe; wayland-1 hardcode; inert
- `x25_capture.sh` — original preview-liveness rig; superseded by x47's LIVE check + y11; leaves the guest with Virtual-1 disabled 
- `x25_gate.py` — grades x25_capture frames; superseded with it
- `x25_probe.sh` — CPU-tick blocked-client diagnostic for x25; one-shot
- `x25_wldebug.sh` — WAYLAND_DEBUG frame-callback vs commit counter diagnostic for x25; one-shot
- `x27_capture.sh` — dock pill proportions vs Dash-to-Dock; its reference constants predate the X53 layout block (x47_cell.py) so i
- `x27_gate.py` — same stale pre-X53 constants as x27_capture; inert with it
- `x29_capture.sh` — one-shot sigma/brightness fit translating dual-kawase size/passes into blur-my-shell units; question answered;
- `x29_gate.py` — the least-squares sigma recovery for x29; inert with it
- `x3b_gate.py` — strip focus-outline corner-radius gate; no rig for it in scripts/ (read share/x3b/shots), cosmetic bug fixed
- `x31_rig.sh` — badges/counters via the Unity LauncherEntry D-Bus protocol; a sound rig but its gate (x31_gate.py) lives only 
- `x35_rig.sh` — dock locations (trash/mounts) rig; its gate (x35_gate.py) lives only in share/; no suite flow owns locations t
- `onlymounted_rig.sh` — show_mounts_only_mounted=false fixture feeding x35_gate's mounts phase; goes wherever x35 goes
- `x41_drag.sh` — X41/X42 bestScale-era drag probe; its lessons (held press, jitter, X16) are codified in x43_click/z3_drag, and
- `x41_fixture.sh` — the bestScale<1 forcing fixture for x41; inert with it; wayland-1 hardcode
- `x49_rig.sh` — 'results are WIDE and CATEGORISED'; superseded by g5's two-layout grid (g5's own header: 'the case X49 could n
- `x49_gate.py` — superseded with x49_rig by g5_gate
- `fade_vid.sh` — video route for the chrome fade; its grader fade_gate.py is not in scripts/; the settled-shot route (fade_alph
- `x54_live.sh` — provider warm-on-open probe: 50s idle bake then human-read bus counts; one-shot
- `y3_probe.sh` — Y3 menu-on-plain-desktop behavioral probe (swallowed-press evidence), verified once; x28 owns menu coverage
- `y12_probe.sh` — Y1/Y2 hit-test proven once via the Dock::render file sink (/tmp/ovdbg.on); both pixel routes were dead on this
- `y12b_rig.sh` — dock-frost vs window-frost tint/radius separation (two-frequency backdrop); the 7afcf63 hypothesis it tested i
- `y12b_gate.py` — first-cut y12b grader (two frequencies, could not read the fine one); superseded by y12b_gate2 even within the
- `y12b_gate2.py` — the working FFT four-zone attenuation-curve version; keep as the starting point if frost parity ever needs re-
- `y13_poll.sh` — GDM-restart-to-wallpaper timing instrument (survives the restart via setsid); perf question answered
- `y13_qs.sh` — quickshell-alone wallpaper-up timing proxy; answered with y13_poll

## Suite integrity (2026-08-11) — why 25 of 27 gates were red

Worth reading before trusting or distrusting any table this suite prints.

**The mechanism, end to end.** `g1_rig.sh run` finished with the overview still
OPEN on its headless output. The g1 gate's EXIT trap then ran `headless_off`,
which REMOVED that output. `IOverview::pMonitor` is a weak ref and
`CScrollOverview::close()` dereferences it (scrollOverview.cpp:5052), so the
overview was left pointing at freed memory — and the next `overview off`, which
is the first line of g5's fixture, took Hyprland down with SIGSEGV. gdm's
`start-hyprland` restarted it about two seconds later **without the user
config**: `WARN: No config file found` in the new session's log, meaning no
`hl.plugin.load`, no monitor rule. The remaining 22 gates then ran against a
bare Hyprland with **no plugin loaded** and Virtual-1 at the virtio-gpu
preferred **1280x800** instead of 2560x1600.

Everything the P7 tables showed follows from that one crash:

- "the dock never drew even with autohide off" (x30), "no glow" (y7), "the pill
  never moved" (y8), "input did not land" (x50), "no accent row" (x48), "open
  and shut are near-identical" (reopen) — there was no plugin.
- `plugin:scrolloverview:dock:autohide is such` (x47) — `hyprctl getoption`
  answering "no such option", for the same reason.
- `warp landed at 622,777, not 1245,1555` (y11) — ydotool's absolute space is a
  fixed 1280x800 grid mapped onto the output its pointer is BOUND to, so on a
  1280x800 Virtual-1 the rig's halving lands every click at half.
- the numbers moving run to run — a rotating wallpaper under a suite that no
  longer had a plugin.

Reproduced on every build from `1769513` (untouched parent) to `0b6782f`, and
across a full VM reboot. `scripts/monitor_gone_repro.sh` is the three-line
reproduction; crash reports and the pluginless session log are in
`zrig/gatefire/`.

**What changed.** The harness, not the plugin: `ov_off_settled` in front of
every output teardown, `gate_slate` between gates, `DIED` detection in
`suite.sh`, a MEASURED ydotool scale, and the `cp -f` that z1/z2/x28 needed to
stage helpers onto the virtiofs share. Result on clean `0b6782f`: 27 gates, 13
red, twice in a row with identical verdicts and no compositor death.

**Still open (P0, plugin, not harness):** the crash itself. The plugin has no
monitor-removed handler, so an overview outliving its output remains a
compositor-killer — and `hyprctl output remove` and unplugging a DisplayPort
cable arrive at the same `close()`. The rig now avoids the situation; nothing
fixes it.

## Suite status (2026-08-08, Phase 1 landing)

The harness is proven: `rig.sh` env discovery, headless swap, capture-liveness
guard, and `suite.sh` run end to end — `x46_pill_invariant` is green through the
full path. The remaining gates are promoted (wrapper + rig.sh conversion done)
but validated incrementally as each becomes load-bearing for a later phase; a
gate is only trusted once it has FAILED on a known-bad build.

Known follow-ups (tracked, not worked around):
- `x43_raise`: the red-tile grab-point locator rejects the current overview
  render (fill 0.63, non-rectangular — it spans the real window and the card
  tile). Retune the locator before trusting this gate. *(2026-08-11: green on
  both runs of the post-fix pair — the locator's trouble was the pluginless
  session, not the locator.)*
- Pixel gates: the guest can raise a gnome-keyring "Authentication required"
  dialog that overlaps captures. *(2026-08-11: `gate_slate` kills it, along with
  every other stray toplevel, before each gate.)*
- `fade_alpha`, `x51_text_cache`: NEEDS-HOST (two builds / compositor restart);
  suite reports them SKIP (exit 3), not FAIL. *(2026-08-11: x51 now restarts gdm
  itself — it had been invoking share/hyprrestart.sh, a HOST script whose every
  step goes through ssh and which therefore did nothing at all from inside the
  guest.)*

## Gate baseline notes (2026-08-08)

- `x47_hover_preview`: BEHAVIOR half green. FROST A/B: the arm-alignment bug is
  FIXED -- both blur configs are now captured against ONE frozen hover
  (X47_FROST_PAIR in x47_rig.sh, frost-fa/frost-fb frames), so SAMEBACK is
  bit-identical (0.0/255) and BLURS reads the right way (HF 5.77 sharp -> 3.61
  frosted, frost suppresses). Frost is directionally confirmed. STILL red on
  TEXTURE/BACKDROP: in this fixture the panel renders over a low-contrast dark
  wallpaper region (backdrop luminance sd 14.8 < 20), so there is too little
  texture behind the plate to measure blur strength as an absolute pass/fail.
  Calibration follow-up: put a high-contrast surface behind the panel's actual
  render position (bottom-centre), or review the absolute texture thresholds,
  before treating the frost A/B as a trusted gate. Not a plugin frost defect --
  the plugin frost code is untouched and the behavior gate is green.

## Guest gate dependencies + known flakes (2026-08-09)

- The film gates (z4/z4t/z5) need `ffmpeg` in the guest; the pixel graders need
  `python3-pillow` + `python3-numpy`. Install once per guest.
- `zflight_z4_z7 :: z4c` is flaky at its precondition ("minimize 1 missed" --
  the first click misses the predicted dock cell; ~1 in 3 standalone runs is
  clean, and when it runs the geometry is invariant). Rig-hardening follow-up
  (sweep + settle harder before the first click), not a product defect.
