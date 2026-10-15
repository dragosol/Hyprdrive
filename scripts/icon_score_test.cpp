// IconScore.hpp: which file of an icon the index keeps (G6 -- the largest SVG
// design, not whichever size directory the walk reached first).
#include "../IconScore.hpp"

#include <cstdio>
#include <string>

using AppSearch::IconScore::iconCandidateScore;
using AppSearch::IconScore::iconDirSize;

static int g_fail = 0, g_checks = 0;
static void check(bool ok, const std::string& what) {
    ++g_checks;
    if (!ok) {
        ++g_fail;
        std::printf("FAIL: %s\n", what.c_str());
    }
}

int main() {
    // The old contract.
    check(iconCandidateScore("/usr/share/icons/hicolor/scalable/apps/kitty.svg") > iconCandidateScore("/usr/share/icons/hicolor/256x256/apps/kitty.png"), "svg beats png");
    check(iconCandidateScore("/usr/share/icons/hicolor/256x256/apps/kitty.png") > iconCandidateScore("/usr/share/icons/hicolor/48x48/apps/foot.png"), "bigger png wins");
    check(iconCandidateScore("/usr/share/icons/hicolor/48x48/apps/x.txt") == -1, "not an icon");
    check(iconCandidateScore("/usr/share/pixmaps/a.png") == 0, "pixmaps scores 0 (still beats nothing)");
    check(iconCandidateScore("/usr/share/icons/Papirus/16x16/apps/a.svg") > iconCandidateScore("/usr/share/icons/hicolor/512x512/apps/a.png"), "any svg beats any png");

    // G6: SVG designs per size.
    check(iconCandidateScore("/usr/share/icons/Papirus/64x64/mimetypes/text-x-generic.svg") > iconCandidateScore("/usr/share/icons/Papirus/16x16/mimetypes/text-x-generic.svg"),
          "Papirus 64x64 sheet beats the 16x16 line glyph");
    check(iconCandidateScore("/usr/share/icons/Papirus-Dark/48x48/mimetypes/a.svg") > iconCandidateScore("/usr/share/icons/Papirus-Dark/24x24/mimetypes/a.svg"), "48 > 24");
    check(iconCandidateScore("/usr/share/icons/hicolor/scalable/apps/a.svg") > iconCandidateScore("/usr/share/icons/Papirus/64x64/apps/a.svg"), "scalable beats sized");
    check(iconCandidateScore("/usr/share/icons/Adwaita/symbolic/mimetypes/a-symbolic.svg") < iconCandidateScore("/usr/share/icons/Adwaita/16x16/mimetypes/a.svg"),
          "a symbolic folder is no size");

    // Directory names only.
    check(iconDirSize("/usr/share/icons/Papirus/16x16@2x/apps/a.svg") == 32, "@2x doubles");
    check(iconDirSize("/usr/share/icons/elementary/apps/48/a.svg") == 48, "bare number dir");
    check(iconDirSize("/home/w2s/.local/share/icons/T/16x16/apps/a.png") == 16, "digits in a home name are not a size");
    check(iconDirSize("/opt/x11/icons/T/apps/a.png") == 0, "x11 is not a size");
    check(iconDirSize("/opt/T/22x22-old/apps/a.png") == 0, "22x22-old is not a size");
    check(iconDirSize("/opt/T/32x32@2/apps/a.png") == 0, "malformed scale suffix");

    std::printf("icon_score_test: %d checks, %d failed\n", g_checks, g_fail);
    return g_fail ? 1 : 0;
}
