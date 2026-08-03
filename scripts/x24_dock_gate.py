#!/usr/bin/env python3
"""X24 dock-side gate. Judges pre/post `hyprctl clients` around one dock click.

Asserts STATE, not focus and not pixels. X43's lesson was that a test which
checks the wrong property passes forever while the reported bug stays broken;
the property the user reported here is "the icon click minimizes / restores",
and a minimized window is one parked on `special:minimized`.

usage: x24_dock_gate.py <expect> <class>
  expect = minimized-one | minimized-all | restored | nochange
"""
import json
import pathlib
import sys

OUT = pathlib.Path("/mnt/host/x24d")
STASH = "special:minimized"


def load(name):
    return {c["address"]: c for c in json.load(open(OUT / name))}


def stashed(clients, cls):
    return {a for a, c in clients.items() if c["class"] == cls and c["workspace"]["name"] == STASH}


def owned(clients, cls):
    return {a for a, c in clients.items() if c["class"] == cls}


def main():
    expect, cls = sys.argv[1], sys.argv[2]
    pre, post = load("pre-clients.json"), load("post-clients.json")
    pre_active = json.load(open(OUT / "pre-active.json")).get("address")
    post_active = json.load(open(OUT / "post-active.json")).get("address")

    all_pre, all_post = owned(pre, cls), owned(post, cls)
    min_pre, min_post = stashed(pre, cls), stashed(post, cls)

    print(f"class={cls} windows={len(all_pre)}->{len(all_post)} "
          f"minimized={len(min_pre)}->{len(min_post)}")
    print(f"active {pre_active} -> {post_active}")

    fails = []

    # No dock click may ever destroy a window. This catches a minimize that
    # unmaps instead of stashing, which would also silently break X25.
    if all_pre != all_post:
        fails.append(f"window set changed: lost {all_pre - all_post}, gained {all_post - all_pre}")

    if expect == "minimized-one":
        if len(min_post) - len(min_pre) != 1:
            fails.append(f"expected exactly 1 more minimized, got {len(min_post) - len(min_pre)}")
    elif expect == "minimized-all":
        if min_post != all_post:
            fails.append(f"expected every window minimized, {all_post - min_post} still out")
    elif expect == "restored":
        if min_post:
            fails.append(f"expected none minimized, {len(min_post)} still stashed")
        if not min_pre:
            fails.append("nothing was minimized beforehand -- the rig proved nothing")
        # Restore must put it back where it came from, not on the stash's monitor.
        for a in min_pre & all_post:
            if post[a]["workspace"]["name"] == STASH:
                fails.append(f"{a} never left the stash")
        if post_active not in all_post:
            fails.append(f"restored app did not take focus (active={post_active})")
    elif expect == "nochange":
        if min_post != min_pre:
            fails.append(f"minimized set changed: {min_pre} -> {min_post}")
        if pre_active != post_active:
            fails.append(f"click leaked through the pill and moved focus: {pre_active} -> {post_active}")
    else:
        sys.exit(f"unknown expectation {expect}")

    if fails:
        print("FAIL")
        for f in fails:
            print("  -", f)
        sys.exit(1)

    print("PASS")


main()
