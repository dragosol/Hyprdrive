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
| `x48_results_band` | search | 13.12 **X60** (supersedes X48's placement + DoD 23): ORDER the selected result row sits ABOVE the tile block; YIELDS the band's height comes out of the tile grid; ONSCREEN the tile foot stays clear of the dock (X48's surviving constraint). Fail-on-mutant: pre-X60 bottom layout, a grid that does not yield, tiles under the dock | ~1.5 min |
| `x50_pill_docks` | search | 13.12 X50: search bar animates up when results appear — DOCK (pill appears under the work-area top edge, vanishes from rest), NOMATCH negative control (pill wid | ~2 min |
| `x51_text_cache` | open-overview | X51: text served from the surviving glyph cache is PIXEL-IDENTICAL to text rendered fresh (A cold after compositor restart == B cached after 4 open/close laps), | ~1 min + one compositor restart |
| `x53_compat_alias` | config | Phase 9 rename compat: A a value set under `plugin:scrolloverview:` is readable under `plugin:hyprdrive:` (through a real fragment + `hyprctl reload`, bracketed by a negative control and a restore); B a dispatch through the old `hl.plugin.scrolloverview.*` namespace reaches the same handler, asserted as STATE (special:minimized), not pixels; C exactly ONE deprecation warning for the whole session however many old names were used. The one gate that deliberately does NOT route the old name through `$RIG_NS`. Fails at its first step on any pre-rename build (zrig/phase9/x53-on-parent.log) | ~1 min |
| `y11_crossdesk_preview` | dock-hover | 13.14 Y11 (the regression gate on X99): a non-active-desktop dock preview is NON-BLANK (fixture magenta count in the panel band) and LIVE (changed pixels betwee | ~2 min |
| `y12_stash_slot_once` | search | Y12 (user report 2026-08-17, the phantom/misplaced tile): a window minimized FROM the desktop you are looking at owns ONE grid slot, not two. `overviewGridPromotable` and `overviewGridSlot` read the raw `m_workspace`, which for a stashed window is `special:minimized` and can never equal the active workspace, so such a window answered "I live somewhere else" and joined the active grid a second time under B2; the layout then solved for N+1, picked two rows and left one empty. Graded as GEOMETRY against a control of the same two windows with nothing stashed, captured on BOTH sides of three stashed laps: one connected blob per fixture, and the tile block's centre where the control put it. Fail-on-parent measured at 264 px of block drift against a 16 px tolerance; passes at 2 px (zrig/fire-phantom2/) | ~2.5 min |
| `y4_click_semantics` | dock-click | 13.14 Y4: plain dock click minimizes ALL of an app's windows, second click restores all, CTRL+click cycles (never stashes) — STATE via special:minimized, not pi | ~2 min |
| `y7_drag_glow` | drag-strip | 13.14 Y7: dock glow intensity correlated to drag distance within the bottom-30% band — OFF above the band, CONTINUOUS (rungs rise in steps, none is the whole ri | ~1.5 min |
| `y8_bounce_once` | drag-strip | 13.14 Y8: on drop-to-minimize the landing icon hops ONCE, macOS-like, 'not a decaying bounce train' — IT HAPPENS / ONE PEAK (no second hump above a third of the first) / IT SETTLES. The fixture is spawned as `kitty` because the hop moves the ICON and a class with no desktop entry has no icon to move; the gate asserts that before it drags. | ~2-3 min |
| `y9_filter_reveal` | search | Y9 as revised 2026-08-06: minimized windows show in the overview ONLY when a query matches — q0 no-query magenta ABSENT, q1 'MAGWIN' magenta PRESENT, q2 cleared | ~1.5 min |
| `z1_preview_survives_swaps` | dock-hover | Z1 (user report 2026-08-07): move window to another desktop, hover its dock preview, swap desktops back and forth — preview must still draw (h0 before swaps ==  | ~1.5 min |
| `z2_preview_click_goto` | dock-click | Z2 (user report 2026-08-07): clicking the dock preview goes to that window — view lands on its desktop AND it is focused; control click at the same height but o | ~1 min |
| `z3_position_memory` | drag-strip | Z3 (user report 2026-08-07): strip moves after the first must still remember coordinates — G1 main tile -> off-screen desktop mini (always worked, keep), G2 str | ~3 min |
| `z10_theme_adopt` | config | Phase 10 theme adoption, end to end: a wallpaper swap through the rice's own rotation script (`THEME=1`) must repaint the dock pill AND the overview strip ring with no compositor restart and nobody typing anything — asserted by requiring the systemd path unit to have fired (service InvocationID changes, theme-sync's log grows) rather than by the gate not calling it. Two-sided in one run: P1 inherits (dock delta 14.54 over a backdrop control of 0.00, cos 1.000 against the move the palette predicts; ring 1311 -> 0 old, 0 -> 1310 new), P2 pins the dock's accent keys in a later-sorting fragment (dock delta 0.00 while the overview still repaints). Red two ways on the old world and they fail differently: with nothing installed the overview arms pass on Hyprland's own config-file auto-reload and the dock arms sit at 0.00 (`zrig/phase10/z10-on-parent.log`); with the derived fragment present and the sync off, BOTH accents freeze (`z10-stale-pin.log`) | ~4 min |
| `zflight_z4_z7` | minimize-restore | z4: no hole at restore landing (green area never dips below 25% of steady after first exceeding 50%); z4t: tiled window's restore flies to its tile, not the sta | ~3-4 min for all seven arms |

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
- `z20_repro.sh` — Z20, "invisible tile after in-overview restore": minimize a window while the overview is up, restore it while it is still up, and assert the tile is DRAWN in its cell and that clicking that cell activates it. The cell is derived from the other window, because a locator that hunts an invisible tile cannot find it and has nothing to click. Exit 0 = does not reproduce.
- `monitor_gone_variants.sh` — The four states the repro does not cover: the output removed while the overview is still ANIMATING open, while a search query is up, and while a dock MINIMIZE and a dock RESTORE flight are in the air. Each variant carries its own positive control (the search proves itself with a frame diff across the keystrokes; a flight proves itself by the stash, and a restore flight by the window being hidden) so a variant cannot pass by never reaching the state it names. Exit 0 = every variant survived and landed sanely, 2 = a scene could not be set up. Run over ssh.
- `p8_ab.sh` + `p8_diff.py` — Phase-8 drag A/B: four drags (within a card, onto another desktop's strip cell, a near miss above the dock pill, onto it), each captured as frames + every window's geometry + the drop dump, then graded parent-vs-child against a same-build noise floor. Coordinates are measured ONCE and reused by every run of both builds; the wallpaper rotation is held for the whole A/B, not per run (a per-run resume rotates it under the next pass and every frame diff then measures the wallpaper -- 1.5M px of it). Needs the temporary instrumentation described in the script header; that patch is deliberately not committed.
- `drop_table_test.cpp` — Exhaustive host-side table test for `ScrollOverview::Drop::resolve()`: 16 boolean facts, all 65536 combinations, against the pre-split branch ladder transliterated from a4189e2. Needs no compositor and no Hyprland headers. `g++ -std=c++2b -O2 -o /tmp/drop_table_test scripts/drop_table_test.cpp && /tmp/drop_table_test`.
- `geometry_test.cpp` — Host-side unit test for `ScrollOverview::Geometry`, the overview's pure transforms: 94 checks over the getOverviewBox family, the hit-test expansion, the box predicates, the resize clamps and the interpolators. Needs no compositor and no display; `make check` runs it through `scripts/host_tests.sh`. GOLDENs are hand-computed answers, PROPERTYs are the algebraic identities (offset is a translation, the viewport centre is the scale's fixed point, a resize holds the opposite corner). Six mutations of OverviewGeometry.cpp were checked to kill it (zrig/danglingC2/geometry-mutants.log).
- `host_tests.sh` — Builds and runs every test that needs no compositor (drop_table_test, geometry_test) and is wired into `make check`, because a host test nobody runs is a comment with a build cost.
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
- `x1_probe.sh` — 'does a query actually reach the overview's filter', X1's three-frame falsifiability control; that liveness check lives inside the gates now
- `x1_dragprobe.sh` — hunts a grab point and strip target that actually move a window, so X1's drag phase could not silently no-op; superseded by x1_fixture.sh + the rig's warp
- `x1_dropsweep.sh` — empirical sweep of candidate X positions for a committing strip-cell drop; same X1 coordinate-discovery fire
- `x1_tilebox.sh` — captures the overview at rest so the HOST could measure a tile box; host/guest split-brain era
- `x1_tilebox.py` — the host-side measurement for it (connected component, not bbox); its lessons were re-implemented in x43_tilebox.py, which cites it
- `p7_ab.sh` — Phase-7 search A/B across five settled states; needs an instrumentation patch its own header says was deliberately never committed
- `p7_func.sh` — Phase-7 behavioural check (session reset + keyboard/pointer hit lists end to end); x28 and y4 own that coverage now
- `p8_smoke.sh` — Phase-8 filmed drag smoke, the three drags a human would try after endWindowDrag changed; drop_table_test.cpp now covers the logic exhaustively on every `make check`
- `x24_flight_run.sh` — X24 flight driven from the HOST over ~/hyprvm/g; `gates/x24/run.sh` says in as many words that it ports this driver's orchestration
- `x26_run.sh` — X26 end to end from the HOST; `gates/x26/run.sh` is the port, and this hardcodes host paths
- `z3_run.sh` — Z3 driver that ran on the HOST, three gestures in one overview session; `gates/z3_position_memory/run.sh` is the port
- `z3_view.sh` — puts the overview's main card on a workspace and photographs it so the host could locate the next drag target; orphaned with z3_run.sh

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

## Harness follow-ups (2026-08-11, after the gate fire) -- ALL FOUR CLOSED

Kept with what closed each one rather than deleted: the next four will look
like these, and the shape is the lesson.

1. **CLOSED b308bb7, and again 306e67f.** `g1_gate.py` diffed whole frames
   against an absolute 400 px floor, no mask and no blob, on a desktop that is
   not still -- its own "no drift between two idle frames" control measured
   2849 px on frames it then graded, so the verdict was decided by whether a
   clock edge fell in the window. It masks now: every non-fullscreen layer
   surface out of `hyprctl layers -j` (the rig dumps it beside the frames),
   plus a PINNED box for the ii desktop clock, which is drawn inside the
   fullscreen background layer and therefore cannot come from layers.json. Then
   dilate, then the largest 4-connected blob. QUIET 25000 / LOUD 50000, both set
   outside the measured noise rather than beside it, and the hand-written box is
   leashed at 1.5% of the frame.
   306e67f is the SAME defect in the compose arm: `g1c_grade.py` had been
   written by transcribing the old scheme, and it applied it to the pair where
   the clock is most exposed -- two desktop frames ~10 s apart with nothing over
   the widget, measured at 7911 px. Both arms call one `g1_gate.grade()` now,
   because a doctrine kept in two copies drifts back apart, which is exactly
   what happened here.
2. **CLOSED f8e810a.** `g1_rig.sh` and `x48_rig.sh` hand-rolled their headless
   output and never set its mode, so g1/g5/x48/x50 ran at the headless default
   1920x1080 while every cell predictor assumes 2560x1600. They set the mode
   explicitly (and verify it) where they create the output; `headless_on` still
   cannot be used there because its EXIT trap would tear the output down when
   the fixture script exits.
3. **CLOSED 06dcd36 + b5cdf62.** `gate_slate` snapshots and restores all
   seventy-nine registered plugin keys, not the eight it knew about. The
   baseline is a snapshot of the SESSION'S own values, not Config.cpp defaults
   -- this rice configures the plugin, and forcing defaults would re-theme the
   session between gates. Only the keys that DRIFTED are written back:
   `getoption` reports `set: true` for anything ever assigned, and
   x53_compat_alias's A control requires its probe keys to be UNSET, so a slate
   that assigned all seventy-nine turned that control red on a clean build.
4. **CLOSED 0aafce5.** `z3_position_memory`'s G1 takes its two strip minis from
   the STRIP BAND, as G2 and G3 already did, and only the main tile from the
   whole frame. Its yellow mask is broad and there is a photograph behind the
   overview; on wp03 the largest yellow blob was the wallpaper.

## Harness follow-ups (2026-08-12, dangling-A2)

1. **A GATE CAN BE BROKEN BY THE PASSAGE OF TIME.** `x66_theme_import` P3 asked
   "was a snapshot committed across these two imports?" by counting
   `hdprof list -n 50 --json` before and after. That list is CAPPED at fifty.
   The guest's snapshot history passed fifty at 18:06 on 2026-08-12 and both
   reads answered 50 from then on, so the check could never pass again whatever
   the importer did -- no build changed, no harness commit touched it. FIXED
   6b83374 with a ref that has to MOVE. **Anything that asks "how many" of a
   paginated list is this bug**; nothing else in scripts/ currently does.
2. **TWO CLOCKS, NOT ONE.** `x51_text_cache` was still a straddler after its bar
   mask went in, because the ii DESKTOP clock shows through the overview's
   wallpaper backdrop and `layers.json` cannot describe it -- it is inside the
   fullscreen background layer. A and B are ~25 s apart, so a minute boundary
   falls between them about forty percent of the time; measured on the failing
   run's own frames, A read 18:38 and B read 18:39, 1675 px, none of it where
   the plugin draws. FIXED 65ecb93. Any new whole-output gate needs BOTH masks.
3. **Kitty fixture opacity: measured, and deliberately NOT changed.** Every
   fixture is composited at the rice's 0.92 window opacity (custom/rules.lua:40,
   `class = ".*"`), which `kitty -o background_opacity=1.0` does not defeat.
   Measured, the bleed is a ~10% shift toward the wallpaper and spatially FLAT
   (sd 0.5/255), it cancels in every A/B because the wallpaper is held, and
   pinwall's wp17 is greyscale so it cannot fake a colour-locator hit. No red
   traces to it and x47's TEXTURE would get WORSE with opaque fixtures, since
   its complaint is too little structure behind the plate.
   `zrig/danglingA2/kitty-opacity-finding.md`.
4. **Z20 has a repro at last** and it does not reproduce: `scripts/z20_repro.sh`
   (9c33db1), three consecutive clean runs. See the repro list above.

## Guest gate dependencies + known flakes (2026-08-09)

- The film gates (z4/z4t/z5) need `ffmpeg` in the guest; the pixel graders need
  `python3-pillow` + `python3-numpy`. Install once per guest.
- `zflight_z4_z7 :: z5` grades the film with the DOCK'S OWN LIVE PREVIEW of the
  fixture excluded. A minimized window is drawn in the pill (X25), and on this
  fixture that preview is 212x132 = 27952px of fixture green -- nearly twice the
  15000px floor that was meant to keep dock-sized blobs out. Measured on 3d5281c
  (`zrig/danglingB/z5/z5-controls.log`): when the flying proxy fades at frame
  111 the crown passes to that still preview and the two centres are 924px
  apart, which is the "teleport" this arm reported for a week. Excluding it
  takes the worst jump to 209px, the restore flight's own expo step. The
  rectangle is measured off the film's still tail, not predicted, and the arm
  refuses to grade a film whose tail is not still. Same class of fault as
  x24's hover-panel read (f7fe954): one green fixture, several dock surfaces
  showing it.
- `zflight_z4_z7 :: z5log` is the seventh arm and rides on the z5 run: the same
  clicks graded through the plugin's own drawn-box log, which is the only
  instrument that can separate a 400ms EASE_OUT_EXPO from a teleport at 30fps.
  It existed in `zflight_gate.py` and nothing had ever called it. `z_rig.sh`
  truncates `/tmp/ovdbg.log` at the top of the z5 arm (zdbg APPENDS, and every
  earlier arm runs with `flight_log=true`), and the log is kept beside the film
  as `z5-flight.log`. Both arms carry mutation controls in
  `zrig/danglingB/z5/z5-controls.log`: a same-size 700px displacement in one
  film frame FAILs the pixel arm (650px), and a first-draw-after-a-reversal
  moved 200px behind the old flight's last box FAILs the log arm (+200.0px).
- `zflight_z4_z7 :: z4c` is flaky at its precondition ("minimize 1 missed" --
  the first click misses the predicted dock cell; ~1 in 3 standalone runs is
  clean, and when it runs the geometry is invariant). Rig-hardening follow-up
  (sweep + settle harder before the first click), not a product defect.

## y8 was photographing an empty square (2026-08-12, fixed)

Three rounds of "the pill never moved" -- peaks 43, 20 and finally 0 px against
a 300 px floor -- and none of them was about the bounce. The hop moves the
ICON's draw box and only that (Dock.cpp:3284; the running dot and the badge stay
put on purpose, which is what macOS does), and the dock draws an icon only for a
class AppSearch can resolve to a desktop entry. The fixture was
`kitty --class MARK`; nothing on this guest claims MARK, so its dock cell was an
empty square with a running dot under it. There was no moving part in frame.

Two fixes, both in the rig:

- the fixture is spawned as `kitty` (`Z3_MARK_CLASS`, default still MARK for
  z3's own callers), which resolves through kitty.desktop -- and the gate now
  asserts that its class owns an icon before it drags, naming the fixture rather
  than the plugin when it does not (`y8_icon_check.py`, mirroring
  AppSearch::entryIndexForClass);
- the camera starts AT the release. Z10 arms the hop at the drop, not at the
  landing, so the drop-committed check that used to run first -- 1.2 s plus an
  hyprctl round trip, against a 3.4 s hop at anim_scale 8 -- opened the shutter
  just after the peak. It is asserted after the burst instead.

CALIBRATION, and the floor turns out to have been right all along. Two arms, one
camera, one band, three runs each (`zrig/danglingB2/y8/arms.log`):

    DROP (flight + hop)          peak 1903, 1903, 1903   one hump, settles to 0
    dispatcher minimize (no hop) peak   47,   55,   51

The dispatcher arm takes `minimizeWithFlight`'s default `bounceOnLand=false`, so
it is the same window, the same flight and the same landing with the hop
removed: whatever the two arms share is not the bounce, and they share almost
nothing. The 300 px floor sits 5.5x above the no-bounce readings and 6.3x below
the hop's, in a 38x gap, so it stays. The magnitude corroborates the constants
independently: BOUNCE_HEIGHT 0.34 of a 54 px icon is an 18 px lift, and an 18 px
lift of a 54 px icon is ~1944 changed px.

The ONE PEAK half is proven on a mutant film -- the same hop replayed at half
height 14 frames later -- which the gate reports as "2 humps" and fails.

## Two gates were graded on the wallpaper, and one of them still is (2026-08-12)

The hold was fixed below; PINNING was not. A hold freezes the rotation, it does
not choose what it freezes -- and the rotation had already put a photograph up:
the pair of 2026-08-12 ran on wp06 because the timer's last firing before it
(19:35:53, suites 19:41-20:55, zero rotations between) had left wp06 there, and
nothing ran `pinwall.sh`. The pair came back **5 red and 7 red on one build**
(`zrig/danglingB/suites/`), and neither extra red was a build difference:

- `x64`'s frost half compared the patch's high-frequency energy against the
  wallpaper's own and required it under 60%. That ratio is a measurement of how
  much APP TEXT is in the patch relative to how detailed the picture is. Measured
  minutes apart on one build: wp17 (detail 9.3) 28% PASS, wp06 (detail 2.7-3.6)
  72-95% FAIL -- and a synthetic 45%-alpha UNBLURRED overlay reads 0.45 and would
  have PASSED. It now correlates the wallpaper's own structure with what shows
  through: fine detail must be gone (< 0.25, measured 0.002-0.006) and the
  backdrop's shape must still be there (> 0.20, measured 0.37-0.52). Wallpaper
  contrast cancels, so the gate no longer cares which picture is up: measured
  green on wp17, wp02 and wp06.
- `x26`'s P3b hunts fixture green with `G>150 and R,B<110`, which is also a
  description of foliage. On wp02 the wallpaper -- drawn UNBLURRED behind the
  overview by design -- puts 7072 pixels into that mask, and P3b called the
  largest 16x20 of them "the released window is still up", three runs out of
  three. The mask now also requires the green to stand 120 above the larger of
  its own red and blue: fixture 141-142, wallpaper 42-90, accent 53.

Neither was session wear, which was the first hypothesis: six consecutive runs
of both gates in a session already 5.5 hours old and two suites deep drift
nowhere (`zrig/danglingB2/wear/wear.log`), and x64's one red there was the FIRST
run of the sequence, not the last.

`suite.sh` now runs `pinwall.sh` itself and prints the wallpaper it started and
ended on, so a pair that ran on two pictures says so in its own table.

Two commits in this round (`812d2e9`, and a line in `0cfe09d`) blamed the drift
on `z10_theme_adopt` leaving its wallpaper behind. That is wrong and is corrected
here: z10 moves the wallpaper on purpose and puts it back, palette included, in
its EXIT trap (`z10_restore`, `THEME=1 WALL="$WALL0"`), and both converged suites
end on the picture they started on. The pair was simply never pinned.

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
| `x64_app_obeys_laws` | user law: frost, Apple motion | the app's own surface: the wallpaper's FINE detail is gone behind it and its SHAPE is not (high-frequency correlation < 0.25, low-frequency > 0.20 -- frosted, rather than either translucent or painted over); its open and close are filmed and the open decelerates, the close accelerates, and the exit is not longer. |

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
not happen. The measured ratio is reported, and graded only against a floor BELOW the
measured noise. Seven runs of one build on one wallpaper gave 0.001, 0.310,
0.353, 0.357, 0.402, 0.413 and 0.500 -- a 0.5-wide band on an unchanging app,
because the open film also carries Hyprland's own window animation. The old
floor of 0.02 sat inside that band and reddened the first x64 of a session about
one run in seven, which is the position a suite runs it in. It is -0.15 now,
which still catches an exit LONGER than the entrance and leaves the 20-30% claim
where it can be measured: on the constants the app runs.

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

## Campaign close-out (2026-08-14) — what is CLOSED and what is OPEN by design

This is the end of the refactor/feature campaign. Everything below is either
finished or deliberately not finished; there is no third category and nothing is
waiting on somebody to remember it.

### A word on what "converged" means

Two consecutive suites are compared on their **VERDICT TABLE, stripped of
timings** — gate name and PASS/FAIL/SKIP/DIED, nothing else. They are never
byte-identical and it would be a bad sign if they were: every gate prints its
own duration, and the same gate legitimately varies by seconds between runs on
the same build. A claim of "byte-identical runs" in any report is either wrong
or was made about the stripped table; say **verdict-identical** and there is
nothing to misread.

### CLOSED

1. **P6i1, the membership snapshot — CUT OVER.** The gate is split by cost.
   `isHidden`, `validMapped` and the pinned+floating pair are re-read on every
   call, forever: they are four bool reads, and they are the properties that
   change with no event to announce it. The expensive half — the search match
   and the minimize-stash scan — is cached against a generation that every
   mutator bumps. Round one shadowed the WHOLE gate and found 15 divergences,
   all of them `validMapped` flipping between `window.close` and
   `window.destroy`; splitting by cost removed exactly those and nothing else.
   Evidence: `zrig/final/`, and the finding it closes is
   `zrig/danglingC2/p6i1-shadow-finding.md`.
2. **The shadow does not ship hot.** It was running unconditionally inside the
   render path — ~192k calls per suite, with a synchronous `fopen`/`fprintf`/
   `fclose` on the compositor thread for every divergence. It is now behind
   `HYPRDRIVE_MEMBERSHIP_SHADOW`, read once, branched on at the CALL SITE, so
   with it off `Membership::observe` is not called at all. Same shape as
   `Prof::enabled()`. Turn it on to re-run the verification; it costs nothing
   when off.
3. **The dock's frame pump could latch off.** `g_pumpPending` was set false by
   the `doLater` it queued, and a `doLater` queued against an output that is
   then removed never runs — leaving that monitor's mark true forever and its
   dock silently unable to request another frame. The mark is erased by the
   callback now, and `Dock::forgetMonitor()` drops all three per-monitor maps
   from the `monitor.removed` handler, beside `Flight::abortAll`.
4. **Dead code and stale instruments** — see the Attic list above for the twelve
   one-off probes that moved there, and the commit for the ~120 lines of
   unreachable plugin code that went with them.
5. **x47's frost fixture owns its backdrop.** It was the campaign's last
   blocker. The gate measured whatever was behind the hover plate, and that was
   the scene the PREVIOUS gate left: the same build gave a backdrop step of
   216.5/255 inside a suite and 13.0 in a standalone re-run twenty minutes
   later. Both changes are FIXTURE, the grader is untouched.
   * The frost pair is captured with the **overview CLOSED**. `x47_rig.sh` said
     "the dock is drawn by the overview pass, so there is no dock to hover with
     the overview closed"; X27 moved the dock to `RENDER_POST_WINDOWS` and that
     comment went stale. Probed: hovering with the overview closed raises the
     plate perfectly well, 120095 px over the plate rect. It also HAS to be
     closed — with the overview open the plate sits on the flat workspace-card
     background, profile sd 0.9 and a step of 4.0, i.e. nothing to blur.
   * **`X47Z`**, one extra kitty, solid white, placed with its bottom edge 30
     rows into the plate: white above, the compositor's dark background below,
     one hard step across the whole plate width — the shape the grader already
     looks for. It is wider than the plate by 200px each side so its rounded
     corners and border miss every sampled column, it is static so SAMEBACK
     stays exact, and it goes up AFTER every behaviour capture so
     RISES/LIVE/FOLLOWS/GRACE see the scene they always saw. The predictions are
     re-read once it is mapped, because a fourth class shifts every icon centre.
   Acceptance, three consecutive runs from a COLD session (fresh compositor
   each): step **166.3**/255 at row 26, profile sd **78.0**, EDGEFRAC 0.705 →
   0.050, correlation 0.996 / 0.817, RADIUS 17276 of 17290 — identical to the
   decimal in all three, with SELFTEST rejecting all five synthetic arms every
   time. The ticket asked for "the same TEXTURE numbers to within noise when run
   STANDALONE twice"; these are the same to the decimal, three times.
6. **`y8`'s wallpaper guard was grading energy, not structure.** It aborted the
   gate when frame 0 and frame -1 differed by more than 500,000 px — and y8's
   own subject is a 1100x700 window flying out of the frame, which is ~500k px
   by itself. Measured on the run that tripped it: **502,366 against a 500,000
   floor**, a straddler at 100.5% of its own threshold, red because the build
   got faster and the flight finished inside the capture window. It counts
   COLUMNS now: the real minimize touches 856 of 2560 (33%), a different
   wallpaper touches 2560 of 2560 (100%), and so does that rotation blended
   50%. Floor at 80%, nowhere near either. Proved both ways — the old guard
   aborts on the real frames, the new one passes them and still returns 2 on a
   frame pair whose last frame is a different wallpaper.

### OPEN, on purpose, with the reason

1. **P6i2 — `FramePacing.cpp`, and the `refreshWindows` deletion behind it.**
   Not a refactor that can be taken in isolation. `refreshWindows()` is
   `redrawAll()`, which rebuilds `workspaceImage->windows` — and the render
   walks THAT list, not the membership gate — so deleting its one caller
   (`CHiddenLease::release()`) before the render walks the snapshot puts Z20
   back. Order: cut over (done) → the render walks the snapshot → the call is
   the no-op the ticket assumes → delete. The two ~25-line verbatim twins in
   `scrollOverview.cpp` (`shouldAllowSurfaceFrame` /
   `shouldHandleSurfaceDamage`, and the `renderWorkspaceBackground` /
   `renderWorkspaceLive` heads) are the body of that module and are deliberately
   left duplicated until it exists: deduplicating them in place would make the
   extraction harder, not easier. Reasoning in
   `zrig/danglingC2/deferred-refactors-roundC.md`.
2. **P6i4 — the liveliness registry.** Already exists in substance (`g_previewed`
   with its 250ms TTL, consumed at one place through `Dock::isPreviewing`). The
   only unpaid clause is killing the core→dock query, and that cannot be bought
   by adding a registry — it dies when frame pacing moves out of the god object,
   i.e. with P6i2, which takes the registry with it. Same document.
3. **P8 — `SGesture` as a `std::variant`.** Worth doing; struck on verification
   cost, not on merit. The illegal state it would make unrepresentable (a drag
   and a resize owning one window) was already made unreachable at runtime by
   `bdef20c`. Its named method (`scripts/p8_ab.sh` + `p8_diff.py`) needs
   instrumentation the script's own header says is deliberately not committed,
   and grades four drags parent-vs-child against a same-build noise floor —
   about an hour of wall clock before the first line is written. **Next round:
   build it against `scripts/drop_table_test.cpp` first — 65536 combinations,
   free, and it runs on every `make check` — then `p8_ab.sh` for the pixels.**
4. **The lock-screen zoom asymmetry is unmeasured, and needs a password.**
   `modules/ii/lock/PasswordChars.qml` carries literal durations (50 / 200 /
   1000) that the motion audit never reached, because grading the lock screen
   means locking the session and unlocking it, and an automated run cannot type
   the user's password. Not routed to tokens with the rest for the same reason:
   an unverifiable edit to the one surface that can lock you out is a bad trade.
5. **The waffle panel family's 30 literal durations.** `Config.options.panelFamily`
   selects `ii` or `waffle`; this rice runs `ii`, so `modules/waffle/**` is not
   loaded and its thirty literals were left alone. If waffle is ever made the
   live family, audit them first — the numbers are 80/120/150/160/170/200/250/
   300/350/400/1000 and only some have equal-valued Appearance tokens.
6. **`AppSearch.cpp` and `SearchProviders.cpp` carry `#ifdef`-gated self-check
   `main()`s** (`APPSEARCH_TEST`, `SEARCHPROVIDERS_TEST`, ~320 lines together)
   that nothing defines, so they never compile and can rot unnoticed. They each
   carry a hand-build recipe and are deliberate dev tools; the fix if they are
   worth keeping is to wire them into `scripts/host_tests.sh` beside
   `drop_table_test` and `geometry_test`, not to delete them. Left as found.
7. **`OvGeom::expandHitbox` and `OvGeom::spanOverlap` now have no production
   caller** — their three wrappers in `OverviewInternal.hpp` were dead and were
   deleted. Both are kept: they are pure primitives of the geometry module with
   host-test coverage (`scripts/geometry_test.cpp`), which is exactly what the
   module is for, and P6i2's extraction is the caller most likely to want them.

### One trap this pass paid for, so the next one does not

**The duplicated `#include` lines in this tree are load-bearing.** Several files
include the same std headers twice, and an automated tidy will find them. They
are the `#define private public` idiom: the std headers are included CLEAN
first, so that claiming a private member only reaches the one Hyprland header
whose include guard is being claimed, and every later inclusion is a no-op. The
Z19 comment at the top of `Dock.cpp` says so. Deleting the first block appears
to work — it compiles — and quietly widens `private`-to-`public` over every
std header in the translation unit. Only `OverviewRender.cpp` and
`SearchProviders.cpp` have no such block, and those are the only files where an
unused include was actually removed.
