// See BuiltinIcons.hpp. No Hyprland headers: scripts/builtin_icons_test.cpp
// links this file on the host.
#include "BuiltinIcons.hpp"

namespace {
    // Embedded with a trailing NUL so each is a C string.
    constexpr char TRASH_SVG[] = {
#embed "assets/icons/trash.svg"
        , 0};

    struct STint {
        const char* top;  const char* aTop;
        const char* mid;  const char* aMid;
        const char* bot;  const char* aBot;
        const char* shade; const char* aShade;
        const char* aSheen;
        const char* lipTop; const char* lipBot;
        const char* mouth;
        const char* edge; const char* aEdge;
        const char* aInside;
    };
    constexpr STint LIGHT{"#ffffff", "0.92", "#f1f3f6", "0.62", "#d9dde3", "0.82", "#8a929c", "0.35", "0.35", "#ffffff", "#d8dde3", "#6d7580", "#7d8590", "0.45", "0.75"};
    constexpr STint DARK{"#5a5d63", "0.92", "#2e3034", "0.72", "#1b1c1f", "0.90", "#000000", "0.45", "0.12", "#8a8d93", "#3a3c40", "#0e0f11", "#000000", "0.50", "0.55"};
    constexpr STint CLEAR{"#ffffff", "0.45", "#ffffff", "0.14", "#ffffff", "0.32", "#ffffff", "0.25", "0.30", "#ffffff", "#cfd5dc", "#48505a", "#ffffff", "0.70", "0.85"};

    void replaceAll(std::string& s, std::string_view from, std::string_view to) {
        for (size_t at = s.find(from); at != std::string::npos; at = s.find(from, at + to.size()))
            s.replace(at, from.size(), to);
    }

    // Drop every <!--TAG--> ... <!--/TAG--> block.
    void dropBlocks(std::string& s, std::string_view tag) {
        const std::string OPEN = "<!--" + std::string(tag) + "-->", CLOSE = "<!--/" + std::string(tag) + "-->";
        for (size_t a = s.find(OPEN); a != std::string::npos; a = s.find(OPEN, a)) {
            const auto B = s.find(CLOSE, a);
            if (B == std::string::npos)
                break;
            s.erase(a, B + CLOSE.size() - a);
        }
    }

    std::string trashSvg(std::string_view variant) { // "<empty|full>-<tint>-<papers>"
        const bool  FULL  = variant.starts_with("full");
        const auto& T     = variant.find("-dark") != std::string_view::npos ? DARK : variant.find("-clear") != std::string_view::npos ? CLEAR : LIGHT;
        const bool  COLOR = variant.ends_with("-color");
        std::string out   = TRASH_SVG;
        if (!FULL)
            dropBlocks(out, "PAPERS");
        else if (!COLOR)
            dropBlocks(out, "COLOR");
        // Longest tokens first: #A_TOP must not be eaten by a shorter prefix.
        const std::pair<const char*, const char*> SUBS[] = {
            {"#A_INSIDE", T.aInside}, {"#A_SHADE", T.aShade}, {"#A_SHEEN", T.aSheen}, {"#A_EDGE", T.aEdge}, {"#A_TOP", T.aTop}, {"#A_MID", T.aMid},
            {"#A_BOT", T.aBot},       {"#LIP_TOP", T.lipTop}, {"#LIP_BOT", T.lipBot}, {"#G_TOP", T.top},  {"#G_MID", T.mid},  {"#G_BOT", T.bot},
            {"#SHADE", T.shade},      {"#MOUTH", T.mouth},    {"#EDGE", T.edge},
        };
        for (const auto& [FROM, TO] : SUBS)
            replaceAll(out, FROM, TO);
        return out;
    }
    constexpr char STACK_EMPTY_SVG[] = {
#embed "assets/icons/stack-empty.svg"
        , 0};
    constexpr char SWAP_SVG[] = {
#embed "assets/icons/swap.svg"
        , 0};
    constexpr char SCRATCHPAD_SVG[] = {
#embed "assets/scratchpad-symbolic.svg"
        , 0};
    constexpr char AGENT_SVG[] = {
#embed "assets/icons/agent.svg"
        , 0};

    // Each agent's tile, top and bottom of its gradient. Our own picks, chosen
    // to tell nine rows apart at 20 px on a dark or a light card -- not any
    // vendor's brand colours.
    struct SAgentTint {
        std::string_view prefix, top, bot;
    };
    constexpr SAgentTint AGENT_TINTS[] = {
        {"claude", "#e08a5c", "#b85a34"},   {"codex", "#3fb68b", "#1f7f5e"},   {"gemini", "#5b8def", "#3159c4"},
        {"agy", "#8b6cf0", "#5a3fc4"},      {"grok", "#6b7280", "#3b4150"},    {"opencode", "#f0b13c", "#c27d12"},
        {"copilot", "#a35ee0", "#7134b0"},  {"crush", "#ec5f86", "#bb3159"},   {"pi", "#38b2ac", "#1f7f7a"},
    };
    constexpr SAgentTint AGENT_DEFAULT_TINT{"", "#64748b", "#3f4a5c"};

    std::string agentSvg(std::string_view prefix) {
        const SAgentTint* tint = &AGENT_DEFAULT_TINT;
        for (const auto& T : AGENT_TINTS)
            if (T.prefix == prefix)
                tint = &T;
        std::string out = AGENT_SVG;
        replaceAll(out, "#TILE_TOP", tint->top);
        replaceAll(out, "#TILE_BOT", tint->bot);
        return out;
    }
}

namespace ScrollOverview::BuiltinIcons {
    std::string trashName(bool empty, std::string_view style, std::string_view papers) {
        const std::string_view TINT = style == "dark" ? "dark" : style == "clear" ? "clear" : "light";
        return std::string(TRASH_PREFIX) + (empty ? "empty-" : "full-") + std::string(TINT) + (papers == "color" ? "-color" : "-white");
    }

    std::string svg(std::string_view name, std::string_view accentHex) {
        std::string out = name.starts_with(TRASH_PREFIX) ? trashSvg(name.substr(TRASH_PREFIX.size())) : name == STACK_EMPTY ? std::string(STACK_EMPTY_SVG) :
            name == SWAP                                                                    ? std::string(SWAP_SVG) :
            name == SCRATCHPAD                                                              ? std::string(SCRATCHPAD_SVG) :
            name.starts_with(AGENT_PREFIX)                                                  ? agentSvg(name.substr(AGENT_PREFIX.size())) :
                                                                                              std::string();
        constexpr std::string_view TOKEN = "#ACCENT";
        for (size_t at = out.find(TOKEN); at != std::string::npos; at = out.find(TOKEN, at + accentHex.size()))
            out.replace(at, TOKEN.size(), accentHex);
        return out;
    }
}
