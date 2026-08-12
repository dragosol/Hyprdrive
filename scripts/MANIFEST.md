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
| `x32_showapps_fresh` | dock-click | X32: a fresh open from the dock's Show Applications button starts CLEAN — the button is the one entry into the overview that skipped the dispatcher's search-session reset, so a query typed into a previous open came back with it. Closes by TILE CLICK, never `ov off` (that IS the dispatcher and would do the reset itself); NODRIFT floor, LIVE (the query landed), CLEAN (button frame == unfiltered), DISTINCT (button frame != queried frame) | ~1.5 min |
| `x34_hotkeys` | dock-click | 13.9 X34: Super+1..0 (slot ten = 0 key), Shift/Ctrl families, <Super>q shortcut at 2.0s timeout — asserted as STATE (minimized sets, class counts, launches); nu | ~4-5 min |
| `x43_raise` | click-tile | X43: clicking an overview tile RAISES the window — decided by PIXELS at the geometric overlap of two flat-colour windows, never focus (closed three times on a f | ~2 min |
| `x46_pill_invariant` | minimize-restore | 13.12 X46: a minimize must not add a dock entry — the strip band is pixel-identical (pill extent unchanged) before/after a minimize; ABORTs (not passes) if noth | ~1.5 min |
| `x47_hover_preview` | dock-hover | 13.12 X47: RISES / LIVE (contents change between frames) / FOLLOWS / GRACE, two controls before + one after, dilated noise mask, largest connected blob landing  | ~3-4 min incl. both frost arms |
| `x48_results_bottom` | search | 13.12 X48 / DoD 23: selected result row's top is below the overview's half-way line; DoD 18: search row + desktop strip are fixed chrome (quiet between a0 and b | ~1.5 min |
| `x50_pill_docks` | search | 13.12 X50: search bar animates up when results appear — DOCK (pill appears under the work-area top edge, vanishes from rest), NOMATCH negative control (pill wid | ~2 min |
| `x51_text_cache` | open-overview | X51: text served from the surviving glyph cache is PIXEL-IDENTICAL to text rendered fresh (A cold after compositor restart == B cached after 4 open/close laps), | ~1 min + one compositor restart |
| `x53_compat_alias` | config | Phase 9 rename compat: A a value set under `plugin:scrolloverview:` is readable under `plugin:hyprdrive:` (through a real fragment + `hyprctl reload`, bracketed by a negative control and a restore); B a dispatch through the old `hl.plugin.scrolloverview.*` namespace reaches the same handler, asserted as STATE (special:minimized), not pixels; C exactly ONE deprecation warning for the whole session however many old names were used. The one gate that deliberately does NOT route the old name through `$RIG_NS`. Fails at its first step on any pre-rename build (zrig/phase9/x53-on-parent.log) | ~1 min |
| `y11_crossdesk_preview` | dock-hover | 13.14 Y11 (the regression gate on X99): a non-active-desktop dock preview is NON-BLANK (fixture magenta count in the panel band) and LIVE (changed pixels betwee | ~2 min |
| `y4_click_semantics` | dock-click | 13.14 Y4: plain dock click minimizes ALL of an app's windows, second click restores all, CTRL+click cycles (never stashes) — STATE via special:minimized, not pi | ~2 min |
| `y7_drag_glow` | drag-strip | 13.14 Y7: dock glow intensity correlated to drag distance within the bottom-30% band — OFF above the band, CONTINUOUS (rungs rise in steps, none is the whole ri | ~1.5 min |
| `y8_bounce_once` | drag-strip | 13.14 Y8: on drop-to-minimize the landing icon hops ONCE, macOS-like, 'not a decaying bounce train' — IT HAPPENS / ONE PEAK (no second hump above a third of the | ~2-3 min |
| `y9_filter_reveal` | search | Y9 as revised 2026-08-06: minimized windows show in the overview ONLY when a query matches — q0 no-query magenta ABSENT, q1 'MAGWIN' magenta PRESENT, q2 cleared | ~1.5 min |
| `z1_preview_survives_swaps` | dock-hover | Z1 (user report 2026-08-07): move window to another desktop, hover its dock preview, swap desktops back and forth — preview must still draw (h0 before swaps ==  | ~1.5 min |
| `z2_preview_click_goto` | dock-click | Z2 (user report 2026-08-07): clicking the dock preview goes to that window — view lands on its desktop AND it is focused; control click at the same height but o | ~1 min |
| `z3_position_memory` | drag-strip | Z3 (user report 2026-08-07): strip moves after the first must still remember coordinates — G1 main tile -> off-screen desktop mini (always worked, keep), G2 str | ~3 min |
| `z10_theme_adopt` | config | Phase 10 theme adoption, end to end: a wallpaper swap through the rice's own rotation script (`THEME=1`) must repaint the dock pill AND the overview strip ring with no compositor restart and nobody typing anything — asserted by requiring the systemd path unit to have fired (service InvocationID changes, theme-sync's log grows) rather than by the gate not calling it. Two-sided in one run: P1 inherits (dock delta 14.54 over a backdrop control of 0.00, cos 1.000 against the move the palette predicts; ring 1311 -> 0 old, 0 -> 1310 new), P2 pins the dock's accent keys in a later-sorting fragment (dock delta 0.00 while the overview still repaints). Red two ways on the old world and they fail differently: with nothing installed the overview arms pass on Hyprland's own config-file auto-reload and the dock arms sit at 0.00 (`zrig/phase10/z10-on-parent.log`); with the derived fragment present and the sync off, BOTH accents freeze (`z10-stale-pin.log`) | ~4 min |
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
- `x52_prof.sh` — Keystroke-to-paint profiling of the search path; needs a Prof::-instrumented build + HYPRDRIVE_PROFILE=1 in the com
- `x51_open.sh` — Cold vs warm overview-open cost from the Prof log (first open after fresh compositor vs second).
- `x51_opens.sh` — Cold text renders per open across N successive opens — cache convergence-to-zero instrument.
- `x32_cell.py` — Predicts the Show Applications button's centre. Separate from x24_cell.py, which models the button as OFF (every gate using it sets show_apps_button=false) — the button is a slot of its own and teaching x24 about it would move predictions nobody asked to move.
- `monitor_gone_repro.sh` — Three-step reproduction of the compositor-killer below: open the overview on an output, remove that output, `overview off`. Exit 0 = survived (fixed), 1 = died. Run over ssh; it is expected to take the session with it.
- `monitor_gone_variants.sh` — The four states the repro does not cover: the output removed while the overview is still ANIMATING open, while a search query is up, and while a dock MINIMIZE and a dock RESTORE flight are in the air. Each variant carries its own positive control (the search proves itself with a frame diff across the keystrokes; a flight proves itself by the stash, and a restore flight by the window being hidden) so a variant cannot pass by never reaching the state it names. Exit 0 = every variant survived and landed sanely, 2 = a scene could not be set up. Run over ssh.
- `p8_ab.sh` + `p8_diff.py` — Phase-8 drag A/B: four drags (within a card, onto another desktop's strip cell, a near miss above the dock pill, onto it), each captured as frames + every window's geometry + the drop dump, then graded parent-vs-child against a same-build noise floor. Coordinates are measured ONCE and reused by every run of both builds; the wallpaper rotation is held for the whole A/B, not per run (a per-run resume rotates it under the next pass and every frame diff then measures the wallpaper -- 1.5M px of it). Needs the temporary instrumentation described in the script header; that patch is deliberately not committed.
- `drop_table_test.cpp` — Exhaustive host-side table test for `ScrollOverview::Drop::resolve()`: 16 boolean facts, all 65536 combinations, against the pre-split branch ladder transliterated from a4189e2. Needs no compositor and no Hyprland headers. `g++ -std=c++2b -O2 -o /tmp/drop_table_test scripts/drop_table_test.cpp && /tmp/drop_table_test`.
- `fragment.py` — The whole config-fragment mechanism: `write` rewrites a fragment's machine-owned half from stdin and puts the user's raw-snippet block back verbatim, `raw` prints that block, `check` fails when the markers are missing. Two line-anchored markers, no nesting, no escaping -- the format is deliberately too dumb to lose somebody's config, and it is what the Phase-11 settings app writes through.
- `install-fragments.sh` — Lays `config/hyprdrive/*.lua` down in `~/.config/hypr/hyprdrive/`, preserving every raw-snippet block already on disk. Reinstalling the defaults and the settings app writing one value are the same operation, so hand edits survive by construction rather than by remembering to.
- `gen_keys_table.sh` — Generates `docs/CONFIG.md` from `Config.cpp`'s registerConfigValues(); `--check` fails when it is stale. The hand-written table it replaced had two wrong defaults and covered six of seventy-nine keys.

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
- `plugin:scrolloverview:dock:autohide is such` (x47, quoted as it was logged -- the key is `plugin:hyprdrive:dock:autohide` since Phase 9) — `hyprctl getoption`
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

**Closed 2026-08-12 (P0, plugin):** the crash itself. The plugin now hooks
`monitor.removed` and drops every overview standing on the leaving output
through `dropScrollOverviewsForMonitor` — the manager's existing dying-overview
park, so the destructor runs a tick later instead of inside the signal callback.
`close()` additionally no-ops on a dead monitor as a failsafe, and dock flights
are settled at the same moment (a restore flight hides its real window for the
length of the animation, so one that never lands is a window the user cannot get
back). `monitor_gone_repro.sh` goes 1 → 0 across the fix and
`monitor_gone_variants.sh` covers mid-open, mid-search and both flight
directions; evidence in `zrig/p0monitor/`. The rig's `ov_off_settled` /
`headless_off` ordering stays: it is still the right order, it is simply no
longer load-bearing.

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

## Phase 10 notes (2026-08-12)

- **Every "opaque" kitty fixture in this guest is 8% wallpaper.**
  `custom/rules.lua:40` applies `opacity 0.92 0.86` to class `.*`, and kitty's
  own `-o background_opacity=1.0` does not override a compositor window rule.
  Any gate whose claim rests on a solid-colour backdrop is measuring the
  photograph behind it as well; `z10_theme_adopt` pins its own fixture with a
  later `hl.window_rule` and then CHECKS the frame (`off < 3`) before measuring.
  Worth auditing the other pixel gates for the same assumption.
- **`hyprctl reload` re-applies the monitor config.** It re-enables Virtual-1
  and drops a rig's headless output to 1920x1080 at x=2560, and it discards live
  `hl.config` writes. A gate that reloads mid-run must put its own session
  settings in a config fragment, where the reload re-applies them instead of
  undoing them, rather than setting them live.
- **Hyprland 0.56 auto-reloads on a change to a file it has already sourced**
  (a NEW file is not watched until some reload has sourced it). That is how
  matugen's `hyprland/colors.lua` reached the running session before this phase,
  and it is why `05-theme-derived.lua` has to be regenerated rather than merely
  written.

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

## Harness follow-ups (2026-08-11, after the gate fire)

Ranked. None of these is worked around anywhere; they are the next things that
would make a suite verdict worth more.

1. `g1_gate.py` diffs whole frames with an absolute 400 px floor, no mask and no
   blob — and this desktop is not still. The bar clock, the CPU readouts and the
   big desktop clock widget tick under the overview, and g1's own "no drift
   between two idle frames" control has been measured at 2849 px on frames it
   then graded. It reads green when g1 runs first after a compositor restart
   (quickshell's widgets are not up yet) and red mid-suite, on the same build.
   Mask the bar and the clock widget, dilate, take the largest connected blob.
   Until then g1's red says nothing about the build, and a build A/B that moves
   g1's position in the run is measuring the position.
2. `g1_rig.sh` and `x48_rig.sh` hand-roll their headless output and never set
   its mode, so g1/g5/x48/x50 run at the headless default 1920x1080 while every
   cell predictor (x24_cell, x45dock_cell, x47_cell, x32_cell) hardcodes
   2560x1600. They hand-roll it because `headless_on` installs an EXIT trap that
   would tear the output down when the fixture script exits — so the fix is to
   set the mode explicitly there, not to call headless_on.
3. `gate_slate` restores the seven dock options and anim_scale that gates
   actually write. A gate that changes anything else still owns restoring it,
   and will find out the hard way.
4. `z3_position_memory`'s FIRST gesture locates its drop target by taking the
   largest blob of a broad yellow mask over the WHOLE frame, and this desktop
   has a photograph behind the overview. On wp03 (dry golden hillsides, 5.3% of
   its pixels inside that mask) the biggest yellow blob is the wallpaper --
   2871 px at (1925,1217), colour [193 143 84] -- while the strip mini it
   wanted is the third-largest at 570 px. G1 then drags the window into the
   main card instead of onto a strip cell and the gate reports "position lost".
   Its own G2 and G3 already search only the strip band and are unaffected.
   Deterministic, not flaky, and NOT a build difference: identical numbers on
   HEAD and on a4189e2 (zrig/phase8/Z3_FINDING.md). Fix: G1 searches the band,
   or takes the largest blob whose box lands inside a strip cell. Eleven of the
   twenty-two wallpapers score 0.0% on that mask, which is why the gate has
   been green until now.

## Guest gate dependencies + known flakes (2026-08-09)

- The film gates (z4/z4t/z5) need `ffmpeg` in the guest; the pixel graders need
  `python3-pillow` + `python3-numpy`. Install once per guest.
- `zflight_z4_z7 :: z4c` is flaky at its precondition ("minimize 1 missed" --
  the first click misses the predicted dock cell; ~1 in 3 standalone runs is
  clean, and when it runs the geometry is invariant). Rig-hardening follow-up
  (sweep + settle harder before the first click), not a product defect.

## The wallpaper hold was not holding (2026-08-12, fixed)

Two gates are graded on the wallpaper itself -- `x64`'s frost half compares
detail through the app against the wallpaper's own detail (`pinwall.sh` pins
wp17 because it measures ~9 there), and `z3` is a colour locator this file
already records as flipping with the picture. Both went red in a back-to-back
pair and neither was a build difference: the wallpaper moved **four times**
during a run that had asked for 180 minutes of stillness (journal: 14:27 wp15,
14:31 wp11, 14:46 wp21, 15:03 wp20), and x64 was handed a photograph measuring
2.0 where wp17 measures 9.

Two causes, both fixed:

- `g5_rig.sh`, `x48_rig.sh`, `x50_rig.sh` and `x50_flight.sh` drove
  `hyprwall.timer` with **raw systemctl** although all four source `lib/rig.sh`.
  `hyprwall_pause`/`hyprwall_resume` have honoured `RIG_HYPRWALL_HELD` since the
  suite learned to hold the wallpaper; systemctl cannot. And the start is not
  "resume later": `hyprwall.timer` carries `OnUnitActiveSec=3min`, which has
  usually already elapsed, so `systemctl start` **is a rotation**.
- `hyprwall_pause` re-arms its dead-man **by unit name**, so the last caller
  wins -- `x1_fixture.sh`'s bare 30-minute pause silently replaced the suite's
  180-minute one. It now returns early under `RIG_HYPRWALL_HELD`, and `suite.sh`
  arms its own dead-man *before* declaring the hold.

Proof: the same build, same conditions, wallpaper pinned before each run --
`suite-head-7a57070.log` (four rotations, 16 red, x64/z3/x60 red) vs
`suite-head-20c69d9.log` (**zero** rotations, wallpaper still wp17 at the end,
13 red, x64 and z3 green). Only x60 was a real defect; the other two were the
photograph.

`y8_run.sh` has the same shape and is deliberately left alone: it is the
host-side driver the y8 gate was ported away from, it does not run inside the
suite, and its `systemd-run` has no `--unit` so it cannot collide with the
dead-man.

## Phase 11 -- the settings app (2026-08-12)

Four gates, and between them they cover the app's whole claim. None of them
drives the QML: the app is a renderer over `scripts/hdctl.py`, so the round-trips
drive that and the one gate that needs the window films it.

| gate | clause | what it proves |
| --- | --- | --- |
| `x60_settings_schema` | 13.9 X36-X40 | docs/schema.json is current against Config.cpp and the Hyprland snapshot; every entry routes to a pane that exists; and the drift check has been SEEN to fail -- the gate adds a real `CBoolValue` to Config.cpp, requires both `--check`s to go red and name the key, and puts it back. |
| `x61_blur_roundtrip` | 13.8 blur, user law | the app writes `decoration:blur:size` into 41-blur.lua, the compositor reports it, and the frost visibly changes through a translucent fixture over a hard black/white seam (285600 px blob, controls both sides at 0). `unset` restores the file and the option. |
| `x62_raw_and_pin` | Phase 9 raw block, Phase 10 masking | a line typed into the Blur pane's raw editor survives the app rewriting the machine half AND theme-sync regenerating the derived fragment, and is still in effect; all six `dock:blur_*` are -1 so it fans out without naming the dock; and `hdctl set` on a derived key IS a pin -- theme-sync reports it masked, stands the derived value down, and leaves the unpinned accent following. |
| `x63_monitor_countdown` | 13.9, monitors | the keep-these-settings leash, three ways: expired (scale back, fragment byte-identical), confirmed (held past the deadline), and CRASHED -- the watcher killed with the countdown open, nothing reverts it, and the next `hdmon check` (which the launcher runs before the window is drawn) does. |
| `x64_app_obeys_laws` | user law: frost, Apple motion | the app's own surface: detail through it is cut to ~46% of the wallpaper's and is not flat (frosted, not painted over); its open and close are filmed and the open decelerates, the close accelerates, and the exit is measurably shorter. |

### What x61 does NOT claim, and why

The revert half of the blur round-trip is graded on the fragment and on
`hyprctl getoption`, not on pixels. Measured 2026-08-12: raising the blur size
repaints once, and after that nothing under that window repaints again -- not
lowering it back, not a brightness change, not a window nudge, not
`dispatch forcerendererreload` -- while `getoption` reports the new value every
time. Hyprland caches the blurred backdrop (`decoration:blur:new_optimizations`)
and a desktop where nothing moves never damages it; the reload that lands the
first change is itself the damage that makes that one visible. Turning the
optimization off does not help: the headless output then stops producing frames
at all and every pair including the controls comes back byte-identical, which is
a starved output rather than a result. The plugin already has a key about this
cache (`live_layer_frost`, "the stale optimized blur FB"), so it is a known
property of the system. Evidence: `zrig/phase11/x61/`.

### x64's split verdict

A film times an eased animation short, always -- the tail of an OutCubic opacity
ramp moves too few pixels to clear any noise floor. Measured: 216 ms for a 300 ms
animation and 166 ms for a 230 ms one, the same 0.72 factor twice, which is the
instrument and not the app. So the film decides SHAPE (decelerate in, accelerate
out -- the check that catches a linear fade) and direction, and
`Motion.qml`'s constants decide DURATION and the 20-30% ratio, read out of the
file the app actually runs on. The film keeps a veto: anything under 100 ms did
not happen. The measured ratio is reported but not graded; two runs of the same
build gave 23.1% and 33.4%, which is the under-read varying, not the app.

## Phase 12 -- profiles, theme import, wallpaper repos (2026-08-12)

Three gates, one per item, and each is a full round trip rather than a
demonstration. None of them drives the QML: the panes are renderers over
`hdprof.py`, `hdimport.py` and `hdwall.py`, so the gates drive those. None of
them makes a pixel claim either -- every artefact here is a file or the
compositor's own readback, both exact, and x61/z10 already own the photographs.

| gate | clause | what it proves |
| --- | --- | --- |
| `x65_profile_roundtrip` | 13.9, Phase 12 item 1 | a bulk apply across THREE backends (a compositor option, a plugin key, ii's config.json), then revert -- graded on the md5 of all thirteen files in the surface AND on the live system. A named profile applied over a changed surface restores it. And an apply killed with `os._exit` after one write is undone by `hdprof check`, which the launcher runs before the window is drawn -- with a measured four seconds of nothing happening first, so "nobody else put it back" is watched rather than assumed. |
| `x66_theme_import` | Phase 12 item 2 | dockward.conf maps to exactly the nine schema keys the gate predicts, with the values the file asks for, and `decoration:blur:enabled` is REFUSED because the schema locks it. awkward.conf's six leftovers land in the raw block byte-identical to the fixture's own lines (compared against the file by line number, indentation included), the `]]` payload does not close the Lua long string, both blocks coexist because an import appends, and `luac -p` accepts the result. One `hdprof revert` undoes the last import and leaves the first standing. |
| `x67_wallpaper_repos` | Phase 12 item 3 | a real git clone over `file://`, a third wallpaper pushed upstream and pulled down, the active repository switched through its schema row, and the repo removed from the list and from disk. Two swaps through the pane's write path with z10's arms: matugen's primary moves, systemd starts theme-sync on its own, and the derived `col_highlight` follows. The slideshow declines a tick inside its interval and lands on the wallpaper the GATE computed for the one past it. An mp4 is drawn by mpvpaper with the palette taken from a frame, and choosing a still stops it. |

### Fail-on-old, and one mutation each

Absence is the cheap half and it is on record (`zrig/phase12/failonold/`): all
three exit 1 on `adbe081` with a preflight that names the missing script. The
half that means something is a mutation of the mechanism each gate exists to
guard, run on HEAD:

| mutation | gate | what it caught |
| --- | --- | --- |
| the verbatim long-bracket level stops escaping (`[[` always) | x66 | `luac: 40-hyprland.lua:48: syntax error near 'long'` -- plus the missing `]]` line and the values that never landed, because the fragment that carries them no longer parses. Three independent failures for one bug. |
| ii's `config.json` dropped out of the config surface | x65 | "ii's value came back as 0, not 2", one file different in the md5 manifest, and both later phases red. The surface question is decided by the gate, not by the docstring. |
| the pane's swap goes palette-neutral (`THEME=0`) | x67 | theme-sync never ran, systemd never started it, the palette did not move and the derived accent did not follow -- the whole Phase 10 chain reported as broken, which is what a swap that quietly stopped re-theming would look like. |

### What x67 does with the wallpaper

It moves it, on purpose, and its EXIT trap puts the picture AND the palette back
with `THEME=1 WALL=$WALL0`. z10 is the only other gate that does this. Both must
keep doing it: every frame-diffing gate in the suite depends on the wallpaper
being where `pinwall.sh` left it.

### What is NOT claimed

The verbatim lines an import keeps are **inert**. This session's config is Lua,
the fragments are Lua files, and 0.56 exposes no `hl.keyword` and no `hl.source`
to hand a hyprlang line to -- checked against `/usr/share/hypr/stubs/hl.meta.lua`.
So x66 proves the lines are kept exactly, that they are visible in the raw
editor, and that they cannot break the config; it does not prove a `bind =` line
does anything, because it does not. Translating them would mean a
hyprlang-to-dispatcher table, which is the parser this phase was asked not to
write.
