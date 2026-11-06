#pragma once

#include <string>
#include <string_view>

// `hyprdrive:debug gesture <script>`: synthetic touchpad gestures played into
// the same entry points real ones take (DebugGestureScript.hpp has the script
// language and where each step goes in). For headless and nested tests, which
// have no touchpad.
namespace ScrollOverview::DebugGesture {
    // Parse and queue `script` (everything after "gesture"); "" on success,
    // else the parse error. Steps run from the event loop, in order, after any
    // still queued -- so `swipe 3 up 200 hold` then `swipe end` compose.
    // `state` instead returns a one-line report and queues nothing; `stop`
    // drops whatever is queued (a gesture left open stays open: end it).
    std::string run(std::string_view script, bool& isReport);
    // Plugin unload: the step timer would fire into unloaded code.
    void shutdown();
}
