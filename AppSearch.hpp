#pragma once

#include <string>
#include <vector>

// OVERVIEW_CPP_SPEC §13.2 F3. The app half of the GNOME-like search.
//
// This is a result model that lives ALONGSIDE shouldShowOverviewWindow's
// membership gate, never inside it: the gate decides which windows exist for
// every overview path at once, and app results are a second, ordered list that
// the grid does not represent. See RICE_PROGRESS.md "F3-scope" §1.
namespace AppSearch {
    struct SEntry {
        std::string id;      // desktop id, subdirs flattened with '-'
        std::string name;    // Name=
        std::string generic; // GenericName=
        std::string comment; // Comment=
        std::string keywords;
        std::string exec;    // raw Exec=, field codes not yet stripped
        std::string icon;
        std::string wmClass; // StartupWMClass=, measured absent on 185/186 entries
        bool        terminal = false;

        std::string haystack; // lowercased name/generic/comment/keywords/id, built once
    };

    // Scans lazily on first call. ~19 visible apps in the test VM, so this is a
    // plain in-memory vector: no index, no cache, no invalidation story.
    const std::vector<SEntry>& inventory();
    void                       refresh();

    // Ranked best-first. Empty query yields nothing -- an unfiltered overview
    // shows windows, not a list of every installed app.
    std::vector<const SEntry*> search(const std::string& query, size_t limit);

    // Detached, so the app outlives the overview closing.
    // terminalCmd is used only for Terminal=true entries; empty falls back to
    // $TERMINAL.
    bool launch(const SEntry& entry, const std::string& terminalCmd);
}
