#pragma once

#include <hyprland/src/managers/input/trackpad/gestures/ITrackpadGesture.hpp>

class COverviewGesture : public ITrackpadGesture {
  public:
    COverviewGesture()              = default;
    virtual ~COverviewGesture()     = default;

    virtual void begin(const ITrackpadGesture::STrackpadGestureBegin& e);
    virtual void update(const ITrackpadGesture::STrackpadGestureUpdate& e);
    virtual void end(const ITrackpadGesture::STrackpadGestureEnd& e);

  private:
    float m_lastDelta   = 0.F;
    bool  m_firstUpdate = false;
};
