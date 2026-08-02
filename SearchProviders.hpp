#pragma once

#include <cstdint>
#include <string>
#include <vector>

// OVERVIEW_CPP_SPEC §13.7 X19. The GNOME half of the search: an
// org.gnome.Shell.SearchProvider2 client, so an app that ships a provider is
// searchable without a line of code here.
//
// ASYNC BY CONSTRUCTION. org.gnome.Weather is installed in the test VM and
// activates but never replies -- 28 s to the D-Bus default timeout. A blocking
// client freezes the overview on the first keystroke, so every call lives on a
// worker thread with its own reply deadline and the render thread only ever
// takes a snapshot. See share/X19_PROBE_searchprovider2.md.
namespace SearchProviders {
    struct SProvider {
        std::string desktopId;  // DesktopId= minus .desktop
        std::string busName;    // BusName=
        std::string objectPath; // ObjectPath=
        int         version = 2;
    };

    struct SResult {
        std::string providerBus;
        std::string providerDesktopId;
        std::string id;
        std::string name;
        std::string description;
        std::string icon;          // icon NAME or absolute path; feed to AppSearch::resolveIconPath
        std::string clipboardText; // Calculator returns the bare answer here
        size_t      providerRank = 0;
    };

    // Scans both search-providers dirs on first call.
    const std::vector<SProvider>& providers();
    void                          refresh();

    // Called from the render/input thread on every keystroke. Non-blocking:
    // starts a new generation, abandons whatever the previous one had in
    // flight, returns immediately. Empty query clears.
    void query(const std::string& text);

    // Snapshot of whatever has answered so far for the newest query, ordered by
    // provider then by the provider's own ranking. Safe to call every frame.
    std::vector<SResult> results();

    // Generation counter of the results above. Bumps when a query starts and
    // again whenever late replies land, so the render layer can skip relayout
    // on an unchanged set.
    uint64_t revision();

    // ActivateResult on the owning provider. Detached, like AppSearch::launch.
    void activate(const SResult& result, const std::string& queryText);

    // Hand the whole query to the provider's own app (GNOME's "show all").
    void launchSearch(const SProvider& provider, const std::string& queryText);

    // Stops the worker. Idempotent; safe if never started.
    void shutdown();
}
