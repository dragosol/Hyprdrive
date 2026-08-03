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

        std::string path;     // the .desktop file itself, so actions can be read on demand
        std::string haystack; // lowercased name/generic/comment/keywords/id, built once
    };

    // OVERVIEW_CPP_SPEC §13.9 X28. One `[Desktop Action <id>]` group.
    struct SAction {
        std::string name; // Name=
        std::string exec; // raw Exec=, field codes not yet stripped
    };

    // Scans lazily on first call. ~19 visible apps in the test VM, so this is a
    // plain in-memory vector: no index, no cache, no invalidation story.
    const std::vector<SEntry>& inventory();
    void                       refresh();

    // Ranked best-first. Empty query yields nothing -- an unfiltered overview
    // shows windows, not a list of every installed app.
    std::vector<const SEntry*> search(const std::string& query, size_t limit);

    // OVERVIEW_CPP_SPEC §13.12 X51/X52. Build the `stem -> path` icon index up
    // front, so the first search does not pay for it. Idempotent, and a no-op
    // once built; call it wherever a stall is invisible (plugin load), never
    // from a frame that is already late.
    void warmIconIndex();

    // Absolute path to the best icon file for an Icon= value, or "" if none.
    // Pure filesystem: decode and texture upload belong to the render layer.
    // Falls back to a generic application icon when the named one is missing
    // from the theme chain -- an entry with no icon at all still gets a tile.
    std::string resolveIconPath(const std::string& iconName);

    // Detached, so the app outlives the overview closing.
    // terminalCmd is used only for Terminal=true entries; empty falls back to
    // $TERMINAL.
    bool launch(const SEntry& entry, const std::string& terminalCmd);

    // OVERVIEW_CPP_SPEC §13.7 X18, open-window half. Parity with
    // windows-search-provider@G-dH, read off the HOST's own settings rather
    // than its defaults: search-method=0 is Strict, not fuzzy. Strict means
    // every space-separated term must appear somewhere in the text, in any
    // order, case- and accent-insensitively. Lives here because the accent
    // fold and the app-name lookup both belong to the desktop-entry layer.
    bool        strictMatch(const std::string& query, const std::string& text);

    // The app NAME for a window class ("org.gnome.Nautilus" -> "Files"), or ""
    // when no desktop entry claims it. The host matches window results against
    // the app name, so without this "files" would never find a Nautilus window.
    std::string appNameForClass(const std::string& wmClass);

    // The Icon= value for a window class, or "" when no entry claims it.
    // Shares appNameForClass's lookup and cache -- the dock (X27) asks the same
    // question about the same classes, once per frame.
    std::string iconForClass(const std::string& wmClass);

    // The desktop id for a window class, or "". X28's Show Details needs it.
    std::string idForClass(const std::string& wmClass);

    // X32. The entry for a desktop id, or nullptr. Favourites are stored as ids
    // and a pinned app is usually NOT running, so the dock cannot reach its icon
    // or its Exec through a window class the way every other lookup here does.
    // The pointer is into inventory(), so it dies on refresh() -- use it and
    // drop it, never store it.
    const SEntry* entryForId(const std::string& id);

    // X28. The entry's `Actions=` groups in declared order, or empty. Re-reads
    // the .desktop file: this is asked once per right-click, not per frame, so
    // the inventory stays the small thing the search path wants.
    std::vector<SAction> actionsForClass(const std::string& wmClass);

    // X28. Detached spawn of a raw Exec= string, field codes stripped. The
    // action half of launch(); a desktop action is never Terminal=.
    bool launchExec(const std::string& exec);
}
