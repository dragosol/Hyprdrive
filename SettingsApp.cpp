// See SettingsApp.hpp.
#include "SettingsApp.hpp"

#include "Compat.hpp"
#include "Config.hpp"
#include "Integration.hpp"
#include "Launch.hpp"
#include "globals.hpp"

#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprutils/os/Process.hpp>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <format>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace ScrollOverview::SettingsApp {
    namespace {
        SP<SHyprCtlCommand> g_hyprctl;

        bool executable(const std::string& path) {
            struct stat st {};
            return stat(path.c_str(), &st) == 0 && S_ISREG(st.st_mode) && access(path.c_str(), X_OK) == 0;
        }

        // Qt reads #AARRGGBB; the channels are clamped because a theme colour
        // can arrive slightly out of range from a mix.
        std::string qtColor(const CHyprColor& c) {
            const auto BYTE = [](double v) { return sc<int>(std::lround(std::clamp(v, 0.0, 1.0) * 255.0)); };
            return std::format("#{:02x}{:02x}{:02x}{:02x}", BYTE(c.a), BYTE(c.r), BYTE(c.g), BYTE(c.b));
        }

        std::string jsonEscape(std::string_view s) {
            std::string out;
            out.reserve(s.size() + 2);
            for (const char ch : s) {
                switch (ch) {
                    case '"': out += "\\\""; break;
                    case '\\': out += "\\\\"; break;
                    case '\n': out += "\\n"; break;
                    case '\t': out += "\\t"; break;
                    default:
                        if (sc<unsigned char>(ch) < 0x20)
                            out += std::format("\\u{:04x}", sc<int>(ch));
                        else
                            out += ch;
                }
            }
            return out;
        }

        // The palette the app is drawn in: the dock's plate as the window, the
        // overview's text colours on it. The plate's alpha is the dock's frost
        // opacity; the app is an opaque window and composites it over its own
        // base, so it is passed through rather than forced to 1.
        std::string themeReply(eHyprCtlOutputFormat format) {
            const auto        BG     = Config::dockBackgroundColor();
            const auto        FG     = Config::themeForeground();
            const auto        MUTED  = Config::themeMutedText();
            const auto        ACCENT = Config::themeAccent();
            const auto        ON_ACC = Config::highlightForeground();
            const auto        SEL    = Config::themeSelection();
            const auto        URGENT = Config::themeUrgent();
            const std::string FONT   = Config::themeFontFamily();
            const int         ROUND  = Config::themeRounding();
            const bool        LIGHT  = Config::isLightTheme();
            if (format == FORMAT_JSON)
                return std::format(R"({{"background": "{}", "foreground": "{}", "muted": "{}", "accent": "{}", "accentText": "{}", "selection": "{}", "urgent": "{}", )"
                                   R"("font": "{}", "rounding": {}, "light": {}, "integration": "{}"}})",
                                   qtColor(BG), qtColor(FG), qtColor(MUTED), qtColor(ACCENT), qtColor(ON_ACC), qtColor(SEL), qtColor(URGENT), jsonEscape(FONT), ROUND,
                                   LIGHT ? "true" : "false", Integration::omarchy() ? "omarchy" : "none");
            return std::format("background: {}\nforeground: {}\nmuted: {}\naccent: {}\naccentText: {}\nselection: {}\nurgent: {}\nfont: {}\nrounding: {}\nlight: {}\n",
                               qtColor(BG), qtColor(FG), qtColor(MUTED), qtColor(ACCENT), qtColor(ON_ACC), qtColor(SEL), qtColor(URGENT), FONT, ROUND,
                               LIGHT ? "true" : "false");
        }

        // The Omarchy shell's IPC for the dragos.hyprdrive panel (Panel.qml's
        // IpcHandler), for an Omarchy install, which has no standalone app to
        // fall back to. `qs ipc call` exits non-zero when no Omarchy shell
        // answers (or it has no such panel); that is said in a notification
        // instead of an "ok" that opened nothing. The arguments are sh's "$@",
        // never part of the script: an app id is one argument whatever is in it.
        bool omarchyCall(std::vector<std::string> args) {
            static constexpr const char* SCRIPT =
                R"(/usr/bin/qs -p /usr/share/omarchy/shell ipc call dragos.hyprdrive "$@" >/dev/null 2>&1 ||)"
                R"( exec hyprctl notify 3 8000 0 "Hyprdrive settings: the Omarchy shell did not answer, so its settings panel could not open")";
            args.insert(args.begin(), {"-c", SCRIPT, "hyprdrive-settings"});
            Hyprutils::OS::CProcess("/bin/sh", args).runAsync();
            return true;
        }

        bool nativeCall(std::vector<std::string> args) {
            std::string bin = launcher();
            if (bin.empty())
                return false;
            // Its own app scope under uwsm, like every other app hyprdrive starts
            // (Launch.hpp) -- the settings window is an app, not the compositor.
            Launch::wrap(bin, args);
            Hyprutils::OS::CProcess(bin, args).runAsync();
            return true;
        }
    }

    std::string launcher() {
        const char* PATH = std::getenv("PATH");
        std::string_view rest{PATH && *PATH ? PATH : "/usr/local/bin:/usr/bin:/bin"};
        while (true) {
            const auto       COLON = rest.find(':');
            std::string_view dir   = rest.substr(0, COLON);
            if (!dir.empty()) {
                const std::string CAND = std::string{dir} + "/hyprdrive-settings";
                if (executable(CAND))
                    return CAND;
            }
            if (COLON == std::string_view::npos)
                break;
            rest.remove_prefix(COLON + 1);
        }
        if (const char* HOME = std::getenv("HOME"); HOME && *HOME) {
            const std::string LOCAL = std::string{HOME} + "/.local/bin/hyprdrive-settings";
            if (executable(LOCAL))
                return LOCAL;
        }
        return {};
    }

    // ON OMARCHY the launcher, when it is installed, is still the way in: it
    // hands over to the panel and opens the standalone app itself when the
    // panel does not answer (hyprdrive-settings, "ON OMARCHY"). Only without
    // it is the panel called directly.
    static bool viaPanelOnly() {
        return Integration::omarchy() && launcher().empty();
    }

    bool available() {
        if (Integration::omarchy())
            return true;
        // The dock's info menu asks while it lays itself out, which can be every
        // frame it is open: the PATH walk is remembered for two seconds, so an
        // install made while the menu is up shows on its next opening.
        static auto checkedAt = std::chrono::steady_clock::time_point{};
        static bool found     = false;
        const auto  NOW       = std::chrono::steady_clock::now();
        if (checkedAt == std::chrono::steady_clock::time_point{} || NOW - checkedAt > std::chrono::seconds(2)) {
            checkedAt = NOW;
            found     = !launcher().empty();
        }
        return found;
    }

    bool open(std::string_view pane, std::string_view iconApp) {
        if (viaPanelOnly()) {
            // The panel has no "open on section" call; Icons-with-an-app is the
            // one deep link it knows (Panel.qml `icons`).
            if (!iconApp.empty())
                return omarchyCall({"icons", std::string{iconApp}});
            return omarchyCall({"open"});
        }
        if (!iconApp.empty())
            return nativeCall({"--icons", std::string{iconApp}});
        if (!pane.empty())
            return nativeCall({"--pane", std::string{pane}});
        return nativeCall({});
    }

    SDispatchResult dispatch(std::string arg) {
        // The argument was already matched against Config.cpp's pattern
        // (open|toggle|close|pane <id>|icons <id>) for Lua; a hyprlang
        // `hyprdrive:settings` dispatch arrives unchecked, so this stays strict.
        if (arg.empty())
            arg = "open";
        bool ok = false;
        if (arg == "open")
            ok = open();
        else if (arg == "toggle" || arg == "close") {
            if (viaPanelOnly())
                ok = omarchyCall({arg});
            else
                ok = nativeCall({"--" + arg});
        } else if (arg.starts_with("pane ") && arg.size() > 5)
            ok = open(std::string_view{arg}.substr(5), {});
        else if (arg.starts_with("icons ") && arg.size() > 6)
            ok = open({}, std::string_view{arg}.substr(6));
        else
            return {.success = false, .error = "settings: expected open, toggle, close, pane <section> or icons <desktop-id>"};
        if (!ok)
            return {.success = false, .error = "settings: hyprdrive-settings is not installed (make install puts it in $PREFIX/bin)"};
        return {};
    }

    void init() {
        g_hyprctl = HyprlandAPI::registerHyprCtlCommand(SCROLLOVERVIEW_HANDLE, SHyprCtlCommand{
                                                                                   .name  = "hyprdrive-theme",
                                                                                   .exact = true,
                                                                                   .fn    = [](eHyprCtlOutputFormat format, std::string) -> std::string {
                                                                                       return themeReply(format);
                                                                                   },
                                                                               });
    }

    void shutdown() {
        if (g_hyprctl)
            HyprlandAPI::unregisterHyprCtlCommand(SCROLLOVERVIEW_HANDLE, g_hyprctl);
        g_hyprctl.reset();
    }
}
