#pragma once

// BUSY APPS PULSE (Reddit, r/hyprland: "ability for the icon ellipsis to
// pulsate if an app uses the CPU over a certain threshold"). Off by default:
// plugin:hyprdrive:dock:cpu_pulse, threshold dock:cpu_pulse_threshold (% of
// one core, so 200 = two cores flat out).
//
// Once a second, while the option is on, every process's CPU time is read from
// /proc and an app's load is its window processes' plus all their descendants'
// -- a terminal's work happens in its shell's children, a browser's in its
// helpers. An app over the threshold has its running dots pulse. Nothing is
// sampled while the option is off.

#include <vector>

#include <hyprland/src/desktop/DesktopTypes.hpp>

namespace ScrollOverview::CpuPulse {
    // Arms the once-a-second sampler (PLUGIN_INIT, after the config keys exist).
    void init();
    // PLUGIN_EXIT: the timer goes before the code it calls.
    void shutdown();

    // The option is on and at least one mapped window's app is over the
    // threshold: the dock keeps drawing frames for the pulse.
    bool anyBusy();

    // 0 when these windows' app is under the threshold (or the option is off),
    // otherwise the pulse's phase this frame, 0..1.
    float pulseFor(const std::vector<PHLWINDOW>& windows);
}
