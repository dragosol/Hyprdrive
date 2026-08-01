#include "AppSearch.hpp"

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <unordered_set>

#include <hyprutils/os/Process.hpp>

using namespace Hyprutils::OS;

namespace AppSearch {
    namespace {
        std::vector<SEntry> g_entries;
        bool                g_scanned = false;

        std::string         lower(std::string s) {
            std::ranges::transform(s, s.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
            return s;
        }

        std::string trim(const std::string& s) {
            const auto B = s.find_first_not_of(" \t\r\n");
            if (B == std::string::npos)
                return "";
            const auto E = s.find_last_not_of(" \t\r\n");
            return s.substr(B, E - B + 1);
        }

        // XDG basedir order: $XDG_DATA_HOME first, then $XDG_DATA_DIRS. Earlier
        // entries win on desktop-id collision, which is what lets a user's
        // ~/.local override a system entry.
        std::vector<std::string> appDirs() {
            std::vector<std::string> dirs;

            const char* DATAHOME = std::getenv("XDG_DATA_HOME");
            const char* HOME     = std::getenv("HOME");
            if (DATAHOME && *DATAHOME)
                dirs.emplace_back(std::string{DATAHOME} + "/applications");
            else if (HOME && *HOME)
                dirs.emplace_back(std::string{HOME} + "/.local/share/applications");

            const char*       DATADIRS = std::getenv("XDG_DATA_DIRS");
            const std::string REST     = DATADIRS && *DATADIRS ? DATADIRS : "/usr/local/share:/usr/share";

            size_t start = 0;
            while (start <= REST.size()) {
                const auto  END  = REST.find(':', start);
                const auto  PART = REST.substr(start, END == std::string::npos ? std::string::npos : END - start);
                if (!PART.empty())
                    dirs.emplace_back(PART + "/applications");
                if (END == std::string::npos)
                    break;
                start = END + 1;
            }

            return dirs;
        }

        bool onPath(const std::string& binary) {
            if (binary.empty())
                return true;

            if (binary.contains('/')) {
                std::error_code ec;
                return std::filesystem::exists(binary, ec);
            }

            const char* PATHENV = std::getenv("PATH");
            if (!PATHENV || !*PATHENV)
                return true;

            const std::string PATHS = PATHENV;
            size_t            start = 0;
            while (start <= PATHS.size()) {
                const auto END  = PATHS.find(':', start);
                const auto PART = PATHS.substr(start, END == std::string::npos ? std::string::npos : END - start);
                if (!PART.empty()) {
                    std::error_code ec;
                    if (std::filesystem::exists(PART + "/" + binary, ec))
                        return true;
                }
                if (END == std::string::npos)
                    break;
                start = END + 1;
            }

            return false;
        }

        // Only the [Desktop Entry] group is read; later groups are actions and
        // must not overwrite the entry's own keys.
        bool parseEntry(const std::filesystem::path& path, const std::string& id, SEntry& out) {
            std::ifstream file(path);
            if (!file.is_open())
                return false;

            bool        inEntry = false;
            std::string type, tryExec;
            std::string line;

            while (std::getline(file, line)) {
                const auto L = trim(line);
                if (L.empty() || L.starts_with('#'))
                    continue;

                if (L.starts_with('[')) {
                    inEntry = L == "[Desktop Entry]";
                    continue;
                }

                if (!inEntry)
                    continue;

                const auto EQ = L.find('=');
                if (EQ == std::string::npos)
                    continue;

                const auto KEY = trim(L.substr(0, EQ));
                const auto VAL = trim(L.substr(EQ + 1));

                // Localised keys (Name[de]) are skipped for now: the C locale
                // name is what the fallback ranking uses.
                if (KEY == "Type")
                    type = VAL;
                else if (KEY == "Name")
                    out.name = VAL;
                else if (KEY == "GenericName")
                    out.generic = VAL;
                else if (KEY == "Comment")
                    out.comment = VAL;
                else if (KEY == "Keywords")
                    out.keywords = VAL;
                else if (KEY == "Exec")
                    out.exec = VAL;
                else if (KEY == "Icon")
                    out.icon = VAL;
                else if (KEY == "StartupWMClass")
                    out.wmClass = VAL;
                else if (KEY == "TryExec")
                    tryExec = VAL;
                else if (KEY == "Terminal")
                    out.terminal = VAL == "true";
                else if ((KEY == "NoDisplay" || KEY == "Hidden") && VAL == "true")
                    return false;
            }

            if (type != "Application" || out.name.empty() || out.exec.empty())
                return false;

            if (!onPath(tryExec))
                return false;

            out.id       = id;
            out.haystack = lower(out.name + " " + out.generic + " " + out.comment + " " + out.keywords + " " + id);

            return true;
        }

        void scan() {
            g_entries.clear();

            std::unordered_set<std::string> seen;

            for (const auto& DIR : appDirs()) {
                std::error_code ec;
                if (!std::filesystem::is_directory(DIR, ec))
                    continue;

                for (auto it = std::filesystem::recursive_directory_iterator(DIR, std::filesystem::directory_options::skip_permission_denied, ec);
                     it != std::filesystem::recursive_directory_iterator(); it.increment(ec)) {
                    if (ec)
                        break;

                    const auto& PATH = it->path();
                    if (PATH.extension() != ".desktop")
                        continue;

                    // Desktop id: path relative to the applications dir with
                    // separators turned into '-', per the XDG menu spec.
                    // Lexical, not std::filesystem::relative: that one resolves
                    // symlinks, so an entry symlinked out to a store path came
                    // back as "..-..-..-app-<hash>-export-share-..." and dragged
                    // the whole store path into the search haystack.
                    auto id = PATH.lexically_relative(DIR).string();
                    if (id.empty() || id.starts_with(".."))
                        id = PATH.filename().string();
                    std::ranges::replace(id, '/', '-');
                    if (id.ends_with(".desktop"))
                        id = id.substr(0, id.size() - 8);

                    if (seen.contains(id))
                        continue;

                    SEntry entry;
                    if (!parseEntry(PATH, id, entry))
                        continue;

                    seen.insert(id);
                    g_entries.emplace_back(std::move(entry));
                }
            }
        }

        // Word-prefix beats substring, and a shorter name beats a longer one at
        // equal quality, so "fi" puts Files above Firmware Updater without
        // needing a real fuzzy matcher yet.
        int score(const SEntry& entry, const std::string& needle) {
            const auto NAME = lower(entry.name);

            int base = -1;
            if (NAME == needle)
                base = 1000;
            else if (NAME.starts_with(needle))
                base = 900;
            else {
                for (size_t i = 0; i + 1 < NAME.size(); ++i) {
                    if ((NAME[i] == ' ' || NAME[i] == '-') && NAME.compare(i + 1, needle.size(), needle) == 0) {
                        base = 800;
                        break;
                    }
                }
            }

            if (base < 0 && NAME.contains(needle))
                base = 600;
            if (base < 0 && lower(entry.id).contains(needle))
                base = 400;
            if (base < 0 && entry.haystack.contains(needle))
                base = 250;

            if (base < 0)
                return -1;

            return base - std::min<int>(99, static_cast<int>(entry.name.size()));
        }

        // Desktop Exec field codes. %% is a literal percent and must be handled
        // before the rest, or "%%f" would lose its f.
        std::string stripFieldCodes(const std::string& exec) {
            std::string out;
            out.reserve(exec.size());

            for (size_t i = 0; i < exec.size(); ++i) {
                if (exec[i] != '%') {
                    out.push_back(exec[i]);
                    continue;
                }

                if (i + 1 >= exec.size())
                    break;

                const char CODE = exec[++i];
                if (CODE == '%')
                    out.push_back('%');
                // every other code expands to nothing: no file, no url, no icon
            }

            return out;
        }

        std::vector<std::string> splitArgs(const std::string& cmd) {
            std::vector<std::string> args;
            std::string              current;
            bool                     quoted = false, any = false;

            for (size_t i = 0; i < cmd.size(); ++i) {
                const char C = cmd[i];

                if (C == '\\' && i + 1 < cmd.size() && quoted) {
                    current.push_back(cmd[++i]);
                    any = true;
                } else if (C == '"') {
                    quoted = !quoted;
                    any    = true;
                } else if (!quoted && (C == ' ' || C == '\t')) {
                    if (any)
                        args.emplace_back(current);
                    current.clear();
                    any = false;
                } else {
                    current.push_back(C);
                    any = true;
                }
            }

            if (any)
                args.emplace_back(current);

            return args;
        }
    }

    const std::vector<SEntry>& inventory() {
        if (!g_scanned) {
            g_scanned = true;
            scan();
        }
        return g_entries;
    }

    void refresh() {
        g_scanned = true;
        scan();
    }

    std::vector<const SEntry*> search(const std::string& query, size_t limit) {
        std::vector<const SEntry*> results;
        if (query.empty() || limit == 0)
            return results;

        const auto NEEDLE = lower(query);

        std::vector<std::pair<int, const SEntry*>> scored;
        for (const auto& ENTRY : inventory()) {
            const int S = score(ENTRY, NEEDLE);
            if (S >= 0)
                scored.emplace_back(S, &ENTRY);
        }

        std::ranges::stable_sort(scored, [](const auto& a, const auto& b) { return a.first > b.first; });

        for (const auto& [SCORE, ENTRY] : scored) {
            if (results.size() >= limit)
                break;
            results.emplace_back(ENTRY);
        }

        return results;
    }

    bool launch(const SEntry& entry, const std::string& terminalCmd) {
        auto args = splitArgs(stripFieldCodes(entry.exec));
        if (args.empty())
            return false;

        if (entry.terminal) {
            const char* ENVTERM = std::getenv("TERMINAL");
            const auto  TERM    = !terminalCmd.empty() ? terminalCmd : (ENVTERM && *ENVTERM ? std::string{ENVTERM} : std::string{});
            if (TERM.empty())
                return false;

            auto termArgs = splitArgs(TERM);
            if (termArgs.empty())
                return false;

            termArgs.emplace_back("-e");
            termArgs.insert(termArgs.end(), args.begin(), args.end());
            args = std::move(termArgs);
        }

        const auto BINARY = args.front();
        args.erase(args.begin());

        CProcess process(BINARY, args);
        return process.runAsync();
    }
}

// ponytail: self-check lives in the TU so it can reach the anonymous namespace.
// Build with: g++ -std=c++2b -DAPPSEARCH_TEST AppSearch.cpp -o /tmp/appsearch_test
#ifdef APPSEARCH_TEST
    #include <cassert>
    #include <cstdio>

int main() {
    using namespace AppSearch;

    assert(stripFieldCodes("firefox %u") == "firefox ");
    assert(stripFieldCodes("foo %%f") == "foo %f");
    assert(stripFieldCodes("gimp-2.10 %U") == "gimp-2.10 ");

    auto a = splitArgs("env LANG=C \"my app\" -x");
    assert(a.size() == 4);
    assert(a[2] == "my app");
    assert(splitArgs("   ").empty());

    // A quoted empty argument must survive, or Exec="" collapses into nothing.
    auto q = splitArgs("sh -c \"\"");
    assert(q.size() == 3 && q[2].empty());

    SEntry e;
    e.name     = "Files";
    e.id       = "org.gnome.Nautilus";
    e.haystack = lower("Files File Manager folders org.gnome.Nautilus");
    SEntry f;
    f.name     = "Firmware Updater";
    f.id       = "org.fwupd.fwupdmgr";
    f.haystack = lower("Firmware Updater org.fwupd.fwupdmgr");

    assert(score(e, "files") == 1000 - 5);
    assert(score(e, "fi") > score(f, "fi")); // shorter name wins at equal quality
    assert(score(e, "nautilus") > 0);        // id match
    assert(score(e, "zzzz") == -1);

    SEntry w;
    w.name     = "Text Editor";
    w.haystack = lower("Text Editor");
    assert(score(w, "editor") == 800 - 11); // word-prefix beats plain substring

    const auto& INV = inventory();
    std::printf("inventory: %zu visible apps\n", INV.size());
    assert(!INV.empty());

    const auto R = search("te", 5);
    std::printf("search(\"te\"): %zu results, top = %s\n", R.size(), R.empty() ? "(none)" : R.front()->name.c_str());
    assert(search("", 5).empty());

    std::printf("AppSearch self-check OK\n");
    return 0;
}
#endif
