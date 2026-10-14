#pragma once

// INTEGRATION, the pure half: given what the environment, the config key and the
// filesystem say, is this an Omarchy desktop? No Hyprland headers, so
// scripts/integration_test.cpp runs every precedence case on the host.
// Integration.hpp is the API the rest of the plugin calls; Integration.cpp
// gathers the inputs (probe) and caches the answer.
//
// THE RULE, in precedence order -- the first line that has something to say
// decides, and the reason string says which one did:
//
//   1. HYPRDRIVE_NO_OMARCHY=1                    -> none     (a force-off, for
//      testing on a machine that has Omarchy files it cannot remove: fedora's
//      root-owned /usr/share/omarchy is why this exists)
//   2. HYPRDRIVE_INTEGRATION=auto|omarchy|none   -> that     (auto falls through)
//   3. plugin:hyprdrive:integration = auto|omarchy|none -> that (auto falls through)
//   4. auto: `omarchy` is an executable on PATH AND
//      $XDG_STATE_HOME/omarchy/current (default ~/.local/state/omarchy/current)
//      exists                                    -> omarchy, else none
//
// Env beats the config key because the env is the per-session override (a test
// run, a nested instance) and the key is the standing preference. BOTH halves of
// auto are required: the command alone is an Omarchy package on a machine that
// never ran it (or a stray file in ~/.local/bin), the state dir alone is a home
// directory carried over from an Omarchy install to a plain one -- hyprtest on
// fedora has exactly that, and treating it as Omarchy would put five dead
// omarchy-* rows in the search.
//
// An unknown value (a typo) is NOT an error that stops anything: it is treated
// as auto and the reason says so, because the cost of guessing wrong here is a
// label and a menu column, not a broken session.
//
// scripts/hyprdrive-integration is the same rule in shell for code that runs
// without the plugin (make install, hdpanel). Change one, change both:
// integration_test.cpp checks this file, and the shell's header points here.

#include <string>
#include <optional>
#include <string_view>

namespace ScrollOverview::Integration {

    enum class EDesktop { None, Omarchy };

    // Which line of the rule decided.
    enum class ESource { ForceOff, Env, Config, Auto };

    // Everything decide() looks at, gathered by probe() (Integration.cpp) or
    // written by hand in the host test.
    struct SProbe {
        bool        noOmarchyEnv = false; // HYPRDRIVE_NO_OMARCHY is "1" (exactly; "0" and "" are not a force-off)
        std::string envValue;             // HYPRDRIVE_INTEGRATION, "" when unset
        std::string configValue;          // plugin:hyprdrive:integration, "" before the key exists
        bool        omarchyOnPath = false;
        bool        omarchyState  = false;
    };

    struct SDecision {
        EDesktop    desktop = EDesktop::None;
        ESource     source  = ESource::Auto;
        std::string reason;
    };

    constexpr std::string_view name(EDesktop d) {
        return d == EDesktop::Omarchy ? "omarchy" : "none";
    }

    constexpr std::string_view name(ESource s) {
        switch (s) {
            case ESource::ForceOff: return "env:HYPRDRIVE_NO_OMARCHY";
            case ESource::Env: return "env:HYPRDRIVE_INTEGRATION";
            case ESource::Config: return "config";
            case ESource::Auto: return "auto";
        }
        return "auto";
    }

    // "auto" | "omarchy" | "none" -> 0 auto, 1 omarchy, 2 none; -1 for anything
    // else (empty included). Exact, lowercase: the key is documented that way and
    // a second spelling is a second thing to document.
    constexpr int parseValue(std::string_view v) {
        if (v == "auto")
            return 0;
        if (v == "omarchy")
            return 1;
        if (v == "none")
            return 2;
        return -1;
    }

    inline SDecision decide(const SProbe& p) {
        if (p.noOmarchyEnv)
            return {EDesktop::None, ESource::ForceOff, "HYPRDRIVE_NO_OMARCHY=1"};

        std::string note; // an ignored bad value, carried into whichever line decides
        const auto  FORCED = [&](int v, ESource src, std::string_view what, const std::string& raw) -> std::optional<SDecision> {
            if (v == 1)
                return SDecision{EDesktop::Omarchy, src, std::string{what} + "=omarchy"};
            if (v == 2)
                return SDecision{EDesktop::None, src, std::string{what} + "=none"};
            if (v < 0 && !raw.empty())
                note += std::string{what} + "=\"" + raw + "\" is not auto|omarchy|none, treated as auto; ";
            return std::nullopt;
        };

        if (auto d = FORCED(parseValue(p.envValue), ESource::Env, "HYPRDRIVE_INTEGRATION", p.envValue))
            return *d;
        if (auto d = FORCED(parseValue(p.configValue), ESource::Config, "plugin:hyprdrive:integration", p.configValue))
            return *d;

        const bool OMARCHY = p.omarchyOnPath && p.omarchyState;
        std::string why    = OMARCHY ? "omarchy on PATH and omarchy state dir present" :
                (!p.omarchyOnPath && !p.omarchyState) ? "no omarchy on PATH, no omarchy state dir" :
                !p.omarchyOnPath                       ? "omarchy state dir present but no omarchy on PATH" :
                                                         "omarchy on PATH but no omarchy state dir";
        return {OMARCHY ? EDesktop::Omarchy : EDesktop::None, ESource::Auto, note + why};
    }
}
