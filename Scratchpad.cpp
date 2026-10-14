#include "Scratchpad.hpp"

#include "AppSearch.hpp"
#include "BuiltinIcons.hpp"
#include "Minimize.hpp"

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iterator>

#include <dlfcn.h>
#include <string_view>

#define private public
#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/desktop/state/GlobalWindowController.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/state/WorkspaceState.hpp>
#undef private

namespace ScrollOverview::Scratchpad {

bool isScratchpad(const PHLWORKSPACE& workspace) {
    return workspace && workspace->m_isSpecialWorkspace && !Minimize::isStash(workspace);
}

std::vector<PHLWORKSPACE> workspaces() {
    std::vector<PHLWORKSPACE> out;

    for (const auto& ref : State::workspaceState()->workspaces()) {
        if (const auto WORKSPACE = ref.lock(); isScratchpad(WORKSPACE))
            out.emplace_back(WORKSPACE);
    }

    return out;
}

std::vector<PHLWINDOW> windowsOn(const PHLWORKSPACE& workspace) {
    std::vector<PHLWINDOW> out;
    if (!workspace)
        return out;

    for (const auto& WINDOW : Desktop::windowState()->windows()) {
        if (WINDOW && WINDOW->m_isMapped && WINDOW->m_workspace == workspace)
            out.emplace_back(WINDOW);
    }

    return out;
}

std::vector<PHLWORKSPACE> populated() {
    auto out = workspaces();
    std::erase_if(out, [](const auto& workspace) { return windowsOn(workspace).empty(); });
    return out;
}

PHLWORKSPACE shownOn(const PHLMONITOR& monitor) {
    if (!monitor)
        return nullptr;

    const auto SPECIAL = monitor->m_activeSpecialWorkspace;
    return isScratchpad(SPECIAL) ? SPECIAL : nullptr;
}

PHLWORKSPACE byShortName(const std::string& shortName_) {
    for (const auto& WORKSPACE : workspaces()) {
        if (shortName(WORKSPACE) == shortName_)
            return WORKSPACE;
    }

    return nullptr;
}

PHLWORKSPACE workspaceFor(const PHLWINDOW& window) {
    if (!window)
        return nullptr;

    const auto WORKSPACE = window->m_workspace;
    return isScratchpad(WORKSPACE) ? WORKSPACE : nullptr;
}

bool holdsWindow(const PHLWINDOW& window) {
    return !!workspaceFor(window);
}

std::string shortName(const PHLWORKSPACE& workspace) {
    if (!workspace)
        return "";

    constexpr std::string_view PREFIX = "special:";
    const std::string&         NAME   = workspace->m_name;

    return NAME.starts_with(PREFIX) ? NAME.substr(PREFIX.size()) : NAME;
}

std::string label(const PHLWORKSPACE& workspace) {
    auto name = shortName(workspace);
    if (name.empty() || name == "special")
        return "Scratchpad";

    // Title case, like every other label the dock shows -- user, 2026-09-12.
    // The workspace's own name is a config token ("scratchpad"); this is the
    // only place it is shown to a person, so it is capitalised here and the
    // token itself is left alone for the dispatchers that take it.
    name[0] = sc<char>(std::toupper(sc<unsigned char>(name[0])));
    return name;
}

std::string iconName() {
    // THE GLYPH SHIPS WITH THE PLUGIN: a single up chevron, the user's pick
    // (2026-09-12, after trying double chevrons at two weights). It says
    // "summon", which is what pulling the scratchpad up over a desktop is. The
    // stroke sits deliberately between the theme's two single chevrons --
    // lighter than Adwaita's go-up-symbolic, heavier than Yaru's hairline
    // pan-up-large -- so no installed theme icon matched it.
    //
    // `make install` puts it beside hyprdrive.so, and it is found from the .so's
    // OWN load path rather than a hardcoded prefix, so it follows the plugin
    // wherever it is installed. resolveIconPath takes an absolute path as-is.
    static const std::string BUNDLED = [] {
        static const char ANCHOR = 0;
        Dl_info           info{};
        if (!dladdr(&ANCHOR, &info) || !info.dli_fname)
            return std::string{};

        std::error_code ec;
        const auto      PATH = std::filesystem::path(info.dli_fname).parent_path() / "scratchpad-symbolic.svg";
        return std::filesystem::exists(PATH, ec) ? PATH.string() : std::string{};
    }();

    if (!BUNDLED.empty())
        return BUNDLED;

    // NO SIDE FILE: a hyprpm install builds the .so in a temp checkout and
    // copies only the .so. The chevron is embedded (BuiltinIcons::SCRATCHPAD),
    // and written ONCE to $XDG_CACHE_HOME/hyprdrive/ so the dock draws it down
    // the very same path as the side file -- a FILE, tinted white like every
    // symbolic dock icon. Handing the dock the builtin name instead would take
    // OverviewRender's builtin path, which neither tints nor pads. Rewritten
    // only when the bytes differ, so an updated plugin brings its own glyph.
    static const std::string MATERIALISED = [] {
        const auto SVG = BuiltinIcons::svg(BuiltinIcons::SCRATCHPAD, "#000000");
        if (SVG.empty())
            return std::string{};
        const char* const CACHE = std::getenv("XDG_CACHE_HOME");
        const char* const HOME  = std::getenv("HOME");
        const std::filesystem::path DIR = (CACHE && *CACHE) ? std::filesystem::path(CACHE) / "hyprdrive" :
            (HOME && *HOME)                                 ? std::filesystem::path(HOME) / ".cache/hyprdrive" :
                                                              std::filesystem::path{};
        if (DIR.empty())
            return std::string{};
        const auto      PATH = DIR / "scratchpad-symbolic.svg";
        std::error_code ec;
        std::filesystem::create_directories(DIR, ec);
        {
            std::ifstream in(PATH, std::ios::binary);
            const std::string HAVE{std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>()};
            if (HAVE == SVG)
                return PATH.string();
        }
        const auto TMP = PATH.string() + ".tmp";
        {
            std::ofstream out(TMP, std::ios::binary | std::ios::trunc);
            out << SVG;
            if (!out)
                return std::string{};
        }
        std::filesystem::rename(TMP, PATH, ec);
        return ec ? std::string{} : PATH.string();
    }();

    if (!MATERIALISED.empty())
        return MATERIALISED;

    // Last resort (no writable cache dir either):
    // resolved against the live theme rather than hardcoded, since a user on
    // another icon theme may carry none of these, and a dock slot whose icon
    // does not resolve is a blank square.
    for (const char* NAME : {"focus-windows-symbolic", "window-restore-symbolic", "view-app-grid-symbolic", "applications-other"}) {
        if (!AppSearch::resolveIconPath(NAME).empty())
            return NAME;
    }

    return "applications-other";
}

PHLWORKSPACE ensureDefault(const PHLMONITOR& monitor) {
    // Whatever the user already has comes first -- creating a second
    // `special:scratchpad` beside their own would split the shelf in two.
    if (const auto SHOWN = shownOn(monitor))
        return SHOWN;

    const auto POPULATED = populated();
    if (!POPULATED.empty())
        return POPULATED.front();

    const auto ALL = workspaces();
    if (!ALL.empty())
        return ALL.front();

    if (!monitor)
        return nullptr;

    // Same creation Minimize uses for its stash, and the same name Omarchy's own
    // SUPER+grave binding toggles, so a window parked here lands where the
    // keybinding will look for it.
    return State::workspaceState()->create(State::workspaceState()->newSpecialID(), monitor->m_id, "special:scratchpad");
}

void show(const PHLWORKSPACE& workspace) {
    if (!isScratchpad(workspace))
        return;

    // ITS OWN monitor, not the focused one: Hyprland parks a special workspace
    // on a monitor, and pulling it up somewhere else MOVES it there.
    if (const auto MONITOR = workspace->m_monitor.lock(); MONITOR)
        MONITOR->setSpecialWorkspace(workspace);
}

void hide(const PHLWORKSPACE& workspace) {
    if (!workspace)
        return;

    if (const auto MONITOR = workspace->m_monitor.lock(); MONITOR && MONITOR->m_activeSpecialWorkspace == workspace)
        MONITOR->setSpecialWorkspace(PHLWORKSPACE{});
}

void toggle(const PHLWORKSPACE& workspace) {
    if (!isScratchpad(workspace))
        return;

    const auto MONITOR = workspace->m_monitor.lock();
    if (MONITOR && MONITOR->m_activeSpecialWorkspace == workspace)
        hide(workspace);
    else
        show(workspace);
}

void moveWindowTo(const PHLWINDOW& window, const PHLWORKSPACE& workspace) {
    if (!window || !isScratchpad(workspace) || window->m_workspace == workspace)
        return;

    // A stashed window comes off the stash FIRST, or Minimize goes on believing
    // it owns it and a later restore would pull it back out of the scratchpad
    // onto a normal desktop -- silently emptying the shelf the user just filled.
    if (Minimize::isMinimized(window))
        Minimize::restore(window);

    Desktop::globalWindowController()->moveWindowToWorkspace(window, workspace);
}

}
