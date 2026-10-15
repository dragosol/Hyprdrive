#include "../OmarchySearch.hpp"
#include "../SearchIntent.hpp"
#include <cassert>
#include <chrono>
#include <iostream>
#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <algorithm>
#include <vector>

static int s_testsPassed = 0;

#define CHECK(cond) do { \
    if (!(cond)) { \
        std::cerr << "Assertion failed at line " << __LINE__ << ": " << #cond << std::endl; \
        std::exit(1); \
    } \
    s_testsPassed++; \
} while (0)

int main() {
    // 1. Calculator tests
    {
        auto calc1 = OmarchySearch::evaluateCalculator("2 + 2");
        CHECK(calc1.has_value());
        CHECK(calc1->name == "= 4");
        CHECK(calc1->actionCommand == "4");
        CHECK(calc1->category == "Calculator");

        auto calc2 = OmarchySearch::evaluateCalculator("10 * 5 - 3");
        CHECK(calc2.has_value());
        CHECK(calc2->name == "= 47");
        CHECK(calc2->actionCommand == "47");

        auto calc3 = OmarchySearch::evaluateCalculator("(10 + 20) / 3");
        CHECK(calc3.has_value());
        CHECK(calc3->name == "= 10");
        CHECK(calc3->actionCommand == "10");

        auto calc4 = OmarchySearch::evaluateCalculator("2^3");
        CHECK(calc4.has_value());
        CHECK(calc4->name == "= 8");
        CHECK(calc4->actionCommand == "8");

        auto calc5 = OmarchySearch::evaluateCalculator("sqrt(16)");
        CHECK(calc5.has_value());
        CHECK(calc5->name == "= 4");
        CHECK(calc5->actionCommand == "4");

        auto calc6 = OmarchySearch::evaluateCalculator("sin(0)");
        CHECK(calc6.has_value());
        CHECK(calc6->name == "= 0");
        CHECK(calc6->actionCommand == "0");

        // Non-math queries should return nullopt
        auto calcNone1 = OmarchySearch::evaluateCalculator("hello world");
        CHECK(!calcNone1.has_value());

        auto calcNone2 = OmarchySearch::evaluateCalculator("firefox");
        CHECK(!calcNone2.has_value());

        // Bare number without operator should return nullopt
        auto calcNone3 = OmarchySearch::evaluateCalculator("42");
        CHECK(!calcNone3.has_value());

        // Division by zero should not crash
        auto calcDivZero = OmarchySearch::evaluateCalculator("10 / 0");
        if (calcDivZero.has_value()) {
            CHECK(calcDivZero->name.find("Error") != std::string::npos || calcDivZero->name.find("inf") != std::string::npos);
        }
    }

    // 2. AI Agent queries
    {
        CHECK(OmarchySearch::isAgentQuery("/grok what is the weather today"));
        CHECK(OmarchySearch::isAgentQuery("/agy fix the build"));
        CHECK(OmarchySearch::isAgentQuery("/gemini help me"));
        CHECK(OmarchySearch::isAgentQuery("/claude review"));
        CHECK(OmarchySearch::isAgentQuery("/opencode"));
        CHECK(OmarchySearch::isAgentQuery("/codex"));
        CHECK(OmarchySearch::isAgentQuery("/copilot"));
        CHECK(!OmarchySearch::isAgentQuery("grok what is the weather"));
        CHECK(!OmarchySearch::isAgentQuery("firefox"));

        auto grokResults = OmarchySearch::searchAgents("/grok what is the weather today");
        CHECK(!grokResults.empty());
        CHECK(grokResults.front().name.find("Grok") != std::string::npos);
        CHECK(grokResults.front().category == "AI Agent");
        CHECK(grokResults.front().actionCommand.find("what is the weather today") != std::string::npos);

        auto agyResults = OmarchySearch::searchAgents("/agy solve this problem");
        CHECK(!agyResults.empty());
        CHECK(agyResults.front().name.find("AGY") != std::string::npos || agyResults.front().name.find("Antigravity") != std::string::npos);
        CHECK(agyResults.front().category == "AI Agent");
        CHECK(agyResults.front().actionCommand.find("solve this problem") != std::string::npos);

        auto all = OmarchySearch::promptAllAgents("what is the weather today");
        // Sentence queries only list agents that are installed and logged in
        // (usage record with ready:true), not the full catalog.
        CHECK(all.size() < 8);
        for (const auto& it : all) {
            CHECK(it.description == "what is the weather today");
            CHECK(it.actionCommand.find("what is the weather today") != std::string::npos);
            CHECK(it.kind == OmarchySearch::EItemKind::Agent);
        }

        CHECK(OmarchySearch::isGlyphIcon("\uF249"));
        CHECK(!OmarchySearch::isGlyphIcon("folder"));
        CHECK(!OmarchySearch::isGlyphIcon("/usr/share/pixmaps/x.svg"));
    }

    // 3. Omarchy Menu Actions Search — must not fork. The old path ran
    // system("bash -c when") for every menu row on the first query and froze
    // the compositor for seconds.
    {
        const auto t0 = std::chrono::steady_clock::now();
        auto menuResults = OmarchySearch::searchMenu("lock", 5);
        const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t0).count();
        CHECK(ms < 250);
        (void)menuResults;

        const auto t1 = std::chrono::steady_clock::now();
        auto again = OmarchySearch::searchMenu("firefox", 8);
        const auto ms2 = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t1).count();
        CHECK(ms2 < 100);
        (void)again;

        auto installHits = OmarchySearch::searchMenu("install", 8);
        std::string installId;
        for (const auto& it : installHits) {
            if (it.name == "Install" && it.kind == OmarchySearch::EItemKind::Menu) {
                installId = it.id;
                CHECK(!it.icon.empty());
                CHECK(OmarchySearch::isGlyphIcon(it.icon));
                break;
            }
        }
        CHECK(!installId.empty());
        OmarchySearch::navigateMenu(installId);
        auto kids = OmarchySearch::searchMenu("", 24);
        bool hasBack = false, hasPackage = false;
        for (const auto& it : kids) {
            if (it.kind == OmarchySearch::EItemKind::Back)
                hasBack = true;
            if (it.name == "Package") {
                hasPackage = true;
                CHECK(!it.icon.empty());
            }
        }
        CHECK(hasBack);
        CHECK(hasPackage);
        OmarchySearch::resetMenuRoute();
    }

    // 4. File search is idle until a query is issued
    {
        CHECK(!OmarchySearch::fileSearchBusy());
    }

    // 5. Space handling: typing intent must never trigger Quick Look
    {
        // While typing, space is always a space character
        CHECK(!overviewSpacePreviews(ESearchIntent::Typing, true, true, true));
        CHECK(!overviewSpacePreviews(ESearchIntent::Typing, false, false, false));
        // While browsing, auto-selected file must not swallow space
        CHECK(!overviewSpacePreviews(ESearchIntent::Browsing, true, true, false));
        // Explicitly selected file can trigger preview with space
        CHECK(overviewSpacePreviews(ESearchIntent::Browsing, false, true, true));
        CHECK(!overviewSpacePreviews(ESearchIntent::Browsing, false, false, true));
        // Hovering a previewable file triggers preview
        CHECK(overviewSpacePreviews(ESearchIntent::Hovering, true, false, false));
        CHECK(!overviewSpacePreviews(ESearchIntent::Hovering, false, true, true));
    }

    // Agent prompts reach `bash -c` (activate()) as typed text, never as shell
    // (marketplace review, #11012). Every agent's real command is run through
    // bash with stand-in launchers first in PATH that record the last argv word
    // -- the prompt -- byte for byte. A canary file must not appear.
    {
        namespace fs = std::filesystem;
        char tmpl[] = "/tmp/hd-agent-test-XXXXXX";
        const fs::path DIR = mkdtemp(tmpl);
        const fs::path USAGE = DIR / "omarchy/agents/usage";
        fs::create_directories(USAGE);
        for (const char* ID : {"grok", "antigravity", "gemini", "claude", "opencode", "codex", "copilot", "crush", "pi", "agent"})
            std::ofstream(USAGE / (std::string(ID) + ".json")) << "{\"ready\": true}";
        setenv("XDG_STATE_HOME", DIR.c_str(), 1);
        const fs::path BIN = DIR / "bin";
        fs::create_directories(BIN);
        for (const char* L : {"omarchy-launch-tui", "omarchy-agent"}) {
            std::ofstream(BIN / L) << "#!/bin/bash\nprintf '%s' \"${@: -1}\" > \"$HD_GOT\"\n";
            fs::permissions(BIN / L, fs::perms::owner_all);
        }
        const fs::path CANARY = DIR / "pwned";
        const std::string PROMPT = "fix $(touch " + CANARY.string() + ") and `touch " + CANARY.string() + "` for $HOME's \"quoted\" \\ it's\nok";
        const auto ITEMS = OmarchySearch::promptAllAgents(PROMPT);
        CHECK(ITEMS.size() == 10);
        for (const auto& IT : ITEMS) {
            const fs::path GOT = DIR / "got";
            fs::remove(GOT);
            // hand actionCommand to bash -c exactly as activate() does: as one argv word, via a file
            std::ofstream(DIR / "cmd") << IT.actionCommand;
            const int RC = std::system(("env PATH='" + BIN.string() + ":/usr/bin:/bin' HD_GOT='" + GOT.string() + "' /bin/bash -c \"$(cat '" + (DIR / "cmd").string() + "')\"").c_str());
            CHECK(RC == 0);
            std::ifstream f(GOT);
            std::stringstream got;
            got << f.rdbuf();
            if (got.str() != PROMPT)
                std::cerr << IT.name << ": got [" << got.str() << "]" << std::endl;
            CHECK(got.str() == PROMPT);
            CHECK(!fs::exists(CANARY));
        }
        fs::remove_all(DIR);
    }

    // 6. OFF OMARCHY (native port, A4-A11). A scratch HOME, PATH and state dir
    // with stand-in programs: what the System column and the AI column offer,
    // what they run, and that nothing is ever written under ~/.config/omarchy.
    // Then the same agent rows ON Omarchy, to pin that its command lines did
    // not move by a byte.
    {
        namespace fs = std::filesystem;
        char tmpl[] = "/tmp/hd-native-test-XXXXXX";
        const fs::path DIR  = mkdtemp(tmpl);
        const fs::path HOME = DIR / "home";
        const fs::path BIN  = DIR / "bin";
        fs::create_directories(HOME / ".config/hyprdrive");
        fs::create_directories(BIN);
        setenv("HOME", HOME.c_str(), 1);
        setenv("PATH", BIN.c_str(), 1);
        setenv("XDG_STATE_HOME", (DIR / "state").c_str(), 1);
        unsetenv("XDG_CONFIG_HOME");
        unsetenv("TERMINAL");
        const auto stub = [&](const std::string& name, const std::string& body) {
            std::ofstream(BIN / name) << "#!/bin/bash\n" << body << "\n";
            fs::permissions(BIN / name, fs::perms::owner_all);
        };
        const auto drop = [&](const std::string& name) {
            fs::remove(BIN / name);
            OmarchySearch::invalidateProgramLookups();
        };
        for (const char* P : {"loginctl", "systemctl", "hdtest-hello"})
            stub(P, "exit 0");
        // The agents record their last argv word (the prompt) and their own
        // path; "kitty" just runs what it is handed, as the real one does.
        for (const char* A : {"claude", "codex"})
            stub(A, std::string("printf '%s' \"${@: -1}\" > \"$HD_GOT\"; printf '%s' \"$0\" > \"$HD_GOT.who\""));
        stub("kitty", "exec \"$@\"");
        stub("myterm", "[ \"$1\" = --run ] || exit 9; shift; exec \"$@\"");

        // The user's menu, in Omarchy's schema: a row of their own, a built-in
        // hidden by id, and a row whose program is not installed.
        std::ofstream(HOME / ".config/hyprdrive/menu.jsonc") << R"({
            // a comment, as in Omarchy's own file
            "hello": { "label": "Hello Test", "action": "hdtest-hello --flag", "icon": "face-smile" },
            "system.reboot": { "when": "false" },
            "ghost": { "label": "Ghost Row", "action": "omarchy-does-not-exist" },
            "needy": { "label": "Needy Row", "action": "true", "requires": ["not-installed-anywhere"] }
        })";

        static std::string s_searchTerminal;
        OmarchySearch::setHost({
            .omarchy          = [] { return false; },
            .terminalTemplate = [] { return s_searchTerminal; },
            .appTerminal      = [] { return std::string{}; },
        });
        OmarchySearch::invalidateProgramLookups();
        CHECK(OmarchySearch::menuRootTitle() == "System");
        CHECK(OmarchySearch::menuCurrentRouteTitle() == "System");

        const auto names = [](const std::vector<OmarchySearch::SSearchItem>& v) {
            std::vector<std::string> out;
            for (const auto& I : v)
                out.push_back(I.name);
            return out;
        };
        const auto has = [&](const std::vector<OmarchySearch::SSearchItem>& v, const std::string& n) {
            const auto N = names(v);
            return std::find(N.begin(), N.end(), n) != N.end();
        };

        auto root = OmarchySearch::searchMenu("", 24);
        CHECK(has(root, "Lock Screen"));
        CHECK(has(root, "Suspend"));
        CHECK(has(root, "Shut Down"));
        CHECK(has(root, "Hello Test"));
        CHECK(!has(root, "Restart"));           // hidden by the user's "when": "false"
        CHECK(!has(root, "Ghost Row"));         // its program is not installed
        CHECK(!has(root, "Needy Row"));         // "requires" a missing program
        CHECK(!has(root, "Screenshot Region")); // no grim/slurp yet
        for (const auto& I : root) {
            CHECK(I.actionCommand.find("omarchy-") == std::string::npos);
            CHECK(I.category == "System");
        }
        // Nothing from /usr/share/omarchy, which exists on fedora.
        CHECK(!has(OmarchySearch::searchMenu("install", 8), "Install"));

        stub("grim", "exit 0");
        stub("slurp", "exit 0");
        OmarchySearch::invalidateProgramLookups();
        auto shots = OmarchySearch::searchMenu("screenshot", 8);
        CHECK(has(shots, "Screenshot Region"));
        CHECK(has(shots, "Screenshot Screen"));
        drop("slurp");
        shots = OmarchySearch::searchMenu("screenshot", 8);
        CHECK(!has(shots, "Screenshot Region"));
        CHECK(has(shots, "Screenshot Screen"));
        // A harmless row, activated for real: the leading program ran.
        {
            const auto HELLO = OmarchySearch::searchMenu("hello", 4);
            CHECK(!HELLO.empty() && HELLO.front().actionCommand == "hdtest-hello --flag");
        }

        // Agents: claude and codex are installed, kitty is the terminal.
        const fs::path GOT = DIR / "got";
        setenv("HD_GOT", GOT.c_str(), 1);
        const auto runRow = [&](const OmarchySearch::SSearchItem& IT) {
            fs::remove(GOT);
            fs::remove(GOT.string() + ".who");
            std::ofstream(DIR / "cmd") << IT.actionCommand;
            return std::system(("/bin/bash -c \"$(/usr/bin/cat '" + (DIR / "cmd").string() + "')\"").c_str());
        };
        const auto slurpFile = [](const fs::path& p) {
            std::ifstream f(p);
            std::stringstream b;
            b << f.rdbuf();
            return b.str();
        };

        auto asked = OmarchySearch::promptAllAgents("fix it's $(HOME)");
        CHECK(names(asked) == (std::vector<std::string>{"Ask Claude", "Ask Codex"}));
        for (const auto& IT : asked) {
            CHECK(IT.icon.starts_with("hyprdrive-agent-"));
            CHECK(IT.actionCommand.starts_with("kitty '" + BIN.string() + "/"));
            CHECK(runRow(IT) == 0);
            CHECK(slurpFile(GOT) == "fix it's $(HOME)");
        }
        CHECK(asked.front().actionCommand == "kitty '" + (BIN / "claude").string() + "' --permission-mode auto -- 'fix it'\\''s $(HOME)'");
        CHECK(names(OmarchySearch::agentHelpItems()).size() == 2);
        CHECK(OmarchySearch::searchAgents("/grok hi").empty()); // exact, but not installed
        CHECK(OmarchySearch::searchAgents("/agent hi").empty()); // no default yet

        // A usage record that says logged out hides the agent; none says nothing.
        fs::create_directories(DIR / "state/omarchy/agents/usage");
        std::ofstream(DIR / "state/omarchy/agents/usage/codex.json") << "{\"ready\": false}";
        CHECK(names(OmarchySearch::promptAllAgents("x")) == (std::vector<std::string>{"Ask Claude"}));
        fs::remove_all(DIR / "state");

        // No terminal anywhere: no agent rows (they could not open).
        drop("kitty");
        CHECK(OmarchySearch::promptAllAgents("x").empty());
        // A configured template with {cmd}.
        s_searchTerminal = "myterm --run {cmd}";
        {
            const auto ROWS = OmarchySearch::promptAllAgents("tmpl");
            CHECK(ROWS.size() == 2);
            CHECK(!ROWS.empty() && ROWS.front().actionCommand.starts_with("myterm --run '"));
            CHECK(!ROWS.empty() && runRow(ROWS.front()) == 0 && slurpFile(GOT) == "tmpl");
        }
        // ...and one that is not installed falls through to detection (none).
        s_searchTerminal = "not-a-terminal";
        CHECK(OmarchySearch::promptAllAgents("x").empty());
        s_searchTerminal = "myterm --run {cmd}";

        // The default agent: Hyprdrive's own file, never Omarchy's dir.
        {
            auto codex = OmarchySearch::searchAgents("/codex");
            CHECK(codex.size() == 1);
            CHECK(OmarchySearch::canBeDefaultAgent(codex.front()));
            CHECK(OmarchySearch::setDefaultAgent(codex.front()));
            CHECK(slurpFile(HOME / ".config/hyprdrive/default-agent") == "codex\n");
            CHECK(!fs::exists(HOME / ".config/omarchy"));
            CHECK(OmarchySearch::isDefaultAgent(codex.front()));
            CHECK(names(OmarchySearch::promptAllAgents("y")) == (std::vector<std::string>{"Ask Codex", "Ask Claude"}));
            // `/agent` is the default, by name, and runs it.
            const auto AGENT = OmarchySearch::searchAgents("/agent go");
            CHECK(AGENT.size() == 1 && AGENT.front().name == "Ask Codex" && AGENT.front().icon == "hyprdrive-agent-codex");
            CHECK(!AGENT.empty() && runRow(AGENT.front()) == 0 && slurpFile(GOT) == "go" && slurpFile(GOT.string() + ".who") == (BIN / "codex").string());
            // "/" lists every agent once: the pseudo-row is not a second Codex.
            CHECK(OmarchySearch::searchAgents("/").size() == 2);
        }

        // ON OMARCHY: the same rows are the launcher lines they always were,
        // readiness is the usage file again, and a default lands in Omarchy's
        // file with a mirror in Hyprdrive's.
        OmarchySearch::setHost({.omarchy = [] { return true; }});
        CHECK(OmarchySearch::menuRootTitle() == "Omarchy Menu");
        {
            const auto CLAUDE = OmarchySearch::searchAgents("/claude hi there");
            CHECK(CLAUDE.size() == 1);
            CHECK(!CLAUDE.empty() && CLAUDE.front().actionCommand == "omarchy-launch-tui --app-id=org.omarchy.agent claude --permission-mode auto -- 'hi there'");
            CHECK(!CLAUDE.empty() && !CLAUDE.front().icon.starts_with("hyprdrive-agent-")); // the agents plugins' artwork, as before
            CHECK(OmarchySearch::promptAllAgents("x").empty()); // no usage records = none logged in, as before
            const auto HELP = OmarchySearch::searchAgents("/codex");
            CHECK(HELP.size() == 1 && HELP.front().actionCommand == "omarchy-launch-tui --app-id=org.omarchy.agent codex --approve-for-me -- ");
            const auto AGY = OmarchySearch::searchAgents("/agy");
            CHECK(AGY.size() == 1 && OmarchySearch::setDefaultAgent(AGY.front()));
            CHECK(slurpFile(HOME / ".config/omarchy/defaults/agent") == "gemini\n");
            CHECK(slurpFile(HOME / ".config/hyprdrive/default-agent") == "agy\n");
        }
        OmarchySearch::setHost({});
        OmarchySearch::resetMenuRoute();
        fs::remove_all(DIR);
    }

    // D6a: fd prints a directory with a trailing slash; the row's name is the
    // folder's own, its subtitle the parent -- never "" and the folder itself.
    {
        const auto DIRHIT = OmarchySearch::splitFoundPath("/home/u/Documents/");
        CHECK(DIRHIT.name == "Documents");
        CHECK(DIRHIT.dir == "/home/u");
        CHECK(DIRHIT.path == "/home/u/Documents");
        const auto FILEHIT = OmarchySearch::splitFoundPath("/home/u/Documents/hdtest-unique.txt");
        CHECK(FILEHIT.name == "hdtest-unique.txt" && FILEHIT.dir == "/home/u/Documents" && FILEHIT.path == "/home/u/Documents/hdtest-unique.txt");
        const auto TOP = OmarchySearch::splitFoundPath("/srv//");
        CHECK(TOP.name == "srv" && TOP.dir == "/" && TOP.path == "/srv");
        const auto BARE = OmarchySearch::splitFoundPath("notes.txt");
        CHECK(BARE.name == "notes.txt" && BARE.dir.empty());
        CHECK(OmarchySearch::splitFoundPath("/").name.empty()); // skipped by the worker
    }

    std::cout << "omarchy_search_test: " << s_testsPassed << " checks OK" << std::endl;
    return 0;
}

// OmarchySearch folds the dictionary/translator's generation into its own; the
// tool worker needs the compositor's config, so the host test stands it in.
namespace ToolSearch {
    uint64_t generation() {
        return 0;
    }
}
