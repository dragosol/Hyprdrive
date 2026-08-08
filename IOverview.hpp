#pragma once
#include <hyprland/src/desktop/DesktopTypes.hpp>
#include <hyprland/src/SharedDefs.hpp> // WORKSPACEID
#include <hyprland/src/helpers/memory/Memory.hpp>
#include <hyprland/src/helpers/math/Math.hpp>
#include <hyprland/src/helpers/time/Time.hpp>

#include <string>
#include <vector>

class CWLSurfaceResource;

class IOverview {
  public:
    IOverview()          = default;
    virtual ~IOverview() = default;

    virtual void  render()           = 0;
    virtual void  performPrimaryClickAction() = 0;
    virtual void  damage()           = 0;
    virtual void  requestInputFrame() = 0;
    virtual bool  shouldHandleSurfaceDamage(SP<CWLSurfaceResource> surface) = 0;
    virtual bool  shouldAllowSurfaceFrame(SP<CWLSurfaceResource> surface, const Time::steady_tp& now) = 0;
    virtual bool  shouldAllowRealtimePreviewSchedule() = 0;
    virtual bool  shouldSuppressRenderDamage() const = 0;
    virtual void  onPreRender()      = 0;

    virtual void  setClosing(bool closing) = 0;

    // A closing overview stays registered until its animation ends, so "exists"
    // and "is open" are not the same question. Everything that decides whether
    // to open or to close must ask this one -- otherwise a tap during the close
    // animation reads as "already open" and is thrown away.
    virtual bool  isClosing() const = 0;

    // Reverse a close that is still animating. Cheap on purpose: the window
    // images, the blur framebuffers and the input hooks are all still alive at
    // this point, so this re-arms them instead of rebuilding them.
    virtual void  reopen() = 0;

    virtual void  resetSwipe()                = 0;
    virtual void  onSwipeUpdate(double delta) = 0;
    virtual void  onSwipeEnd()                = 0;

    virtual void  close()                  = 0;
    virtual void  selectHoveredWorkspace() = 0;
    virtual bool  moveSelection(const std::string& direction) = 0;
    virtual bool  windowDispatcherAction(const std::string& action) = 0;

    // X24. Where a window is DRAWN in the overview, monitor-local render px.
    // The dock is only ever on screen while the overview is, so a minimize
    // started from it has to shrink from the tile the user is looking at, not
    // from the window's real geometry underneath it.
    virtual CBox  tileBox(const PHLWINDOW& window) const = 0;
    // Z8. A GLOBAL LOGICAL box transformed into the overview's rendering of a
    // given desktop's card. The restore flight aims a MINIMIZED window here:
    // it has no tile (Y9 reveals minimized windows only under a filter), and
    // the offscreen fallback aimed at the NEXT desktop for a window whose home
    // IS the active one.
    virtual CBox  overviewBoxForGlobal(WORKSPACEID workspaceId, const CBox& globalBox) const = 0;
    // Z20. Rebuild the per-card window lists from live state. setHidden fires
    // no compositor event, so a window unhidden at a flight's landing is
    // otherwise never re-added to workspaceImage->windows -- the grid and
    // hit-test see it (live iteration) while the render (list walk) does not:
    // a clickable, invisible tile.
    virtual void  refreshWindows() = 0;

    // X28. Commit the overview's selection to one window and close, the way a
    // tile click does. The dock's right-click window list needs exactly this:
    // focusing the window directly would be overwritten by close()'s own
    // selection, which is also where X43's raise lives.
    virtual bool  selectAndClose(const PHLWINDOW& window) = 0;

    bool          blockDamageReporting   = false;

    PHLMONITORREF pMonitor;
    bool          m_isSwiping = false;
};

const std::vector<SP<IOverview>>& scrollOverviews();
SP<IOverview>                     scrollOverviewForMonitor(PHLMONITOR monitor);
SP<IOverview>                     scrollOverviewAt(const Vector2D& point);
SP<IOverview>                     activeScrollOverview();
void                              registerScrollOverview(const SP<IOverview>& overview);
void                              unregisterScrollOverview(IOverview* overview);
void                              clearScrollOverviews();

// X32. Open the overview on a monitor, exactly as the dispatcher does -- the
// Show Applications button is the first caller outside the dispatcher itself.
// Already open, or no monitor: a no-op that reports success.
bool                              openScrollOverview(PHLMONITOR monitor);

// Current interaction/render context. The authoritative state is the registry.
inline SP<IOverview> g_pScrollOverview;
