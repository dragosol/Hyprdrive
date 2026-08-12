// Exhaustive table test for ScrollOverview::Drop::resolve().
//
// The drop resolution came out of endWindowDrag()'s 277 lines as a pure
// function precisely so it could be checked without a compositor: 16 boolean
// facts, 65536 combinations, no state, no I/O. `reference()` below is the
// SAME ladder transliterated from the pre-split source (a4189e2,
// scrollOverview.cpp:1919-2195) -- condition for condition, in the order the
// if/else chain evaluated them -- so a transcription slip in either copy shows
// up as a disagreeing row rather than as a drag that misbehaves once a month.
//
//   g++ -std=c++2b -O2 -o /tmp/drop_table_test scripts/drop_table_test.cpp && /tmp/drop_table_test
//
// Needs nothing from Hyprland; DropDecision.hpp includes nothing at all.

#include "../DropDecision.hpp"

#include <cstdio>
#include <string>

using namespace ScrollOverview::Drop;

// The parent's branch structure, written the way the parent wrote it. Names are
// the parent's locals: RETILEONEND, MOVEWORKSPACE, DROPSCROLLINGLAYOUT,
// DROPANCHOR, dropDirection.empty(), dropPointMapsIntoCard, ...
static SDecision reference(const SFacts& f) {
    SDecision d;

    // if (WINDOW && ScrollOverview::Dock::pillContains(...)) { minimizeWithFlight; return; }
    if (f.haveWindow && f.overPill) {
        d.action = EAction::Minimize;
        return d;
    }

    // if (!DROPWORKSPACE) { grid reflow seed; return; }
    if (!f.haveDropWorkspace) {
        d.action = EAction::CancelToGrid;
        return d;
    }

    // if (DROPSCROLLINGLAYOUT && DROPANCHOR && DROPPINGONSCROLLINGCROSSAXIS && isFullscreen(DROPANCHOR))
    if (f.scrollingLayout && f.haveAnchor && f.onScrollingCrossAxis && f.anchorFullscreen)
        d.clearAnchorFullscreen = true;

    d.useOriginalBox               = f.haveOriginalBox;          // HAVEORIGINAL
    d.mapPointIntoCard             = f.dropPointMapsIntoCard;    // dropPointMapsIntoCard
    d.restoreSourceFullscreenFocus = f.restoreSourceFullscreenFocus;

    if (f.retileOnEnd && f.moveWorkspace) {
        d.action = EAction::RetileMove;
        if (f.scrollingLayout) {
            if (!f.dropPointMapsIntoCard)
                d.placement = EPlacement::ScrollEdgeFar;             // ...WorkspaceEdge(TARGET, 1)
            else if (f.haveAnchor && f.haveDirection)
                d.placement = EPlacement::NextToAnchor;              // ...NextToWindow(TARGET, DROPANCHOR, dir)
            else if (!f.haveAnchor)
                d.placement = EPlacement::ScrollEdgeSide;            // ...WorkspaceEdge(TARGET, dropSide)
        }
    } else if (f.retileOnEnd) {
        d.action = EAction::RetileLocal;
        if (f.haveAnchor && f.haveDirection && !f.scrollingLayout && f.anchorHasLayoutTarget)
            d.placement = EPlacement::SwitchTargets;                 // g_layoutManager->switchTargets(...)
        else if (f.haveAnchor && f.haveDirection)
            d.placement = EPlacement::NextToAnchor;
        else if (f.scrollingLayout && !f.haveAnchor)
            d.placement = EPlacement::ScrollEdgeSide;
    } else if (f.haveWindow && f.moveWorkspace) {
        d.action = EAction::FloatMove;
    } else if (f.haveTarget && !f.startedTiled) {
        d.action = EAction::FloatLocal;
    }

    return d;
}

static const char* actionName(EAction a) {
    switch (a) {
        case EAction::Minimize: return "Minimize";
        case EAction::CancelToGrid: return "CancelToGrid";
        case EAction::RetileMove: return "RetileMove";
        case EAction::RetileLocal: return "RetileLocal";
        case EAction::FloatMove: return "FloatMove";
        case EAction::FloatLocal: return "FloatLocal";
        case EAction::Nothing: return "Nothing";
    }
    return "?";
}

static const char* placementName(EPlacement p) {
    switch (p) {
        case EPlacement::None: return "None";
        case EPlacement::ScrollEdgeFar: return "ScrollEdgeFar";
        case EPlacement::ScrollEdgeSide: return "ScrollEdgeSide";
        case EPlacement::NextToAnchor: return "NextToAnchor";
        case EPlacement::SwitchTargets: return "SwitchTargets";
    }
    return "?";
}

static bool same(const SDecision& a, const SDecision& b) {
    return a.action == b.action && a.placement == b.placement && a.clearAnchorFullscreen == b.clearAnchorFullscreen && a.useOriginalBox == b.useOriginalBox &&
        a.mapPointIntoCard == b.mapPointIntoCard && a.restoreSourceFullscreenFocus == b.restoreSourceFullscreenFocus;
}

// The 16 facts, in bit order, so a failing row can be read back.
static const char* BITNAMES[] = {
    "haveWindow",   "overPill",        "haveDropWorkspace",    "retileOnEnd",  "moveWorkspace",        "startedTiled",       "haveTarget",     "scrollingLayout",
    "haveOriginalBox", "haveAnchor",   "haveDirection",        "anchorHasLayoutTarget", "anchorFullscreen", "onScrollingCrossAxis", "dropPointMapsIntoCard",
    "restoreSourceFullscreenFocus",
};
static constexpr int NBITS = 16;

static SFacts factsFromBits(unsigned bits) {
    SFacts f;
    f.haveWindow                   = bits & (1u << 0);
    f.overPill                     = bits & (1u << 1);
    f.haveDropWorkspace            = bits & (1u << 2);
    f.retileOnEnd                  = bits & (1u << 3);
    f.moveWorkspace                = bits & (1u << 4);
    f.startedTiled                 = bits & (1u << 5);
    f.haveTarget                   = bits & (1u << 6);
    f.scrollingLayout              = bits & (1u << 7);
    f.haveOriginalBox              = bits & (1u << 8);
    f.haveAnchor                   = bits & (1u << 9);
    f.haveDirection                = bits & (1u << 10);
    f.anchorHasLayoutTarget        = bits & (1u << 11);
    f.anchorFullscreen             = bits & (1u << 12);
    f.onScrollingCrossAxis         = bits & (1u << 13);
    f.dropPointMapsIntoCard        = bits & (1u << 14);
    f.restoreSourceFullscreenFocus = bits & (1u << 15);
    return f;
}

static std::string describe(unsigned bits) {
    std::string s;
    for (int i = 0; i < NBITS; ++i) {
        if (bits & (1u << i)) {
            if (!s.empty())
                s += " ";
            s += BITNAMES[i];
        }
    }
    return s.empty() ? "(nothing set)" : s;
}

int main() {
    int failures = 0;
    int counts[7] = {};

    for (unsigned bits = 0; bits < (1u << NBITS); ++bits) {
        const SFacts    F = factsFromBits(bits);
        const SDecision A = resolve(F);
        const SDecision B = reference(F);

        counts[static_cast<int>(A.action)]++;

        if (same(A, B))
            continue;

        if (++failures <= 20)
            std::printf("MISMATCH bits=0x%04x [%s]\n  resolve   %s/%s cf=%d orig=%d map=%d rsf=%d\n  reference %s/%s cf=%d orig=%d map=%d rsf=%d\n", bits,
                        describe(bits).c_str(), actionName(A.action), placementName(A.placement), A.clearAnchorFullscreen, A.useOriginalBox, A.mapPointIntoCard,
                        A.restoreSourceFullscreenFocus, actionName(B.action), placementName(B.placement), B.clearAnchorFullscreen, B.useOriginalBox, B.mapPointIntoCard,
                        B.restoreSourceFullscreenFocus);
    }

    // Every action has to be REACHED, or "all 65536 agree" would be a fact
    // about an unreachable ladder rather than about this one.
    std::printf("rows %u\n", 1u << NBITS);
    for (int i = 0; i < 7; ++i) {
        std::printf("  %-13s %6d\n", actionName(static_cast<EAction>(i)), counts[i]);
        if (counts[i] == 0) {
            std::printf("UNREACHED action %s\n", actionName(static_cast<EAction>(i)));
            ++failures;
        }
    }

    // The five real drags this rig exists for, named, so the table has anchors
    // a human can check by hand.
    struct SCase {
        const char* name;
        SFacts      facts;
        EAction     action;
        EPlacement  placement;
    };
    const SCase CASES[] = {
        {"drop on the dock pill", SFacts{.haveWindow = true, .overPill = true}, EAction::Minimize, EPlacement::None},
        {"released over nothing", SFacts{.haveWindow = true, .haveTarget = true}, EAction::CancelToGrid, EPlacement::None},
        {"floating tile to another desktop",
         SFacts{.haveWindow = true, .haveDropWorkspace = true, .moveWorkspace = true, .haveTarget = true, .haveOriginalBox = true, .dropPointMapsIntoCard = true},
         EAction::FloatMove, EPlacement::None},
        {"floating tile dropped on its own card", SFacts{.haveWindow = true, .haveDropWorkspace = true, .haveTarget = true, .haveOriginalBox = true}, EAction::FloatLocal,
         EPlacement::None},
        {"tiled window swapped with the tile under the cursor",
         SFacts{.haveWindow = true,
                .haveDropWorkspace = true,
                .retileOnEnd       = true,
                .startedTiled      = true,
                .haveTarget        = true,
                .haveAnchor        = true,
                .haveDirection     = true,
                .anchorHasLayoutTarget = true},
         EAction::RetileLocal, EPlacement::SwitchTargets},
    };

    for (const auto& C : CASES) {
        const SDecision D = resolve(C.facts);
        const bool      OK = D.action == C.action && D.placement == C.placement;
        std::printf("  %-52s %s/%s %s\n", C.name, actionName(D.action), placementName(D.placement), OK ? "ok" : "WRONG");
        if (!OK)
            ++failures;
    }

    std::printf(failures ? "DROP_TABLE FAIL (%d)\n" : "DROP_TABLE OK (%d)\n", failures);
    return failures ? 1 : 0;
}
