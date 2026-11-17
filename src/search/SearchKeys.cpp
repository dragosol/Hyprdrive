// The search half of the overview's arrow, Tab and Return keys (SearchKeys.hpp).
// Cut out of COverview::moveSelection, onKeyboardKey and tabAcrossMonitors with
// their branch order kept verbatim.
#include "OverviewParts.hpp"
#include "SearchKeys.hpp"

Search::SKeyOutcome Search::onArrow(CSession& S, MONITORID monitor, bool LEFT, bool RIGHT, bool UP, bool DOWN) {
    // UP/DOWN WALK THE COLUMN'S FULL LIST, not just the rows drawn last frame.
    // The trim (D14) shows a window of a long column; stepping past its last
    // drawn row selects the next row and the trim scrolls the window onto it,
    // so rows behind "+N" are reachable. The tool pane lays its rows out on
    // its own and keeps the drawn-row walk below.
    if (S.nav.zone == EOverviewNavZone::Result && (UP || DOWN) && S.nav.selection >= 0) {
        const auto ROWS = overviewSearchRows(S);
        if (!ROWS.empty() && ROWS[0].tool == 0) {
            for (const auto& SEC : overviewSearchSections(ROWS)) {
                const auto IT = std::ranges::find(SEC.rows, sc<size_t>(S.nav.selection));
                if (IT == SEC.rows.end())
                    continue;
                const auto P = (IT - SEC.rows.begin()) + (UP ? -1 : 1);
                S.nav.explicitSelection = true;
                S.nav.intent            = ESearchIntent::Browsing;
                if (P >= 0 && P < sc<std::ptrdiff_t>(SEC.rows.size()))
                    S.nav.selection = sc<int>(SEC.rows[sc<size_t>(P)]);
                else if (UP) {
                    // Up off the top of the column returns focus to the search bar.
                    S.nav.zone              = EOverviewNavZone::Search;
                    S.nav.selection         = -1;
                    S.nav.explicitSelection = false;
                    S.nav.intent            = ESearchIntent::Typing;
                }
                return {.handled = true, .damage = true};
            }
        }
    }

    // 2D Navigation inside the Results zone
    if (S.nav.zone == EOverviewNavZone::Result && !S.layoutOn(monitor).hits.empty()) {
        const SSearchRowHit* curHit = nullptr;
        for (const auto& hit : S.layoutOn(monitor).hits) {
            if (hit.index == S.nav.selection) {
                curHit = &hit;
                break;
            }
        }

        if (curHit) {
            S.nav.explicitSelection = true;
            S.nav.intent            = ESearchIntent::Browsing;

            if (UP) {
                if (curHit->rowInCol == 0) {
                    // Return focus to search bar
                    S.nav.zone              = EOverviewNavZone::Search;
                    S.nav.selection         = -1;
                    S.nav.explicitSelection = false;
                    S.nav.intent            = ESearchIntent::Typing;
                    return {.handled = true, .damage = true};
                }
                for (const auto& hit : S.layoutOn(monitor).hits) {
                    if (hit.column == curHit->column && hit.rowInCol == curHit->rowInCol - 1) {
                        S.nav.selection = hit.index;
                        return {.handled = true, .damage = true};
                    }
                }
                return {.handled = true};
            }

            if (DOWN) {
                for (const auto& hit : S.layoutOn(monitor).hits) {
                    if (hit.column == curHit->column && hit.rowInCol == curHit->rowInCol + 1) {
                        S.nav.selection = hit.index;
                        return {.handled = true, .damage = true};
                    }
                }
                return {.handled = true};
            }

            if (RIGHT) {
                int maxCol = 0;
                for (const auto& hit : S.layoutOn(monitor).hits)
                    maxCol = std::max(maxCol, hit.column);

                for (int targetCol = curHit->column + 1; targetCol <= maxCol; ++targetCol) {
                    const SSearchRowHit* bestHit = nullptr;
                    int bestDiff = 999;
                    for (const auto& hit : S.layoutOn(monitor).hits) {
                        if (hit.column == targetCol) {
                            int diff = std::abs(hit.rowInCol - curHit->rowInCol);
                            if (diff < bestDiff) {
                                bestDiff = diff;
                                bestHit  = &hit;
                            }
                        }
                    }
                    if (bestHit) {
                        S.nav.selection = bestHit->index;
                        return {.handled = true, .damage = true};
                    }
                }
                return {.handled = true};
            }

            if (LEFT) {
                if (curHit->column == 0) {
                    if (overviewMenuBack(S))
                        return {.handled = true};
                    return {.handled = true};
                }

                for (int targetCol = curHit->column - 1; targetCol >= 0; --targetCol) {
                    const SSearchRowHit* bestHit = nullptr;
                    int bestDiff = 999;
                    for (const auto& hit : S.layoutOn(monitor).hits) {
                        if (hit.column == targetCol) {
                            int diff = std::abs(hit.rowInCol - curHit->rowInCol);
                            if (diff < bestDiff) {
                                bestDiff = diff;
                                bestHit  = &hit;
                            }
                        }
                    }
                    if (bestHit) {
                        S.nav.selection = bestHit->index;
                        return {.handled = true, .damage = true};
                    }
                }
                return {.handled = true};
            }
        }
    }

    // Down drops into the results from the SEARCH FIELD only. `|| zone !=
    // Result` also matched the window grid and the strip, so with a query up
    // every Down in the grid jumped back to the results instead of walking to
    // the next row of tiles (user, 2026-09-29).
    if (S.nav.zone == EOverviewNavZone::Search && DOWN) {
        if (!S.layoutOn(monitor).hits.empty()) {
            S.nav.zone              = EOverviewNavZone::Result;
            S.nav.selection         = S.layoutOn(monitor).hits[0].index;
            S.nav.explicitSelection = true;
            S.nav.intent            = ESearchIntent::Browsing;
            return {.handled = true, .damage = true};
        }
    }

    return {};
}

bool Search::downIntoResults(CSession& S, MONITORID monitor) {
    if (S.nav.zone != EOverviewNavZone::Result && S.nav.zone != EOverviewNavZone::Tile && S.nav.zone != EOverviewNavZone::Desktop &&
        overviewSearchPaneUp(S)) {
        if (!S.layoutOn(monitor).hits.empty()) {
            S.nav.zone              = EOverviewNavZone::Result;
            S.nav.selection         = S.layoutOn(monitor).hits[0].index;
            S.nav.explicitSelection = true;
            S.nav.intent            = ESearchIntent::Browsing;
            return true;
        } else {
            const auto RESULTS = overviewSearchRows(S);
            if (!RESULTS.empty()) {
                S.nav.zone              = EOverviewNavZone::Result;
                S.nav.selection         = 0;
                S.nav.explicitSelection = true;
                S.nav.intent            = ESearchIntent::Browsing;
                return true;
            }
        }
    }
    return false;
}

bool Search::tabIntoResults(CSession& S, bool rowsFirst) {
    if (!rowsFirst && !overviewSearchPaneUp(S))
        return false;
    const auto RESULTS = overviewSearchRows(S);
    if ((!rowsFirst || overviewSearchPaneUp(S)) && !RESULTS.empty()) {
        S.nav.zone              = EOverviewNavZone::Result;
        S.nav.explicitSelection = true;
        S.nav.intent            = ESearchIntent::Browsing;
        S.nav.keyboardTile      = false;
        if (S.nav.selection < 0 || S.nav.selection >= sc<int>(RESULTS.size()))
            S.nav.selection = 0;
        return true;
    }
    return false;
}

void Search::tabEnterSearch(CSession& S, const std::vector<SSearchRow>& RESULTS) {
    if (overviewSearchPaneUp(S) && !RESULTS.empty()) {
        S.nav.zone              = EOverviewNavZone::Result;
        S.nav.explicitSelection = true;
        S.nav.intent            = ESearchIntent::Browsing;
        if (S.nav.selection < 0 || S.nav.selection >= sc<int>(RESULTS.size()))
            S.nav.selection = 0;
    } else {
        S.nav.zone      = EOverviewNavZone::Search;
        S.nav.selection = -1;
        S.nav.intent    = ESearchIntent::Typing;
    }
}

// The root browse (nothing typed, no submenu) runs only a row the keyboard
// walked onto: Enter in the bare pill still means "back to the window", never
// "run the first menu row" (Lock, Shut Down).
Search::SReturnPick Search::returnPick(CSession& S, const std::function<size_t()>& matchingWindows) {
    const bool PICKABLE = !S.query.text.empty() || SearchBackend::canNavigateMenuBack() ||
        (S.query.active && S.nav.zone == EOverviewNavZone::Result);
    if (!(PICKABLE && S.nav.zone != EOverviewNavZone::Tile && S.nav.zone != EOverviewNavZone::Desktop))
        return {};
    const auto RESULTS = overviewSearchRows(S);

    int launchIdx = -1;
    if (S.nav.zone == EOverviewNavZone::Result && S.nav.selection >= 0 && S.nav.selection < sc<int>(RESULTS.size()))
        launchIdx = S.nav.selection;
    else if (!RESULTS.empty() && (matchingWindows() == 0 || S.nav.zone == EOverviewNavZone::Search || SearchBackend::canNavigateMenuBack()))
        launchIdx = 0;
    return {.pickable = true, .index = launchIdx};
}
