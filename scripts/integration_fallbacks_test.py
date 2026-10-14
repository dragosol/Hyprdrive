#!/usr/bin/env python3
"""The Omarchy-or-not rule's two OTHER fallbacks, against the shell CLI.

integration_test.cpp holds IntegrationRule.hpp and scripts/hyprdrive-integration
to each other. Two more copies of the auto half exist for code that runs with
neither the plugin nor the CLI: 00-plugin.lua's hyprdrive_integration() (a
config parse before the .so is loaded) and hdpanel's integration() (the
marketplace panel, which ships without the CLI). This runs all three over every
combination of the auto signals -- `omarchy` on PATH, ~/.local/share/omarchy/
bin/omarchy, $OMARCHY_PATH, the state dir -- in a scrubbed environment and
requires the same answer. Part of `make check`; skips the Lua half when no
`lua` interpreter is installed.
"""
import itertools
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
LUA = shutil.which("lua") or shutil.which("luajit")
fails = 0
cases = 0

tmp = pathlib.Path(tempfile.mkdtemp(prefix="hd-intfb-"))
try:
    (tmp / "bin").mkdir()
    (tmp / "empty").mkdir()
    (tmp / "state/omarchy/current").mkdir(parents=True)
    (tmp / "nostate").mkdir()
    (tmp / "nohome").mkdir()
    (tmp / "run").mkdir(mode=0o700)
    inst = tmp / "home/.local/share/omarchy/bin"
    inst.mkdir(parents=True)
    for d in (tmp / "bin", inst):
        (d / "omarchy").write_text("#!/bin/sh\n")
        (d / "omarchy").chmod(0o755)

    for path, installed, openv, state in itertools.product((False, True), repeat=4):
        env = {
            "HOME": str(tmp / ("home" if installed else "nohome")),
            "PATH": str(tmp / ("bin" if path else "empty")),
            "XDG_STATE_HOME": str(tmp / ("state" if state else "nostate")),
            "XDG_RUNTIME_DIR": str(tmp / "run"),  # no compositor for hdpanel to find
        }
        if openv:
            env["OMARCHY_PATH"] = str(tmp / "home/.local/share/omarchy")
        label = "path=%d installed=%d OMARCHY_PATH=%d state=%d" % (path, installed, openv, state)

        want = subprocess.run(["/bin/sh", str(ROOT / "scripts/hyprdrive-integration"), "--offline"],
                              env=env, capture_output=True, text=True).stdout.strip()
        got = {}
        if LUA:
            got["lua"] = subprocess.run(
                [LUA, "-e", "hl = {}", "-e", "dofile(%r)" % str(ROOT / "config/hyprdrive/00-plugin.lua"),
                 "-e", "io.write(hyprdrive_integration())"],
                env=env, capture_output=True, text=True).stdout.strip()
        got["hdpanel"] = subprocess.run(
            [sys.executable, "-c",
             "import sys; from importlib.machinery import SourceFileLoader as L;"
             "m = L('hdpanel', sys.argv[1]).load_module(); print(m.integration())",
             str(ROOT / "omarchy-plugin/bin/hdpanel")],
            env=env, capture_output=True, text=True).stdout.strip()
        # The rule's own expectation, independent of all three: any install
        # signal AND the state dir.
        expect = "omarchy" if (path or installed or openv) and state else "none"
        for who, ans in [("sh", want)] + sorted(got.items()):
            cases += 1
            if ans != expect:
                fails += 1
                print("FAIL %-8s %s: %r, want %r" % (who, label, ans, expect))
finally:
    shutil.rmtree(tmp, ignore_errors=True)

print("integration fallbacks: %d answers checked (sh, hdpanel%s), %d failed" % (cases, ", lua" if LUA else "; NO lua, skipped", fails))
sys.exit(1 if fails else 0)
