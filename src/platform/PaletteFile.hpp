#pragma once

// A PALETTE FILE, READ (native port, docs/native/OMARCHY-AUDIT.md A12 / P2-8).
// What plugin:hyprdrive:theme:palette_file points at, and Omarchy's
// colors.toml, become one SPalette here. Pure -- no Hyprland, no file I/O (the
// caller reads the file; Config.cpp caches it on path and mtime) -- so
// scripts/palette_file_test.cpp checks every shape on the host.
//
// Three shapes:
//   * colors.toml-style lines     `key = "#rrggbb"` -- Omarchy's background,
//                                 foreground, muted, accent, selection,
//                                 dark_/light_foreground, red (or urgent), and
//                                 `mode = light|dark`
//   * pywal / wallust colors.json special.background/foreground, color0..15:
//                                 accent = color4 (wal's blue slot, what its
//                                 templates accent with), muted = color8,
//                                 urgent = color1
//   * matugen JSON                Material roles, dark scheme: surface,
//                                 on_surface, primary, on_surface_variant /
//                                 outline, primary_container, error -- under
//                                 colors.<mode>.<role> (2.x) or
//                                 colors.<role>.<mode>[.color] (3.x)
// A role the file does not name is left unset (has* false): Config.cpp then
// derives it -- except for Omarchy's colors.toml, which keeps the fixed
// defaults below exactly as every earlier build did.

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>

namespace ScrollOverview::PaletteFile {
    struct SPalette {
        bool     valid           = false;
        bool     isLight         = false;
        uint32_t background      = 0xFF0c0b0c;
        uint32_t foreground      = 0xFFFAFCFB;
        uint32_t muted           = 0xFF584e51;
        uint32_t accent          = 0xFFb59790;
        uint32_t selection       = 0xFF584e51;
        uint32_t darkForeground  = 0;
        uint32_t lightForeground = 0;
        uint32_t urgent          = 0xFFa55555;
        bool     hasBg = false, hasFg = false, hasMuted = false, hasAccent = false, hasSel = false;
        bool     hasDarkFg       = false;
        bool     hasLightFg      = false;
        bool     hasUrgent       = false;
    };

    // Sniffs the shape: a leading '{' is JSON (pywal, else matugen), anything
    // else is key = value lines. `explicitMode` is set when the file says
    // light or dark itself.
    SPalette parse(std::string_view text, bool& explicitMode);
    // The key = value shape only (Omarchy's colors.toml).
    SPalette parseKeyValues(std::string_view text, bool& explicitMode);

    // "#rrggbb" / "rrggbb" / "#rrggbbaa" -> opaque 0xFFrrggbb.
    std::optional<uint32_t> parseHex(std::string_view v);
    // Every string leaf of a JSON document as "a.b.c" -> value (array
    // elements by index); numbers, bools and null are skipped. Malformed input
    // stops the walk and keeps what was read.
    std::unordered_map<std::string, std::string> flattenJson(std::string_view text);
}
