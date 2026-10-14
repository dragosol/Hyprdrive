#pragma once

#include <cstdint>
#include <string>
#include <vector>
#include <optional>
#include <functional>

namespace OmarchySearch {

enum class EItemKind : uint8_t {
    App,
    Action,      // Omarchy menu action / toggle / command
    Menu,        // Omarchy submenu (drills down into route)
    Back,        // Back to parent menu
    Agent,       // AI Coding Agent chat launcher (/grok, /agy, etc.)
    Calculator,  // Instant arithmetic calculation
    File,        // File search result
    Provider,    // D-Bus search provider
};

struct SSearchItem {
    EItemKind   kind = EItemKind::Action;
    std::string id;
    std::string name;
    std::string description;
    std::string icon;
    std::string iconFont;     // nerd-font family for menu glyphs; empty = JetBrainsMono Nerd Font
    std::string category;     // "Apps", "Omarchy Menu", "AI Agent", "Calculator", "Files", "Settings"
    std::string actionCommand;// shell command or executable
    std::string filePath;     // absolute path for files
    uint64_t    fileSizeBytes = 0;
    std::string fileSizeStr;
    std::string fileModifiedStr;
    std::string fileTypeStr;  // e.g. "PDF Document", "C++ Source", "PNG Image"
    bool        canQuickLook = false;
};

// Lifecycle
void init();
void shutdown();

// WHAT THIS FILE ASKS THE PLUGIN (native port, docs/native/OMARCHY-AUDIT.md
// A4-A11). OmarchySearch.cpp is linked into a host test with no Hyprland in it,
// so it cannot call Integration or Config itself: main.cpp hands it these at
// PLUGIN_INIT, and the test hands it its own. Every one may be null.
//
//   omarchy           Integration::omarchy(). Null = true: the behaviour this
//                     file had before the port, for any caller that never set it.
//   terminalTemplate  plugin:hyprdrive:search:terminal -- the terminal an agent
//                     opens in off Omarchy ("" = detect, NativeSearch.hpp).
//   appTerminal       plugin:hyprdrive:terminal, the Terminal=true one; the
//                     detection's second choice.
//
// With omarchy() true NOTHING below changes: the menu is Omarchy's, agents run
// through omarchy-launch-tui, readiness is the agents plugins' usage files and
// the default agent is Omarchy's file (now also mirrored to Hyprdrive's own).
// With it false: a "System" column with native commands plus the user's
// ~/.config/hyprdrive/menu.jsonc, agents in a real terminal when their binary
// is on PATH, embedded agent icons, and ~/.config/hyprdrive/default-agent.
struct SHost {
    bool (*omarchy)()                 = nullptr;
    std::string (*terminalTemplate)() = nullptr;
    std::string (*appTerminal)()      = nullptr;
};
void setHost(const SHost& host);

// "Omarchy Menu" or "System": column 0's title at the menu root.
std::string menuRootTitle();

// Forget every cached "is this program installed?" answer now rather than at
// the end of its few-second window (OmarchySearch.cpp, resolveCached). For
// tests that change PATH, and harmless anywhere else.
void invalidateProgramLookups();

// Keystroke query across all Omarchy providers
void query(const std::string& text);

// Provider queries
bool isAgentQuery(const std::string& query);
std::vector<SSearchItem> searchAgents(const std::string& query);
// Logged-in agents only, with the typed sentence as the prompt.
std::vector<SSearchItem> promptAllAgents(const std::string& prompt);
bool                     isGlyphIcon(const std::string& icon);
std::vector<SSearchItem> agentHelpItems();

// THE DEFAULT CODING AGENT. Its rows lead the AI & Tools column; Ctrl x2 over
// an agent row sets it (overviewHandleCtrlTap).
//   On Omarchy it is OMARCHY'S -- the one `omarchy agent` launches, in
//   ~/.config/omarchy/defaults/agent. Search reads that file, so the overview,
//   the Omarchy menu's checkmark and `omarchy agent` can never disagree; a
//   Ctrl x2 writes it AND mirrors the choice into Hyprdrive's own file.
//   Off Omarchy it is Hyprdrive's own: ${XDG_CONFIG_HOME:-~/.config}/hyprdrive/
//   default-agent, one line, the agent's prefix ("claude", "agy"...). Omarchy's
//   directory is never created there.
bool canBeDefaultAgent(const SSearchItem& item);
bool isDefaultAgent(const SSearchItem& item);
bool setDefaultAgent(const SSearchItem& item);
std::optional<SSearchItem> evaluateCalculator(const std::string& query);
std::vector<SSearchItem> searchMenu(const std::string& query, size_t limit = 10);
std::vector<SSearchItem> fileResults();
bool fileSearchBusy();

// EVERYTHING THE ROW BUILDER READS THAT IS NOT THE QUERY, as one number.
//
// Building a row set costs a scored sort of the whole app inventory, two
// stat()s for the menu, a stat() and two fs::exists per agent and a copy of the
// file results under a mutex -- and the overview asks for it on every monitor
// on every frame while a query is up, for an answer that changes only when one
// of those files does. This is the key a caller memoises on.
//
// The filesystem half is re-read at most every 250ms, which is also the ceiling
// on how long a `omarchy default agent ...` run in a terminal (or a Ctrl x2 in
// the search field) takes to show up. The file-search worker's own generation
// is folded in unpolled, so an async result lands on the next frame.
uint64_t searchInputsGeneration();
void setResultsCallback(std::function<void()> cb);

// Menu hierarchy navigation
void navigateMenu(const std::string& routeId);
bool navigateMenuBack();
bool canNavigateMenuBack();
std::string menuCurrentRoute();
std::string menuCurrentRouteTitle();
void resetMenuRoute();

// Activate an item (runs command, launches agent, copies calc, or opens file)
bool activate(const SSearchItem& item);

// Quick Look (Sushi) state and actions
bool isSushiActive();
void toggleSushi(const std::string& filePath);
void closeSushi();
void updateSushiIfActive(const std::string& filePath);
bool isOverviewSushiWindow(const std::string& windowClass, uint32_t pid = 0);
std::vector<SSearchItem> recentFiles();

} // namespace OmarchySearch
