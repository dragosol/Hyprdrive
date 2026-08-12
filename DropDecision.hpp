#pragma once

// Where a released window drag goes, as a pure function.
//
// endWindowDrag() was 277 lines in which the facts about the drop, the choice
// that followed from them and the compositor calls that carried it out were the
// same code. The ladder below is that choice and nothing else: no Hyprland
// types, no state, no side effects, so it can be walked exhaustively off the
// compositor -- scripts/drop_table_test.cpp compiles this header on the host and
// checks every reachable combination against the branch structure it replaced.
//
// The caller gathers facts in three stages and asks again after each, because
// the gathering itself is not free: the pill branch must return before anything
// queries a drop workspace, and the anchor query writes the destination
// overview's cursor before it reads it. resolve() is total at every stage --
// the fields a stage has not filled in yet are false, which is why the two
// early actions are decided by the facts that ARE known first.

namespace ScrollOverview::Drop {

    struct SFacts {
        // stage 1 -- the window and where the button came up
        bool haveWindow        = false;
        bool overPill          = false;
        // stage 2 -- the destination
        bool haveDropWorkspace = false;
        bool retileOnEnd       = false; // startedTiled AND a live layout target/space/algorithm
        bool moveWorkspace     = false; // the drop workspace is not the one the drag started on
        bool startedTiled      = false;
        bool haveTarget        = false;
        bool scrollingLayout   = false;
        bool haveOriginalBox   = false;
        // stage 3 -- the anchor under the cursor
        bool haveAnchor             = false;
        bool haveDirection          = false; // the anchor came back with a side to sit on
        bool anchorHasLayoutTarget  = false;
        bool anchorFullscreen       = false;
        bool onScrollingCrossAxis   = false;
        bool dropPointMapsIntoCard  = false;
        bool restoreSourceFullscreenFocus = false;
    };

    enum class EAction {
        Minimize,     // released on the dock pill: the drop is a minimize and nothing else
        CancelToGrid, // no workspace under the cursor: keep everything, ease the tile home
        RetileMove,   // a tiled window, onto another workspace
        RetileLocal,  // a tiled window, within its own
        FloatMove,    // a floating window, onto another workspace
        FloatLocal,   // a floating window, within its own
        Nothing,      // a drop with nothing to move (no window, or no layout target)
    };

    // What to do with the layout target once the window is where it belongs.
    enum class EPlacement {
        None,
        ScrollEdgeFar,  // push to the far edge of a scrolling workspace (side +1)
        ScrollEdgeSide, // push to the edge the cursor left from (the caller's dropSide)
        NextToAnchor,   // insert beside the anchor window, on the anchor's direction
        SwitchTargets,  // swap slots with the anchor -- plain tiling only
    };

    struct SDecision {
        EAction    action    = EAction::Nothing;
        EPlacement placement = EPlacement::None;
        // The anchor is fullscreen and the drop crosses a scrolling layout's
        // secondary axis: it has to come out of fullscreen and give its column
        // width back before anything is inserted next to it.
        bool clearAnchorFullscreen = false;
        // A move commits the window's ORIGINAL global size, not the size of the
        // mission-control slot it was drawn at (X41/X42).
        bool useOriginalBox   = false;
        // The cursor can be read as a point inside the destination card, so the
        // window lands where it was dropped rather than where it already was.
        bool mapPointIntoCard = false;
        bool restoreSourceFullscreenFocus = false;
    };

    constexpr SDecision resolve(const SFacts& f) {
        SDecision d;

        if (f.haveWindow && f.overPill) {
            d.action = EAction::Minimize;
            return d;
        }

        if (!f.haveDropWorkspace) {
            d.action = EAction::CancelToGrid;
            return d;
        }

        d.clearAnchorFullscreen = f.scrollingLayout && f.haveAnchor && f.onScrollingCrossAxis && f.anchorFullscreen;
        d.restoreSourceFullscreenFocus = f.restoreSourceFullscreenFocus;
        d.useOriginalBox               = f.haveOriginalBox;
        d.mapPointIntoCard             = f.dropPointMapsIntoCard;

        if (f.retileOnEnd && f.moveWorkspace) {
            d.action = EAction::RetileMove;
            if (f.scrollingLayout) {
                if (!f.dropPointMapsIntoCard)
                    d.placement = EPlacement::ScrollEdgeFar;
                else if (f.haveAnchor && f.haveDirection)
                    d.placement = EPlacement::NextToAnchor;
                else if (!f.haveAnchor)
                    d.placement = EPlacement::ScrollEdgeSide;
            }
            return d;
        }

        if (f.retileOnEnd) {
            d.action = EAction::RetileLocal;
            if (f.haveAnchor && f.haveDirection && !f.scrollingLayout && f.anchorHasLayoutTarget)
                d.placement = EPlacement::SwitchTargets;
            else if (f.haveAnchor && f.haveDirection)
                d.placement = EPlacement::NextToAnchor;
            else if (f.scrollingLayout && !f.haveAnchor)
                d.placement = EPlacement::ScrollEdgeSide;
            return d;
        }

        if (f.haveWindow && f.moveWorkspace) {
            d.action = EAction::FloatMove;
            return d;
        }

        if (f.haveTarget && !f.startedTiled) {
            d.action = EAction::FloatLocal;
            return d;
        }

        return d;
    }

}
