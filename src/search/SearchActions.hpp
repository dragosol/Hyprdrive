#pragma once

// What a result does: the pane-up test, the menu-step settle, and activation.
// Cut from OverviewInternal.hpp by pure code motion. Not standalone: that header
// includes this one at the point the block stood, after everything it reads.

namespace OvInternal {

// THE RESULTS PANE IS UP: something is typed, a submenu is open, or the search
// was focused with nothing typed yet (a click on the pill, or a menu walked back
// to its root) -- which BROWSES: the menu's root, the folder shortcuts, the
// agent help rows (FEATURE-INVENTORY D5/D6/D9). Every "are there results to
// walk into" question asks this one, so the pane and the keys cannot disagree.
// The focused-and-empty browse is search:browse_on_click (off by default,
// user 2026-11-04): off, the pane is up only for a query or a submenu.
inline bool overviewSearchPaneUp() {
    auto& S = searchSession();
    return !S.query.text.empty() || (S.query.active && Hyprdrive::Config::getSearchBrowseOnClick()) || SearchBackend::canNavigateMenuBack();
}

// After ANY step through the menu tree -- a drill, the Back row, Esc, Backspace
// or Left -- the keyboard stays in the results, so the next Esc/Backspace walks
// up again instead of falling through to "empty query = close", and the
// highlight is on the first child (never the Back row: a second Enter runs it)
// -- or, on the way UP, on the submenu just left (`from`), so Enter goes back
// down and a run of Esc never parks the highlight on Lock or Shut Down.
// The walk up ends in the root browse, not in an empty pane: at the root the
// search counts as focused-and-empty, which lists the menu's root.
inline void overviewSettleMenuStep(const std::string& from = {}) {
    auto& S = searchSession();
    if (!SearchBackend::canNavigateMenuBack()) {
        if (!Hyprdrive::Config::getSearchBrowseOnClick()) {
            // No root browse to land in: back to the bare search field.
            S.nav.zone              = EOverviewNavZone::Search;
            S.nav.selection         = -1;
            S.nav.explicitSelection = false;
            S.nav.intent            = ESearchIntent::Typing;
            S.nav.hoverIndex        = -1;
            return;
        }
        S.query.active = true;
    }
    S.nav.zone               = EOverviewNavZone::Result;
    S.nav.explicitSelection  = true;
    S.nav.selectFirstPending = false;
    S.nav.intent             = ESearchIntent::Browsing;
    S.nav.hoverIndex         = -1;

    const auto NEXT = overviewSearchRows();
    int        sel  = NEXT.empty() ? -1 : 0;
    for (int i = 0; i < sc<int>(NEXT.size()); ++i) {
        if (NEXT[sc<size_t>(i)].column != 0)
            continue;
        if (NEXT[sc<size_t>(i)].omarchy && NEXT[sc<size_t>(i)].omarchy->kind == SearchBackend::EItemKind::Back)
            continue;
        sel = i;
        break;
    }
    if (!from.empty()) {
        for (int i = 0; i < sc<int>(NEXT.size()); ++i) {
            if (NEXT[sc<size_t>(i)].column == 0 && NEXT[sc<size_t>(i)].omarchy && NEXT[sc<size_t>(i)].omarchy->kind == SearchBackend::EItemKind::Menu &&
                NEXT[sc<size_t>(i)].omarchy->id == from) {
                sel = i;
                break;
            }
        }
    }
    S.nav.selection = sel;
}

// Activating a result runs the corresponding app, Omarchy action, agent prompt,
// calculator copy, or file open. Submenu navigation returns false so the overview
// stays open while drilling down into the hierarchy. For an already-open app,
// Enter focuses that window unless newInstance is set (double-tap Shift).
void overviewQueryEdited(); // main.cpp

inline bool activateSearchResult(int index, bool newInstance = false) {
    auto& S = searchSession();
    const auto RESULTS = overviewSearchRows();
    if (index < 0 || index >= sc<int>(RESULTS.size()))
        return false;

    const auto& ROW = RESULTS[index];

    // A tool row that rewrites the query (AI & Tools "Define" / "Translate"):
    // the panel turns into the tool, and the overview stays up to show it.
    if (ROW.omarchy && ROW.omarchy->kind == SearchBackend::EItemKind::Action && ROW.omarchy->actionCommand.starts_with(OVERVIEW_QUERY_REWRITE)) {
        S.query.text             = ROW.omarchy->actionCommand.substr(OVERVIEW_QUERY_REWRITE.size());
        S.query.active           = true;
        S.nav.zone               = EOverviewNavZone::Search;
        S.nav.selection          = -1;
        S.nav.explicitSelection  = false;
        S.nav.selectFirstPending = false;
        S.nav.intent             = ESearchIntent::Typing;
        S.nav.hoverIndex         = -1;
        // The rewritten query owes the same trailing work as a typed one --
        // without it no provider (and no lookup) ever saw `define <word>`.
        overviewQueryEdited();
        return false;
    }

    // A status row ("Looking up...") is not a result.
    if (ROW.toolStatus)
        return false;

    if (ROW.omarchy) {
        if (ROW.omarchy->kind == SearchBackend::EItemKind::Menu || ROW.omarchy->kind == SearchBackend::EItemKind::Back) {
            const bool DRILL = ROW.omarchy->kind == SearchBackend::EItemKind::Menu;
            const auto LEFT  = DRILL ? std::string{} : SearchBackend::menuCurrentRoute();
            SearchBackend::activate(*ROW.omarchy);
            if (DRILL && !S.query.text.empty()) {
                // The drill clears the query the windows were filtered by, so
                // the membership gate has to hear about it like any other edit:
                // unbumped, every tile kept the "test tools" answer (hidden) for
                // as long as the menu was open, and the window lists rebuilt on
                // the empty-query edge were built from that stale answer -- a
                // blank grid even after Esc walked back to the root (D5b).
                S.query.text.clear();
                Membership::bump("menu drill");
            }
            overviewSettleMenuStep(LEFT);
            return false;
        }
        return SearchBackend::activate(*ROW.omarchy);
    } else if (ROW.app) {
        if (!newInstance) {
            if (const auto W = overviewWindowForApp(*ROW.app)) {
                S.nav.pendingFocus = W;
                return true;
            }
        }
        AppSearch::launch(*ROW.app, Hyprdrive::Config::getTerminal());
        return true;
    } else {
        SearchProviders::activate(ROW.provider, S.query.text);
        return true;
    }
}

} // namespace OvInternal
