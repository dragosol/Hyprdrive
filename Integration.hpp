#pragma once

// INTEGRATION -- THE one answer to "is this an Omarchy desktop?" (native port,
// docs/native/OMARCHY-AUDIT.md P0-1). Hyprdrive runs on plain Hyprland 0.56 with
// no Omarchy anywhere, and on Omarchy exactly as it always has; everything that
// only makes sense on Omarchy (the menu column, `omarchy-launch-tui` agents, the
// default-agent file, colors.toml, the settings panel, Mosaic's Super+L
// takeover...) asks HERE instead of stat()ing its own Omarchy path. A second
// private check is a second answer, and two answers disagree on exactly the
// machines that matter: fedora's hyprtest has Omarchy state files and no Omarchy.
//
// The rule (precedence, values, why both halves of auto) is in IntegrationRule.hpp.
// In one line: HYPRDRIVE_NO_OMARCHY=1 > HYPRDRIVE_INTEGRATION > the config key
// plugin:hyprdrive:integration (auto|omarchy|none, default auto) > auto
// (`omarchy` on PATH AND ~/.local/state/omarchy/current).
//
// ---- C++ (this header) -----------------------------------------------------
//
//   #include "Integration.hpp"
//   if (ScrollOverview::Integration::omarchy()) { ...Omarchy-only path... }
//
//   omarchy()    the cached answer. Cheap (one load), callable from a render
//                pass, from any thread after init, and -- unlike a config read --
//                BEFORE registerConfig(): until the key exists it answers from
//                env + auto alone, so a PLUGIN_INIT caller cannot abort Hyprland
//                (Config.hpp, earlyPluginKey).
//   desktop()    the same as an enum, for a switch.
//   decision()   desktop + which rule line decided + a human reason, for logs
//                and `hyprctl hyprdrive-integration`. The reference is stable
//                but its contents change on reevaluate(): copy what you keep.
//   generation() bumped whenever the ANSWER changes (not on every reload), so a
//                cache keyed on it rebuilds only when it has to:
//                    if (seen != Integration::generation()) { seen = ...; rebuild(); }
//   reevaluate() re-probe now. main.cpp calls it on every config.reloaded,
//                first, before anything else in that hook reads it; there is
//                no other reason to call it.
//
// ---- Lua (fragments, hyprland.lua) -----------------------------------------
//
//   hl.plugin.hyprdrive.integration()  -> "omarchy" | "none", reason
//       Evaluated FRESH on each call (env + the key's value at that point of
//       the parse + the filesystem), not the cached answer: during a parse the
//       cache still holds the previous parse's result.
//   hyprdrive_integration() / hyprdrive_omarchy()   (defined in 00-plugin.lua)
//       Use these in fragments: they call the plugin function when it is
//       loaded and fall back to the same rule in Lua when it is not (first
//       parse, a hand-copied .so, Omarchy's keybinding scanner's stub `hl`).
//
// ---- shell (install scripts, hdpanel, anything outside the compositor) ------
//
//   hyprctl hyprdrive-integration [-j]
//       The running plugin's cached answer: "omarchy" or "none" on the first
//       line, then "source: <line>" and "reason: <text>"; with -j
//       {"integration": "...", "source": "...", "reason": "..."}.
//   hyprdrive-integration [-q] [--why] [--offline]     ($PREFIX/bin, from
//   scripts/hyprdrive-integration)
//       Asks the running plugin when there is one, else applies the same rule
//       itself. Prints omarchy|none; -q prints nothing and exits 0 for omarchy,
//       1 for none; --why adds the source and reason. Python:
//           subprocess.run(["hyprdrive-integration", "-q"]).returncode == 0
//
// What this does NOT do: decide anything about a feature. "Omarchy" means the
// Omarchy files and commands are there to be used; whether a given feature then
// uses them (or offers a native equivalent too) is that feature's call.

#include "IntegrationRule.hpp"

#include <cstdint>

struct lua_State; // lua.h's, at global scope -- not a new one in this namespace

namespace ScrollOverview::Integration {
    bool             omarchy();
    EDesktop         desktop();
    const SDecision& decision();
    uint64_t         generation();
    void             reevaluate();

    // The inputs as they are right now, `configValue` passed in by the caller
    // (the cached path reads the key, the Lua path reads it mid-parse).
    SProbe probe(std::string_view configValue);

    // PLUGIN_INIT, after Config::registerConfig(): the hyprctl command. The Lua
    // function is registered by Config.cpp with the others (Lua config only).
    void init();
    // PLUGIN_EXIT: unregister the hyprctl command (its lambda is in this .so).
    void shutdown();

    // hl.plugin.hyprdrive.integration -- a lua_CFunction (lua_State*), declared
    // here without the Lua headers.
    int luaIntegration(lua_State* L);
}
