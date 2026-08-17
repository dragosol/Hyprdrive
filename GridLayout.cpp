#include "GridLayout.hpp"
#include "OverviewGeometry.hpp"
#include "OverviewInternal.hpp"

#include <algorithm>
#include <ranges>

// Every body here came out of OverviewInternal.hpp unchanged except for the two
// mechanical substitutions the move forced: the four globals are now members of
// the one SGridAnimator, and the pure arithmetic (lerp, open-progress ramp,
// half-pixel comparison) forwards to OverviewGeometry. Nothing else moved, so a
// tile that lands somewhere new is a transcription slip and not a redesign.

namespace OvInternal {

    SGridAnimator& grid() {
        static SGridAnimator ANIMATOR;
        return ANIMATOR;
    }

    // Y9 taught overviewGridWindows and addOverviewWindow that a stashed window
    // belongs to the desktop it was minimized FROM. Two decisions kept reading
    // the raw m_workspace instead, and a stashed window's m_workspace is the
    // stash -- so it could never equal the active workspace, and a window
    // minimized FROM the active desktop answered "I live somewhere else". It
    // then took a grid slot twice: once as a home member, once as an
    // off-desktop match joining the active grid under B2. Measured with the
    // render-list shadow: 4145 RENDER-GRIDDUP lines in one soak, every one of
    // them a stashed window against its own home card. The visible cost is the
    // layout solving for N+1 -- two windows laid out as three, so the tiles sit
    // in row 0 of a two-row grid with an empty row underneath, which is the
    // user's "not centered or organized properly".
    WORKSPACEID overviewGridHomeWorkspace(const PHLWINDOW& window) {
        if (!window)
            return WORKSPACE_INVALID;

        if (const auto HOME = ScrollOverview::Minimize::originalWorkspace(window); HOME != WORKSPACE_INVALID)
            return HOME;

        return window->m_workspace ? window->m_workspace->m_id : WORKSPACE_INVALID;
    }

    std::vector<PHLWINDOW> overviewGridWindows(const PHLWORKSPACE& workspace) {
        std::vector<PHLWINDOW> windows;
        if (!workspace)
            return windows;

        for (const auto& window : Desktop::windowState()->windows()) {
            if (getOverviewWindowToShow(window) != window || !shouldShowOverviewWindow(window))
                continue;

            // Y9 (user): "when an app window is minimized it should still be
            // visible there, so I can see it and filter to it". A minimized window
            // is parked on the `special:minimized` stash, so its own m_workspace can
            // never equal a real one and the plain test below dropped it from every
            // grid. It belongs to the desktop it was minimized FROM, which is
            // exactly what Minimize records -- and the only source for it, since the
            // stash has overwritten the window's own answer.
            //
            // This also subsumes X58(a), which asked only that the SEARCH reach
            // minimized windows: they are in the grid now whether a query is typed
            // or not, and the query filters them like anything else.
            if (const auto HOME = ScrollOverview::Minimize::originalWorkspace(window); HOME != WORKSPACE_INVALID) {
                if (HOME != workspace->m_id)
                    continue;
            } else if (window->m_workspace != workspace)
                continue;

            windows.emplace_back(window);
        }

        return windows;
    }

    // OVERVIEW_CPP_SPEC section 5 B2. With a query typed, matches from every
    // workspace join the ACTIVE workspace's grid. A promoted window keeps living
    // in its own workspace's window list and is still drawn in that workspace's
    // pass; what changes is that its box comes from the active grid and is placed
    // at the active card's offset. Done here rather than by shuffling windows
    // between the per-workspace loops so the B1 invariant holds: render, hit-test
    // and drag all still read the same getOverviewWindowBox and cannot disagree.
    bool overviewGridPromotable(const PHLWINDOW& window, PHLMONITOR monitor) {
        if (g_search.query.text.empty() || !ScrollOverview::Config::getMissionControl() || !window || !monitor)
            return false;

        if (window->m_monitor != monitor)
            return false;

        const auto ACTIVE = monitor->m_activeWorkspace;
        const auto HOME   = overviewGridHomeWorkspace(window);
        return ACTIVE && HOME != WORKSPACE_INVALID && HOME != ACTIVE->m_id && shouldShowOverviewWindow(window);
    }

    // OVERVIEW_CPP_SPEC 13.2 F3-b, the symmetric half: "released back OUT to its
    // own desktop as the query stops matching". The instant a promoted window
    // stops matching it leaves the grid, so gridReflowBox is never called for it
    // and it cuts -- the exact mirror of the pull-in defect. Keep it promoted for
    // one reflow after the match dies so it still has somewhere to travel FROM.
    bool overviewGridReleasing(const PHLWINDOW& window, PHLMONITOR monitor) {
        const int DURATION = ScrollOverview::Config::getMissionControlReflowMs();
        if (DURATION <= 0 || !window)
            return false;

        const auto NOW = Time::steadyNow();
        auto&      G   = grid();

        if (overviewGridPromotable(window, monitor)) {
            if (G.releases.size() > 64)
                std::erase_if(G.releases, [](const auto& entry) { return !entry.second.window.lock(); });

            G.releases[window.get()] = SGridRelease{window, {}, false}; // armed, not running
            return false;
        }

        const auto IT = G.releases.find(window.get());
        if (IT == G.releases.end())
            return false;

        // A recycled address must not inherit a dead window's release, and a window
        // that unmapped mid-flight must stop being drawn -- the render gate below
        // trusts this function to have checked.
        if (IT->second.window.lock() != window || !validMapped(window)) {
            G.releases.erase(IT);
            return false;
        }

        if (!IT->second.started) {
            IT->second.started = true;
            IT->second.start   = NOW; // the match died on THIS frame, whenever it is
        }

        if (ScrollOverview::Config::animElapsedMs(IT->second.start) > sc<float>(DURATION) + GRID_RELEASE_GRACE_MS) {
            G.releases.erase(IT);
            return false;
        }

        return true;
    }

    bool overviewGridPromoted(const PHLWINDOW& window, PHLMONITOR monitor) {
        return overviewGridPromotable(window, monitor) || overviewGridReleasing(window, monitor);
    }

    // Membership of the MAIN grid. Identical to overviewGridWindows for an empty
    // query. The strip deliberately keeps the workspace-scoped list: its minis and
    // its "no matches" count both need the per-cell answer.
    std::vector<PHLWINDOW> overviewMainGridWindows(const PHLWORKSPACE& workspace, PHLMONITOR monitor) {
        auto windows = overviewGridWindows(workspace);
        if (g_search.query.text.empty() || !monitor)
            return windows;

        for (const auto& window : Desktop::windowState()->windows()) {
            // Promotable, not promoted: a RELEASING tile must leave the grid
            // immediately so the survivors close up WHILE it travels (F3-b-iii,
            // outbound). It keeps being drawn -- it just no longer owns a slot.
            if (getOverviewWindowToShow(window) == window && overviewGridPromotable(window, monitor))
                windows.emplace_back(window);
        }

        return windows;
    }

    Vector2D overviewGridWindowSize(const PHLWINDOW& window) {
        return window->geometricBox(Desktop::View::IGeometric::GEOMETRIC_CURRENT).size();
    }

    // ponytail: recomputed per window per frame, O(windows^2) on the focused
    // workspace. Fine at desktop counts; memoise per frame if it ever shows up.
    bool overviewGridLayout(const PHLWORKSPACE& workspace, PHLMONITOR monitor, const PHLWINDOW& target, CBox& out) {
        auto WINDOWS = overviewMainGridWindows(workspace, monitor);

        // The dragged window keeps a slot for its OWN query: the drag proxy is sized
        // off it, and a proxy sized from the N-1 layout would jump the frame the
        // drag begins. It is absent only from everyone else's layout.
        if (const auto EXCLUDED = grid().dragExcluded; EXCLUDED && target.get() != EXCLUDED)
            std::erase_if(WINDOWS, [EXCLUDED](const auto& window) { return window.get() == EXCLUDED; });

        if (Membership::renderShadowEnabled()) {
            for (size_t i = 0; i < WINDOWS.size(); ++i)
                for (size_t j = i + 1; j < WINDOWS.size(); ++j)
                    if (WINDOWS[i] == WINDOWS[j])
                        Membership::renderDivergence("GRIDDUP", workspace->m_id, WINDOWS[i]->m_workspace ? WINDOWS[i]->m_workspace->m_id : WORKSPACE_INVALID,
                                                     WINDOWS[i]->m_class, WINDOWS[i]->m_title);
        }

        const auto TARGETIT = std::ranges::find(WINDOWS, target);
        if (TARGETIT == WINDOWS.end())
            return false;

        CBox usable = {monitor->m_position, monitor->m_size};
        if (workspace->m_space) {
            if (const auto WORKAREA = workspace->m_space->workArea(); WORKAREA.w > 1 && WORKAREA.h > 1)
                usable = WORKAREA;
        }

        // Grid tiles must not slide under the strip band or the search row (X10) --
        // shrinking `usable` here is what makes the tiles compact to give the space
        // back.
        //
        // X60 SUPERSEDES X48's placement: the results are part of the TOP chrome
        // now, between the search row and the strip, so the whole stack below them
        // moves down and the tiles give their space back from the top. X21's reflow
        // is untouched -- the tiles still shrink and compact off the same eased
        // band, only the direction changed. X48's real constraint survives in
        // overviewResultsBandTarget's budget: the band may never grow so tall that
        // the strip and the tiles are pushed off the screen.
        if (const float TOPCHROME = overviewStripLogicalHeight(monitor) + overviewSearchLogicalHeight(monitor) + overviewResultsLogicalHeight(monitor); TOPCHROME > 0.F) {
            usable.y += TOPCHROME;
            usable.h -= TOPCHROME;
            if (usable.h <= 1)
                return false;
        }
        const size_t COUNT = WINDOWS.size();
        const float  GAP   = sc<float>(ScrollOverview::Config::getMissionControlGap());

        usable.x += GAP;
        usable.y += GAP;
        usable.w -= 2.0 * GAP;
        usable.h -= 2.0 * GAP;
        if (usable.w <= 1 || usable.h <= 1)
            return false;

        // Pick the row count that lets every window share the largest common scale.
        // Capped at 1.0 so a lone window keeps its real size instead of ballooning.
        size_t bestRows  = 0;
        float  bestScale = 0.F;
        for (size_t rows = 1; rows <= COUNT; ++rows) {
            const size_t COLS  = (COUNT + rows - 1) / rows;
            const float  CELLW = (sc<float>(usable.w) - GAP * sc<float>(COLS - 1)) / sc<float>(COLS);
            const float  CELLH = (sc<float>(usable.h) - GAP * sc<float>(rows - 1)) / sc<float>(rows);
            if (CELLW <= 1.F || CELLH <= 1.F)
                continue;

            float rowScale = 1.F;
            for (const auto& window : WINDOWS) {
                const auto SIZE = overviewGridWindowSize(window);
                if (SIZE.x <= 1 || SIZE.y <= 1)
                    continue;

                rowScale = std::min({rowScale, CELLW / sc<float>(SIZE.x), CELLH / sc<float>(SIZE.y)});
            }

            if (rowScale > bestScale) {
                bestScale = rowScale;
                bestRows  = rows;
            }
        }

        if (bestRows == 0 || bestScale <= 0.F)
            return false;

        // Spread the windows over the rows as evenly as possible, earlier rows take
        // the remainder.
        const size_t BASE  = COUNT / bestRows;
        const size_t EXTRA = COUNT % bestRows;
        const size_t INDEX = sc<size_t>(std::distance(WINDOWS.begin(), TARGETIT));

        size_t row      = 0;
        size_t rowFirst = 0;
        size_t rowCount = 0;
        for (; row < bestRows; ++row) {
            rowCount = BASE + (row < EXTRA ? 1 : 0);
            if (INDEX < rowFirst + rowCount)
                break;

            rowFirst += rowCount;
        }

        if (row >= bestRows)
            return false;

        float rowWidth = GAP * sc<float>(rowCount - 1);
        for (size_t i = 0; i < rowCount; ++i)
            rowWidth += sc<float>(overviewGridWindowSize(WINDOWS[rowFirst + i]).x) * bestScale;

        float x = sc<float>(usable.x) + (sc<float>(usable.w) - rowWidth) / 2.F;
        for (size_t i = rowFirst; i < INDEX; ++i)
            x += sc<float>(overviewGridWindowSize(WINDOWS[i]).x) * bestScale + GAP;

        const auto  SIZE   = overviewGridWindowSize(target);
        const float WIDTH  = sc<float>(SIZE.x) * bestScale;
        const float HEIGHT = sc<float>(SIZE.y) * bestScale;
        const float CELLH  = (sc<float>(usable.h) - GAP * sc<float>(bestRows - 1)) / sc<float>(bestRows);
        const float Y      = sc<float>(usable.y) + sc<float>(row) * (CELLH + GAP) + (CELLH - HEIGHT) / 2.F;

        out = CBox{x, Y, WIDTH, HEIGHT};
        return true;
    }

    bool overviewGridSlot(const PHLWINDOW& window, PHLMONITOR monitor, CBox& out) {
        if (!ScrollOverview::Config::getMissionControl() || !monitor)
            return false;

        const auto ACTIVE = monitor->m_activeWorkspace;
        if (!ACTIVE)
            return false;

        // A promoted window is laid out in the ACTIVE workspace's grid, not its own.
        // HOME, not m_workspace: a window stashed FROM the active desktop owns a slot
        // in the active grid outright, and asking its m_workspace sent it down the
        // promoted branch instead -- the other half of the duplicate above.
        if (overviewGridHomeWorkspace(window) != ACTIVE->m_id && !overviewGridPromoted(window, monitor))
            return false;

        return overviewGridLayout(ACTIVE, monitor, window, out);
    }

    float overviewGridProgress(float scale) {
        return ScrollOverview::Geometry::gridProgress(scale, ScrollOverview::Config::getScale());
    }

    CBox overviewGridLerpBox(const CBox& from, const CBox& to, float t) {
        return ScrollOverview::Geometry::lerpBox(from, to, t);
    }

    float gridReflowEase(float t) {
        return houseEase(true, t);
    }

    bool gridBoxesDiffer(const CBox& a, const CBox& b) {
        return ScrollOverview::Geometry::boxesDiffer(a, b);
    }

    CBox gridReflowBox(const PHLWINDOW& window, const CBox& slot, const CBox* enterFrom, bool promoted) {
        const int DURATION = ScrollOverview::Config::getMissionControlReflowMs();
        if (DURATION <= 0)
            return slot;

        const auto NOW = Time::steadyNow();
        auto&      G   = grid();

        if (G.reflows.size() > 64)
            std::erase_if(G.reflows, [](const auto& entry) { return !entry.second.window.lock(); });

        auto& entry = G.reflows[window.get()];

        // OVERVIEW_CPP_SPEC F3-b-i. A tile that was not in the grid last frame is
        // ENTERING now -- first appearance, or a search promoting it off another
        // desktop. Seeding from `slot` makes from == to and draws it straight at its
        // destination, which is exactly the "matches just spawn in" defect. Seed it
        // where it really sits and the ease below carries it in.
        //
        // Untouched-for-a-while stands in for "was not in the grid", so searching the
        // same window a second time re-enters properly instead of reusing its stale
        // settled entry. KNOWN == false also catches a recycled address handing a new
        // window a dead one's entry.
        const bool KNOWN = entry.window.lock() == window;
        // An entering tile is seeded off-screen on purpose, so it is culled -- and
        // on frames where that culls the whole workspace, its pass is skipped and
        // this function is not called at all. Reseeding then would throw away an
        // ease that is still running and draw the tile at its destination.
        const bool INFLIGHT = KNOWN && ScrollOverview::Config::animElapsedMs(entry.start) < sc<float>(DURATION);
        // Genuinely absent: a tile that stopped being drawn entirely, stayed gone
        // long enough to finish whatever it was doing, and is coming back.
        const bool UNDRAWN = KNOWN && !INFLIGHT && g_overviewFrame - entry.lastFrame > 1;
        // ...and the case staleness can never see, because the tile was on screen
        // the whole time: it just crossed onto the active card.
        const bool JOINED = KNOWN && promoted && !entry.promotedLast;

        if (!KNOWN || UNDRAWN || JOINED) {
            const CBox START = enterFrom ? *enterFrom : slot;
            entry            = SGridReflow{window, START, slot, NOW, g_overviewFrame, promoted};
            if (gridBoxesDiffer(START, slot))
                G.reflowActive = true;
            return START;
        }

        entry.lastFrame    = g_overviewFrame;
        entry.promotedLast = promoted;

        const float ELAPSED = ScrollOverview::Config::animElapsedMs(entry.start);
        const float T       = gridReflowEase(ELAPSED / sc<float>(DURATION));
        const CBox  CURRENT = overviewGridLerpBox(entry.from, entry.to, T);

        if (gridBoxesDiffer(slot, entry.to)) {
            entry.from     = CURRENT; // retarget from where the tile actually is
            entry.to       = slot;
            entry.start    = NOW;
            G.reflowActive = true;
            return CURRENT;
        }

        if (T < 1.F)
            G.reflowActive = true;

        return CURRENT;
    }

} // namespace OvInternal
