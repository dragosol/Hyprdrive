#pragma once

#include <hyprland/src/managers/input/trackpad/gestures/ITrackpadGesture.hpp>

class COverviewGesture : public ITrackpadGesture {
  public:
    COverviewGesture()              = default;
    ~COverviewGesture() override = default;

    void begin(const ITrackpadGesture::STrackpadGestureBegin& e) override;
    void update(const ITrackpadGesture::STrackpadGestureUpdate& e) override;
    void end(const ITrackpadGesture::STrackpadGestureEnd& e) override;

  private:
    float m_lastDelta   = 0.F;
    bool  m_firstUpdate = false;
};
