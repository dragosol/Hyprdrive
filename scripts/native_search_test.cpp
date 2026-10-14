// Host test for NativeSearch.hpp (native port A5/A7): the leading-program
// parse every off-Omarchy menu row is filtered on, and the terminal choice
// every off-Omarchy agent row is launched through. The resolver is a stand-in
// table, so this is about the rules, not about what fedora has installed;
// omarchy_search_test.cpp covers the same paths end to end with real stubs.
#include "../NativeSearch.hpp"

#include <cstdio>
#include <map>
#include <string>

using namespace ScrollOverview::NativeSearch;

static int g_checks = 0, g_failed = 0;
#define CHECK(c)                                                                                                                                                                   \
    do {                                                                                                                                                                           \
        ++g_checks;                                                                                                                                                                \
        if (!(c)) {                                                                                                                                                                \
            ++g_failed;                                                                                                                                                            \
            std::printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c);                                                                                                               \
        }                                                                                                                                                                          \
    } while (0)

int main() {
    // ---- leadingProgram
    CHECK(leadingProgram("loginctl lock-session") == "loginctl");
    CHECK(leadingProgram("  FOO=1 BAR='a b' exec setsid grim -g x") == "grim");
    CHECK(leadingProgram("omarchy-launch-walker --x; echo") == "omarchy-launch-walker");
    CHECK(leadingProgram("'/opt/my tools/run' --go") == "/opt/my tools/run");
    CHECK(leadingProgram("uwsm-app -- foot") == "foot");
    CHECK(leadingProgram("env LANG=C kitty") == "kitty");
    CHECK(leadingProgram("$EDITOR file").empty());
    CHECK(leadingProgram("(cd /tmp && ls)").empty());
    CHECK(leadingProgram("cd ~ && make").empty());
    CHECK(leadingProgram("[[ -f x ]] && y").empty());
    CHECK(leadingProgram("").empty());
    CHECK(leadingProgram("PATH=/x/y:/z").empty()); // only an assignment

    std::map<std::string, std::string> have = {
        {"kitty", "/usr/bin/kitty"}, {"foot", "/usr/bin/foot"}, {"ghostty", "/usr/bin/ghostty"}, {"myterm", "/opt/myterm"}, {"grim", "/usr/bin/grim"},
    };
    const FResolve R = [&](std::string_view n) {
        const auto IT = have.find(std::string{n});
        return IT == have.end() ? std::string{} : IT->second;
    };

    CHECK(actionRunnable("grim -g x", R));
    CHECK(!actionRunnable("omarchy-system-lock", R));
    CHECK(actionRunnable("cd ~ && whatever", R)); // syntax we do not model: shown
    CHECK(requirementsMet({"grim"}, R));
    CHECK(!requirementsMet({"grim", "slurp"}, R));

    // ---- terminals
    // search:terminal wins; a bare name gets its own separator.
    auto t = chooseTerminal("foot", "kitty", "ghostty", R);
    CHECK(t.ok() && t.line == "foot --" && t.source == "search:terminal");
    CHECK(t.wrap("'/bin/claude' -- 'x'") == "foot -- '/bin/claude' -- 'x'");
    // {cmd} is used verbatim.
    t = chooseTerminal("myterm --hold -x {cmd} --tail", "", "", R);
    CHECK(t.placeholder && t.wrap("a 'b'") == "myterm --hold -x a 'b' --tail");
    // A configured terminal that is not installed falls through.
    t = chooseTerminal("wezterm", "", "ghostty", R);
    CHECK(t.line == "ghostty -e" && t.source == "$TERMINAL");
    // plugin:hyprdrive:terminal before $TERMINAL; a user-given -e is not doubled.
    t = chooseTerminal("", "ghostty -e", "foot", R);
    CHECK(t.line == "ghostty -e" && t.source == "terminal");
    // kitty takes the program as plain positionals.
    t = chooseTerminal("", "", "kitty", R);
    CHECK(t.line == "kitty");
    // An unknown terminal gets the common -e.
    have["zterm"] = "/usr/bin/zterm";
    t = chooseTerminal("zterm", "", "", R);
    CHECK(t.line == "zterm -e");
    // Detection order: xdg-terminal-exec first, then kitty...
    t = chooseTerminal("", "", "", R);
    CHECK(t.line == "kitty" && t.source == "auto:kitty");
    have["xdg-terminal-exec"] = "/usr/bin/xdg-terminal-exec";
    t = chooseTerminal("", "", "", R);
    CHECK(t.line == "xdg-terminal-exec");
    // Nothing at all: not ok, and every agent row is then hidden.
    have.clear();
    CHECK(!chooseTerminal("", "", "", R).ok());

    // ---- the System rows: every one names what it needs, none is Omarchy's
    for (const auto& ROW : systemRows()) {
        CHECK(!ROW.needs.empty());
        CHECK(std::string_view{ROW.action}.find("omarchy") == std::string_view::npos);
        CHECK(!ROW.icon.empty() && !ROW.label.empty());
    }

    std::printf("%d/%d checks passed\n", g_checks - g_failed, g_checks);
    return g_failed == 0 ? 0 : 1;
}
