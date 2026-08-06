#pragma once

#include "globals.hpp"
#include <hyprland/src/helpers/time/Time.hpp>

#include <hyprland/src/config/ConfigManager.hpp>
#include <hyprland/src/config/ConfigValue.hpp>
#include <hyprland/src/config/shared/complex/ComplexDataTypes.hpp>

#include <optional>
#include <string>
#include <type_traits>
#include <unordered_map>

namespace ScrollOverview::Config {

using TDispatcher       = SDispatchResult (*)(std::string);
using TGestureKeyword   = Hyprlang::CParseResult (*)(const char* LHS, const char* RHS);
using TGestureRegistrar   = SDispatchResult (*)(size_t fingerCount, const std::string& direction, const std::string& action, const std::string& mods, float deltaScale,
                                                bool disableInhibit);

enum class ELayout {
    VERTICAL,
    HORIZONTAL,
};

enum class EScrollAction {
    WORKSPACE,
    COLUMN,
};

void registerDispatcher(const std::string& name, TDispatcher dispatcher);
void registerGesture(TGestureRegistrar gestureRegistrar, TGestureKeyword gestureKeyword);
void registerConfig();

template <typename T>
CConfigValue<T>& valueRef(const std::string& name) {
    static std::unordered_map<std::string, UP<CConfigValue<T>>> values;

    const auto [it, inserted] = values.try_emplace(name);
    if (inserted)
        it->second = makeUnique<CConfigValue<T>>(name);

    return *it->second;
}

template <typename T>
T getValue(const std::string& name) {
    using TValue = std::decay_t<T>;

	if constexpr (std::is_same_v<TValue, ::Config::CGradientValueData>) {
        auto& ref = valueRef<::Config::IComplexConfigValue>(name);
        if (!ref.good())
            return {};
        return *sc<::Config::CGradientValueData*>(ref.ptr());
    }

    if constexpr (std::is_same_v<TValue, bool>)
        return *valueRef<Hyprlang::INT>(name) != 0;
    else if constexpr (std::is_integral_v<TValue> && !std::is_same_v<TValue, bool>)
        return sc<TValue>(*valueRef<Hyprlang::INT>(name));
    else if constexpr (std::is_floating_point_v<TValue>)
        return sc<TValue>(*valueRef<Hyprlang::FLOAT>(name));
    else
        return *valueRef<TValue>(name);
}

template <typename T>
T* getValuePtr(const std::string& name) {
    return valueRef<T>(name).ptr();
}

template <typename T>
void setValue(const std::string& name, const T& value) {
    using TValue = std::decay_t<T>;

    if constexpr (std::is_same_v<TValue, bool>)
        *getValuePtr<Hyprlang::INT>(name) = value ? 1 : 0;
    else if constexpr (std::is_integral_v<TValue> && !std::is_same_v<TValue, bool>)
        *getValuePtr<Hyprlang::INT>(name) = sc<Hyprlang::INT>(value);
    else if constexpr (std::is_floating_point_v<TValue>)
        *getValuePtr<Hyprlang::FLOAT>(name) = sc<Hyprlang::FLOAT>(value);
    else
        *getValuePtr<TValue>(name) = value;
}

int           getGestureDistance();
// X56 (user, 2026-08-06): "pick a different colour from the hyprland theme
// colours, something brighter and easier to see".
//
// general:col.active_border is NOT the theme's accent on this rice -- matugen
// fills it from `outline_variant`, which is a dark warm brown that sits within
// a few units of the blurred wallpaper. X61 already had to draw the selection
// ring OPAQUE and 4px thick just to make it visible against that.
//
// So the highlight reads its own key, `plugin:scrolloverview:col_highlight`,
// which the matugen template fills from `primary` -- the same bright colour the
// pinned-window rule already uses. It regenerates with every theme change, so
// the highlights follow the theme without the plugin having to read quickshell's
// palette behind Hyprland's back.
//
// Alpha 0 means UNSET: fall back to col.active_border, so a machine without the
// template line behaves exactly as before.
CHyprColor    highlightColor();

// Type to put ON the highlight. The selection fill is OPAQUE (X2: a selection
// that can be mistaken for a hover is not a selection), so whatever sits on it
// is reading against the accent itself, not against the dark card. With a dark
// accent that means white; with a bright one -- which is the whole point of
// col_highlight -- white is the low-contrast case the user reported as the
// highlight "overpowering the fonts".
CHyprColor    highlightForeground();

float         getScale();
float         getOpenSpeed();
float         getCloseSpeed();
int           getWorkspaceGap();
ELayout       getLayout();
int           getScrollEventDelay();
bool          getLeftHanded();
int           getDragMode();
int           getDragThreshold();

// GLOBAL ANIMATION SPEED (user, 2026-08-06). One multiplier over every timed
// thing in the plugin. 1.0 is the shipped feel; 10.0 runs everything at a tenth
// speed so a single frame can be looked at properly.
//
// Deliberately applied at the ONE place elapsed time is measured, not by editing
// durations: every constant in the codebase keeps its real, meaningful value
// (GNOME's 400ms minimize stays the number 400 and can still be checked against
// the host), and nothing has to be un-edited afterwards.
float         animScale();

// Milliseconds since `since`, DIVIDED by animScale -- so a clock that runs slow
// makes every duration comparison downstream stretch, with no other changes.
float         animElapsedMs(const Time::steady_tp& since);
float         getDragMiniScale();
int           getDragMiniMs();
int           getDragRecentreMs();
float         getTouchpadScrollFactor();
EScrollAction getVerticalScrollAction(ELayout layout);
EScrollAction getHorizontalScrollAction(ELayout layout);
int           getWallpaperMode();
bool          getBlur();
std::string   getTerminal();
bool          getMissionControl();
int           getMissionControlGap();
int           getMissionControlReflowMs();
bool          getStrip();
int           getStripHeight();
int           getStripGap();
bool          getTapSuper();
int           getTapSuperTimeoutMs();
::Config::CCssGapData getCssGapData(const std::string& name);
int          getShadowEnabled();
int          getShadowRange();
int          getShadowRenderPower();
std::optional<::Config::CGradientValueData> getShadowColor();

}
