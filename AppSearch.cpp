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
        constexpr const char* GENERIC_ICON = "application-x-executable";

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

        // App icons in practice live in hicolor, NOT in the active theme:
        // measured in the guest, Adwaita ships only 16x16/scalable/symbolic UI
        // icons and every app icon (kitty, org.gnome.Nautilus, foot,
        // pavucontrol...) is under /usr/share/icons/hicolor. That is why this
        // does not parse index.theme or walk Inherits= chains -- a filename
        // search over a few roots answers the question the scope was worried
        // about, and an SVG rasterises at whatever size the caller wants.
        std::string iconThemeName() {
            const char* ENVTHEME = std::getenv("XDG_ICON_THEME");
            if (ENVTHEME && *ENVTHEME)
                return ENVTHEME;

            const char* HOME = std::getenv("HOME");
            if (HOME && *HOME) {
                std::ifstream settings(std::string{HOME} + "/.config/gtk-3.0/settings.ini");
                std::string   line;
                while (std::getline(settings, line)) {
                    const auto L = trim(line);
                    if (!L.starts_with("gtk-icon-theme-name"))
                        continue;
                    const auto EQ = L.find('=');
                    if (EQ != std::string::npos)
                        return trim(L.substr(EQ + 1));
                }
            }

            return "Adwaita";
        }

        // The bases that hold an /icons tree, in XDG priority order.
        std::vector<std::string> iconBases() {
            std::vector<std::string> bases;
            for (const auto& DIR : appDirs()) {
                // appDirs() hands back ".../applications"; icons are a sibling.
                bases.emplace_back(DIR.substr(0, DIR.size() - std::string{"/applications"}.size()) + "/icons");
            }
            const char* HOME = std::getenv("HOME");
            if (HOME && *HOME)
                bases.emplace_back(std::string{HOME} + "/.icons");
            return bases;
        }

        // App icons live in hicolor, but NAMED freedesktop icons
        // (preferences-system, applications-other) live in the theme and its
        // ancestors: measured in the guest, Adwaita inherits AdwaitaLegacy then
        // hicolor, and preferences-system exists only in AdwaitaLegacy. So the
        // Inherits= chain does have to be walked -- just the chain, not the
        // per-directory Size/Context/Type machinery, which the filename search
        // makes unnecessary.
        std::vector<std::string> themeChain(const std::string& theme) {
            std::vector<std::string> chain, queue{theme};

            for (size_t head = 0; head < queue.size() && chain.size() < 16; ++head) {
                const auto NAME = queue[head];
                if (NAME.empty() || std::ranges::contains(chain, NAME))
                    continue;
                chain.emplace_back(NAME);

                for (const auto& BASE : iconBases()) {
                    std::ifstream index(BASE + "/" + NAME + "/index.theme");
                    if (!index.is_open())
                        continue;

                    std::string line;
                    while (std::getline(index, line)) {
                        const auto L = trim(line);
                        if (!L.starts_with("Inherits"))
                            continue;
                        const auto EQ = L.find('=');
                        if (EQ == std::string::npos)
                            continue;

                        const auto VAL = trim(L.substr(EQ + 1));
                        size_t     start = 0;
                        while (start <= VAL.size()) {
                            const auto END  = VAL.find(',', start);
                            const auto PART = trim(VAL.substr(start, END == std::string::npos ? std::string::npos : END - start));
                            if (!PART.empty())
                                queue.emplace_back(PART);
                            if (END == std::string::npos)
                                break;
                            start = END + 1;
                        }
                        break;
                    }
                    break;
                }
            }

            if (!std::ranges::contains(chain, std::string{"hicolor"}))
                chain.emplace_back("hicolor");

            return chain;
        }

        // Higher is better. SVG wins outright: one file scales to any row
        // height, so nothing has to be re-picked when the card transform
        // changes. Otherwise prefer the largest raster, parsed out of the
        // "256x256" style directory name.
        int iconCandidateScore(const std::filesystem::path& path) {
            if (path.extension() == ".svg")
                return 100000;

            if (path.extension() != ".png" && path.extension() != ".xpm")
                return -1;

            int        size = 0;
            const auto PARENTS = path.parent_path().string();
            for (size_t i = 0; i < PARENTS.size(); ++i) {
                if (!std::isdigit(static_cast<unsigned char>(PARENTS[i])))
                    continue;
                int n = 0;
                while (i < PARENTS.size() && std::isdigit(static_cast<unsigned char>(PARENTS[i])))
                    n = (n * 10) + (PARENTS[i++] - '0');
                size = std::max(size, n);
            }

            // A themeless location (pixmaps) still beats nothing.
            return std::min(size, 4096);
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

    std::string resolveIconPath(const std::string& iconName) {
        if (iconName.empty())
            return "";

        std::error_code ec;

        // Icon= may legitimately be an absolute path.
        if (iconName.starts_with('/'))
            return std::filesystem::exists(iconName, ec) ? iconName : "";

        std::vector<std::string> roots;
        for (const auto& THEME : themeChain(iconThemeName())) {
            for (const auto& BASE : iconBases())
                roots.emplace_back(BASE + "/" + THEME);
        }
        roots.emplace_back("/usr/share/pixmaps");

        std::string best;
        int         bestScore = -1;

        for (const auto& ROOT : roots) {
            if (!std::filesystem::is_directory(ROOT, ec))
                continue;

            for (auto it = std::filesystem::recursive_directory_iterator(ROOT, std::filesystem::directory_options::skip_permission_denied, ec);
                 it != std::filesystem::recursive_directory_iterator(); it.increment(ec)) {
                if (ec)
                    break;

                const auto& PATH = it->path();
                if (PATH.stem() != iconName)
                    continue;

                const int SCORE = iconCandidateScore(PATH);
                if (SCORE > bestScore) {
                    bestScore = SCORE;
                    best      = PATH.string();
                }
            }

            // Roots are in priority order, so stop at the first that answers.
            if (bestScore >= 0)
                break;
        }

        // Named icons from another desktop's theme (breeze's
        // utilities-system-monitor) simply are not present here. A generic tile
        // is the honest answer, and it is what GNOME shows too.
        if (best.empty() && iconName != GENERIC_ICON)
            return resolveIconPath(GENERIC_ICON);

        return best;
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

    std::printf("icon theme: %s\n", iconThemeName().c_str());
    assert(iconCandidateScore("/usr/share/icons/hicolor/scalable/apps/kitty.svg") > iconCandidateScore("/usr/share/icons/hicolor/256x256/apps/kitty.png"));
    assert(iconCandidateScore("/usr/share/icons/hicolor/256x256/apps/kitty.png") > iconCandidateScore("/usr/share/icons/hicolor/48x48/apps/foot.png"));
    assert(iconCandidateScore("/usr/share/icons/hicolor/48x48/apps/x.txt") == -1);
    assert(resolveIconPath("").empty());
    // An unknown name resolves to the generic tile, not to nothing.
    const auto GENERIC = resolveIconPath(GENERIC_ICON);
    assert(!GENERIC.empty());
    assert(resolveIconPath("definitely-not-an-icon-zzz") == GENERIC);
    // The chain must reach the ancestor that actually holds the legacy names.
    const auto CHAIN = themeChain(iconThemeName());
    assert(std::ranges::contains(CHAIN, std::string{"hicolor"}));
    std::printf("theme chain:");
    for (const auto& T : CHAIN)
        std::printf(" %s", T.c_str());
    std::printf("\n");

    size_t withIcons = 0;
    for (const auto& E : inventory()) {
        if (!resolveIconPath(E.icon).empty())
            ++withIcons;
    }
    std::printf("icons resolved: %zu / %zu entries\n", withIcons, inventory().size());
    assert(withIcons > 0);

    const auto R = search("te", 5);
    std::printf("search(\"te\"): %zu results, top = %s\n", R.size(), R.empty() ? "(none)" : R.front()->name.c_str());
    assert(search("", 5).empty());

    std::printf("AppSearch self-check OK\n");
    return 0;
}
#endif
