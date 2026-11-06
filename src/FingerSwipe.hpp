#pragma once

#include <hyprland/src/devices/IPointer.hpp>

#include "FingerSwipeModel.hpp"

#include <string>

// The glue between the touchpad's raw fingers (TouchpadRaw), the decisions
// (FingerSwipeModel) and Hyprland: libinput's swipe/pinch/scroll events are
// swallowed while a swipe is ours, and ours are fed to the gesture manager.
namespace ScrollOverview::FingerSwipe {
    void init();
    // Config reload / device hotplug: open touchpads that appeared.
    void rescan();
    // hkOnMouseMoved asks before the motion reaches Hyprland: touchpad motion
    // while a swipe is ours would move the pointer (and fling a held drag).
    bool swallowMotion(const IPointer::SMotionEvent& e);
    void shutdown();

    // hyprdrive:debug gesture (DebugGesture.cpp): one raw touchpad frame, into
    // the very handler TouchpadRaw calls per SYN_REPORT -- and the model's mode
    // ("idle", "native", "continue", "drag-arm", "drag-swipe") for its report.
    void debugFrame(const FingerSwipeModel::SFrame& f);
    std::string debugMode();
}
