#pragma once

// THE SEARCH ON PLAIN HYPRLAND (native port P1-4/5, docs/native/OMARCHY-AUDIT.md
// A4-A11). With Integration::omarchy() the search is exactly what it always
// was: Omarchy's menu, `omarchy-launch-tui` agents, the agents plugins' usage
// files, Omarchy's default-agent file. Without it, that machinery is either
// missing or someone else's, and every row it produced did nothing when
// activated (`bash -c omarchy-system-lock` -> "command not found", silently).
// This header is the part of the replacement that has no state and no
// Hyprland in it, so scripts/native_search_test.cpp checks it on the host:
//
//   * which program a name resolves to (PATH, then ~/.local/bin -- where most
//     agent CLIs install themselves and where a display manager's PATH often
//     does not reach -- with the answer as an ABSOLUTE path, so the command
//     line we build runs the binary we checked and not whatever a terminal's
//     login shell finds first);
//   * the terminal an agent opens in: plugin:hyprdrive:search:terminal, then
//     plugin:hyprdrive:terminal, then $TERMINAL, then xdg-terminal-exec, then
//     the usual suspects -- each with ITS way of being handed a command;
//   * the leading program of a shell action, so a menu row whose program is
//     not installed is never shown (a row that does nothing is worse than no
//     row: the user pressed Enter and learned nothing);
//   * the built-in "System" column: lock, screenshots, suspend, reboot, power
//     off, each with the programs it needs.
//
// Nothing here forks: resolution is access(X_OK) over PATH's directories, the
// same thing `command -v` does, from the render thread.

#include "ShellQuote.hpp"

#include <cstdlib>
#include <functional>
#include <string>
#include <string_view>
#include <unistd.h>
#include <vector>

namespace ScrollOverview::NativeSearch {

    // ---- program lookup ------------------------------------------------------

    // name -> absolute path, or "" when it is not an executable anywhere we
    // look. A name with a '/' is taken as a path (after ~ expansion). `pathEnv`
    // and `home` are parameters so the test can point them at a scratch dir.
    inline std::string resolveIn(std::string_view name, std::string_view pathEnv, std::string_view home) {
        if (name.empty())
            return {};
        std::string n{name};
        if (n.front() == '~' && !home.empty())
            n = std::string{home} + n.substr(1);
        if (n.find('/') != std::string::npos)
            return access(n.c_str(), X_OK) == 0 ? n : std::string{};

        std::vector<std::string> dirs;
        for (size_t pos = 0; pos <= pathEnv.size();) {
            const auto SEP = pathEnv.find(':', pos);
            const auto DIR = pathEnv.substr(pos, SEP == std::string_view::npos ? std::string_view::npos : SEP - pos);
            if (!DIR.empty())
                dirs.emplace_back(DIR);
            if (SEP == std::string_view::npos)
                break;
            pos = SEP + 1;
        }
        if (!home.empty())
            dirs.push_back(std::string{home} + "/.local/bin");

        for (const auto& D : dirs) {
            const std::string FULL = D + "/" + n;
            if (access(FULL.c_str(), X_OK) == 0)
                return FULL;
        }
        return {};
    }

    inline std::string resolve(std::string_view name) {
        const char* PATH = std::getenv("PATH");
        const char* HOME = std::getenv("HOME");
        return resolveIn(name, PATH && *PATH ? PATH : "/usr/local/bin:/usr/bin:/bin", HOME ? HOME : "");
    }

    using FResolve = std::function<std::string(std::string_view)>;

    // ---- the leading program of a shell action --------------------------------

    // "FOO=1 exec setsid grim -g ..." -> "grim". Skips VAR=value words and the
    // wrappers that only run the next word. Returns "" when the first word is
    // shell syntax we do not model (a subshell, a brace group, a $VAR, a
    // builtin such as `cd` or `[[`): the caller then shows the row -- failing
    // open is the old behaviour, and it is only ever reached by a hand-written
    // user menu.
    inline std::string leadingProgram(std::string_view action) {
        size_t i = 0;
        const auto word = [&]() -> std::string {
            while (i < action.size() && (action[i] == ' ' || action[i] == '\t'))
                ++i;
            std::string w;
            char        quote = 0;
            while (i < action.size()) {
                const char C = action[i];
                if (quote) {
                    if (C == quote)
                        quote = 0;
                    else
                        w += C;
                } else if (C == '\'' || C == '"') {
                    quote = C;
                } else if (C == ' ' || C == '\t' || C == ';' || C == '|' || C == '&' || C == '\n') {
                    break;
                } else {
                    w += C;
                }
                ++i;
            }
            return w;
        };

        for (int guard = 0; guard < 16; ++guard) {
            const auto W = word();
            if (W.empty())
                return {};
            const auto EQ = W.find('=');
            if (EQ != std::string::npos && EQ > 0 && W.find('/') > EQ)
                continue; // VAR=value
            if (W == "exec" || W == "setsid" || W == "nohup" || W == "env" || W == "command" || W == "uwsm-app" || W == "--")
                continue;
            for (const char* BUILTIN : {"cd", "[[", "[", "test", "true", "false", "eval", "source", ".", "if", "for", "while", "case", "printf", "echo", "read", "export"})
                if (W == BUILTIN)
                    return {};
            if (W.front() == '(' || W.front() == '{' || W.find('$') != std::string::npos || W.find('`') != std::string::npos)
                return {};
            return W;
        }
        return {};
    }

    // Can this action run here? Unknown syntax counts as yes (see above).
    inline bool actionRunnable(std::string_view action, const FResolve& resolver) {
        const auto PROG = leadingProgram(action);
        return PROG.empty() || !resolver(PROG).empty();
    }

    // ---- terminals -----------------------------------------------------------

    // How each terminal is told "run this program": what goes between the
    // terminal and the program's own argv. Getopt-based ones (foot) would
    // otherwise eat the agent's `--permission-mode`; kitty stops at the first
    // positional on its own; xdg-terminal-exec takes the command directly.
    inline std::string_view execSeparator(std::string_view terminalBasename) {
        struct SSep {
            std::string_view term, sep;
        };
        static constexpr SSep TABLE[] = {
            {"kitty", ""},          {"xdg-terminal-exec", ""}, {"foot", "--"},          {"footclient", "--"}, {"alacritty", "-e"}, {"ghostty", "-e"},
            {"wezterm", "start --"}, {"konsole", "-e"},         {"gnome-terminal", "--"}, {"ptyxis", "--"},     {"kgx", "--"},       {"xterm", "-e"},
        };
        for (const auto& E : TABLE)
            if (E.term == terminalBasename)
                return E.sep;
        return "-e";
    }

    // The order the auto-detection tries (after the two config keys and
    // $TERMINAL): the freedesktop launcher first, then the terminals Hyprland
    // users actually have.
    inline constexpr std::string_view TERMINAL_CANDIDATES[] = {"xdg-terminal-exec", "kitty", "foot", "alacritty", "ghostty", "wezterm", "konsole", "gnome-terminal", "ptyxis"};

    struct STerminal {
        // A shell command PREFIX the agent's command line is appended to, or
        // -- when `placeholder` -- a whole command line with "{cmd}" in it.
        std::string line;
        bool        placeholder = false;
        std::string source; // "search:terminal" | "terminal" | "$TERMINAL" | "auto:<name>" | "" (none)

        bool        ok() const {
            return !line.empty();
        }

        // `cmd` is already a shell command line (quoted words).
        std::string wrap(const std::string& cmd) const {
            if (!placeholder)
                return line + " " + cmd;
            std::string out = line;
            constexpr std::string_view TOKEN = "{cmd}";
            for (size_t at = out.find(TOKEN); at != std::string::npos; at = out.find(TOKEN, at + cmd.size()))
                out.replace(at, TOKEN.size(), cmd);
            return out;
        }
    };

    // A configured terminal ("kitty", "foot --app-id x", "/opt/wez/wezterm")
    // with its separator appended -- unless the user already ended it with one
    // or wrote a "{cmd}" placeholder, in which case it is used exactly as written.
    inline STerminal terminalFrom(const std::string& configured, std::string source, const FResolve& resolver) {
        STerminal t;
        std::string v = configured;
        while (!v.empty() && (v.back() == ' ' || v.back() == '\t'))
            v.pop_back();
        while (!v.empty() && (v.front() == ' ' || v.front() == '\t'))
            v.erase(v.begin());
        if (v.empty())
            return t;

        const auto FIRST = leadingProgram(v);
        if (!FIRST.empty() && resolver(FIRST).empty())
            return t; // configured but not installed: fall through to the next source

        t.source = std::move(source);
        if (v.find("{cmd}") != std::string::npos) {
            t.line        = v;
            t.placeholder = true;
            return t;
        }
        for (std::string_view END : {" -e", " --"}) {
            if (v.size() > END.size() && std::string_view{v}.ends_with(END)) {
                t.line = v;
                return t;
            }
        }
        const auto  SLASH = FIRST.rfind('/');
        const auto  BASE  = SLASH == std::string::npos ? FIRST : FIRST.substr(SLASH + 1);
        const auto  SEP   = execSeparator(BASE);
        t.line            = SEP.empty() ? v : v + " " + std::string{SEP};
        return t;
    }

    inline STerminal chooseTerminal(const std::string& searchTerminal, const std::string& appTerminal, const std::string& envTerminal, const FResolve& resolver) {
        if (auto t = terminalFrom(searchTerminal, "search:terminal", resolver); t.ok())
            return t;
        if (auto t = terminalFrom(appTerminal, "terminal", resolver); t.ok())
            return t;
        if (auto t = terminalFrom(envTerminal, "$TERMINAL", resolver); t.ok())
            return t;
        for (const auto NAME : TERMINAL_CANDIDATES) {
            if (const auto FULL = resolver(NAME); !FULL.empty()) {
                STerminal t = terminalFrom(std::string{NAME}, "auto:" + std::string{NAME}, resolver);
                if (t.ok())
                    return t;
            }
        }
        return {};
    }

    // ---- the built-in "System" column ----------------------------------------

    struct SSystemRow {
        std::string_view         id;
        std::string_view         label;
        std::string_view         icon;        // icon-theme name
        std::string_view         description;
        std::string_view         action;      // a `bash -c` line
        std::vector<std::string> needs;       // every program must resolve
        std::vector<std::string> aliases;
    };

    // The screenshot lands in XDG_PICTURES_DIR (or ~/Pictures), and on the
    // clipboard too when wl-copy is there. The full-screen one waits for the
    // overview's close animation (~0.2 s) or it photographs the overview.
    inline const std::vector<SSystemRow>& systemRows() {
        static const std::vector<SSystemRow> ROWS = {
            {"system.lock", "Lock Screen", "system-lock-screen", "loginctl lock-session", "loginctl lock-session", {"loginctl"}, {"lock"}},
            {"system.screenshot-region", "Screenshot Region", "applets-screenshooter", "Select an area with slurp, save with grim",
             "d=\"$(xdg-user-dir PICTURES 2>/dev/null || echo \"$HOME/Pictures\")\"; mkdir -p \"$d\"; f=\"$d/screenshot-$(date +%Y%m%d-%H%M%S).png\"; "
             "g=\"$(slurp)\" || exit 0; grim -g \"$g\" \"$f\" && { command -v wl-copy >/dev/null && wl-copy < \"$f\"; "
             "command -v notify-send >/dev/null && notify-send -i \"$f\" 'Screenshot saved' \"$f\"; }",
             {"grim", "slurp"}, {"capture", "screen shot", "print"}},
            {"system.screenshot", "Screenshot Screen", "applets-screenshooter", "Every output, saved with grim",
             "d=\"$(xdg-user-dir PICTURES 2>/dev/null || echo \"$HOME/Pictures\")\"; sleep 0.4; mkdir -p \"$d\"; f=\"$d/screenshot-$(date +%Y%m%d-%H%M%S).png\"; "
             "grim \"$f\" && { command -v wl-copy >/dev/null && wl-copy < \"$f\"; command -v notify-send >/dev/null && notify-send -i \"$f\" 'Screenshot saved' \"$f\"; }",
             {"grim"}, {"capture", "screen shot", "print"}},
            {"system.suspend", "Suspend", "system-suspend", "systemctl suspend", "systemctl suspend", {"systemctl"}, {"sleep"}},
            {"system.reboot", "Restart", "system-reboot", "systemctl reboot", "systemctl reboot", {"systemctl"}, {"reboot"}},
            {"system.poweroff", "Shut Down", "system-shutdown", "systemctl poweroff", "systemctl poweroff", {"systemctl"}, {"power off", "poweroff"}},
        };
        return ROWS;
    }

    inline bool requirementsMet(const std::vector<std::string>& needs, const FResolve& resolver) {
        for (const auto& R : needs)
            if (resolver(R).empty())
                return false;
        return true;
    }

    // ---- where Hyprdrive keeps its own search state ---------------------------

    // ${XDG_CONFIG_HOME:-~/.config}/hyprdrive/<leaf>, or "" with no HOME.
    inline std::string configPath(std::string_view leaf) {
        if (const char* X = std::getenv("XDG_CONFIG_HOME"); X && *X)
            return std::string{X} + "/hyprdrive/" + std::string{leaf};
        const char* HOME = std::getenv("HOME");
        return HOME && *HOME ? std::string{HOME} + "/.config/hyprdrive/" + std::string{leaf} : std::string{};
    }
}
