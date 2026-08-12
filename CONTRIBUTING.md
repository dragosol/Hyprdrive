# Contributing to Hyprdrive

This is a compositor plugin. A mistake here does not throw an exception, it
takes the user's session down mid-sentence, so the rules below are not style
preferences — every one of them is a bug that already happened.

## Build

```bash
make all
```

- `all` is the build **and** `scripts/symcheck.sh`. It must end with
  `symcheck: OK -- every undefined symbol has a provider (~558 checked)`.
  A `-shared` link never complains about an undefined symbol and `dlopen` binds
  lazily, so a missing symbol is a time bomb that goes off at the first call
  that reaches it — once, that was a mid-close tile ease, minutes after login,
  with no crash report because `ld.so`'s error path is `_exit(127)`. Never ship
  a build whose symcheck failed.
- **`rm -f scrolloverview.so` before `make` while the compositor has it mapped.**
  The link otherwise truncates the inode that is currently loaded.
- After any unclean stop — power loss, a paused VM, a full disk — run
  `find .build -size 0 -delete` before trusting a build. Truncated objects keep
  fresh timestamps, so `make` skips them and the link happily consumes them.
- `-O2` is the shipped artifact and what every pixel gate grades. `OPT=-O0` for
  a debugging session, never for a measurement.

## Gates

`scripts/gates/<name>/run.sh` runs one; `scripts/suite.sh` runs the table and
exits nonzero on red. `scripts/MANIFEST.md` maps each gate to the clause it
defends — update it whenever you add or change one.

The suite has a known red baseline. A change is clean when it moves **zero**
gates, in either direction: a red turning green without you intending it means
you changed observed behaviour and did not notice.

### Pixel doctrine

A screenshot is evidence only with its controls. Non-negotiable:

- Control frames on **both** sides of the measured one. Two identical frames are
  an explicit FAIL, not a pass — a frozen output hands back the same picture
  forever, and "nothing changed" then means nothing.
- Dilate the noise mask; measure the **largest connected blob**, never a
  bounding box and never a raw pixel count. A bbox spans the whole panel as soon
  as two far-apart pixels move.
- A new or changed gate must FAIL on the old build before its pass means
  anything.
- Film motion with `wf-recorder`. A one-shot `grim` on an output nobody is
  watching returns a stale frame.
- Hold the wallpaper rotation for the whole run, not per phase. Starting the
  timer is itself a rotation trigger, so a per-phase resume changes the
  wallpaper under the next phase — measured, and it cost a whole A/B pass.
- Fixtures are **kitty**, never foot: an opaque application defeats compositor
  blur and makes every frost measurement ambiguous.

### When gates cannot see it

Some behaviour has no green gate — drag and drop is the standing example. Then
the evidence is an A/B against the parent commit:

1. Instrument both builds with the same dump (temporary, never committed).
2. Drive the **same** script on both. Coordinates are measured once and reused;
   a per-run measurement lets the two builds be driven differently, which is the
   one thing an A/B may not do.
3. Run each build **twice**. The same-build pair is the noise floor; a
   cross-build residual only means something below it.
4. Report the numbers, not the verdict.

`scripts/p8_ab.sh` + `scripts/p8_diff.py` are a worked example, and
`scripts/drop_table_test.cpp` is the other half of the same idea: pull the
decision out as a pure function and check it exhaustively off the compositor.

## Changing behaviour-preserving code

Refactors here have a specific failure mode. One previous extraction had every
moved function verified byte-identical and still regressed a gate, because
grouping the mutations together moved them relative to the draws between them.

So: **pure code motion and grouping, yes; execution-order changes, no.** If a
decomposition would force a mutation to happen before or after a draw it
previously followed, take the smaller decomposition and say so in the commit.
The same applies to reads that sit inside short-circuited conditions — a
refactor that quietly starts calling `layoutTarget()` on windows the old code
never asked about is not a refactor.

## Configuration keys

`docs/CONFIG.md` is generated. Add the key to `Config.cpp`, then:

```bash
scripts/gen_keys_table.sh          # rewrite docs/CONFIG.md
scripts/gen_keys_table.sh --check  # fails if it is stale
```

The hand-maintained table this fork inherited had two wrong defaults and covered
six of seventy-nine keys. Do not reintroduce one.

## Commits

- Small, one coherent change each.
- The message explains **why**, names what was measured, and names the evidence.
  "Fixes the drag" is not a commit message; "the proxy box is the
  mission-control slot, so descaling it by the overview scale alone commits a
  shrunken window" is.
- Deviations, scope-downs and things you deliberately did not do belong in the
  message. A decision that is not written down gets re-litigated.
- **No AI attribution anywhere** — not in commits, not in code, not in docs. No
  `Co-Authored-By`, no "generated with".
- Code comments and commit messages use `--` rather than an em dash. That is the
  existing convention throughout the source, and it survives a terminal.
