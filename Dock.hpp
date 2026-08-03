#pragma once

#include "globals.hpp"

#include <string>
#include <vector>

// OVERVIEW_CPP_SPEC §13.9 X27. hyprgnomedock's SURFACE: a floating pill at the
// bottom of the monitor, proportioned from the reference Dash to Dock config.
// X25 (live previews) and X26 (drag-to-dock) both need something to draw into
// and drop onto, which is why the surface lands before them.
namespace ScrollOverview::Dock {

struct SItem {
    std::string wmClass;
    std::string icon;    // desktop-entry Icon=, "" when no entry claims the class
    CBox        iconBox; // monitor-local, RENDER px

    // X32. The desktop id, which is what a FAVOURITE is stored as -- and the
    // only handle a pinned-but-not-running app has, since it owns no window and
    // therefore no class. `running` is the split the running dot draws and the
    // click reads: a favourite with no window launches instead of minimizing.
    std::string desktopId;
    bool        favorite = false;
    bool        running  = false;

    // X35. A LOCATION -- the trash, or a mount -- rather than an app. Dash to
    // Dock wraps these as fake ShellApps so its dash can hold them; here they
    // keep their own identity, because every app lookup in Dock.cpp keys on a
    // WINDOW CLASS and a location has none. A non-empty `uri` IS the
    // discriminator, and it is also what activating the item opens.
    std::string uri;
    std::string locationName;
    bool        mount      = false; // so its menu unmounts rather than empties
    bool        canEject   = false;
    bool        mounted    = true;  // false: an fstab point offering Mount instead

    bool        trashEmpty = true;  // no `Empty Trash` row while it is
};

// X25. One minimized window, drawn in the pill as the REAL window, live.
struct SPreview {
    PHLWINDOW window;
    CBox      box; // monitor-local, RENDER px
};

struct SLayout {
    CBox                  pill; // monitor-local, RENDER px; empty when there is nothing to draw
    int                   rounding = 0;
    std::vector<SItem>    items;
    std::vector<SPreview> previews;

    // X32 Show Applications. `show-apps-at-top` false and
    // `show-apps-always-in-the-edge` true, so on a bottom dock it is the LAST
    // slot -- past the previews, hard against the right-hand edge. Empty when
    // `show-apps-button` is off.
    CBox showApps;
};

// Pure geometry, so a test rig can assert proportions without a frame.
SLayout layout(PHLMONITOR monitor);
void    render(PHLMONITOR monitor);

// X26. Is a monitor-local RENDER px point inside the pill? The overview's drop
// handling asks this before it asks any workspace: the pill floats over the main
// area, so the card underneath would otherwise claim the drop.
bool    pillContains(PHLMONITOR monitor, const Vector2D& point);

// X24. A click inside the pill, in the same monitor-local RENDER px as
// pillContains. An icon toggles its app's minimized state
// (`click-action='minimize'`); a preview restores that one window. `shift`
// applies `minimize-shift` -- the whole app rather than just the front window.
// Returns whether an item claimed the click; the caller swallows the event
// either way, since the pill is not a window and must not leak clicks through.
//
// X33. `middle` runs `middle-click-action` / `shift-middle-click-action`
// instead, which reach ICONS only -- the reference hangs middle-click off the
// AppIcon, so previews and Show Applications are not targets for it.
bool    click(PHLMONITOR monitor, const Vector2D& point, bool shift, bool middle = false);

// X33. A wheel tick over the pill, `up` for one notch away from the user.
// `scroll_action` decides: `cycle-windows` steps through the windows of the icon
// under the pointer, `switch-workspace` moves to the neighbouring workspace from
// anywhere on the pill, `do-nothing` does nothing. All three SWALLOW the tick,
// which is what the return value says -- true whenever the point is on the pill,
// because the pill is not a window and a tick must not leak to the tile under it.
// The reference's two behaviours are ONE setting and are mutually exclusive; see
// the note beside the key in Config.cpp for why `scroll-switch-workspace` is not
// a key of its own.
bool    scroll(PHLMONITOR monitor, const Vector2D& point, bool up);

// X32 reordering and G12 share ONE drop handler, per G12's "the two drag
// sources land in the same dock drop handler and must not fight". Both end in
// pinAt(): a favourite being moved and a search result being pinned are the
// same edit to the same stored list, one at an index it already holds and one
// at an index it does not.
//
// The insertion index a monitor-local RENDER px point names, counted in
// FAVOURITE SLOTS as they are drawn -- 0 before the first icon, size() past the
// last. -1 when the point is not over the pill at all.
int  dropIndexAt(PHLMONITOR monitor, const Vector2D& point);

// X32/G12. Is the point over the Show Applications button? G12 drops there to
// UNPIN, so the caller has to tell the two targets apart before it commits.
bool showAppsContains(PHLMONITOR monitor, const Vector2D& point);

// Move `desktopId` to `index` among the favourites, inserting it if it is not
// one yet. Writes the store. `index` counts the favourites this machine
// actually provides; a stored id nothing provides is never drawn and keeps its
// place.
void pinAt(const std::string& desktopId, int index);
void unpin(const std::string& desktopId);

// X32. The dock's own drag, which is why the pill's press is no longer its
// click: press remembers, motion past the threshold commits to a drag, and only
// the release decides which of the two gestures happened.
bool dragBegin(PHLMONITOR monitor, const Vector2D& point);
bool dragMove(PHLMONITOR monitor, const Vector2D& point);
bool dragEnd(PHLMONITOR monitor, const Vector2D& point);
void dragCancel();
bool dragPending();
bool dragging();

// G12. A foreign drag (a search result) over the pill lights the same insertion
// caret the dock's own drag draws. -1 clears it.
void setForeignInsert(int index);

// X28. The GNOME app-icon menu, opened by a right-click over an icon. It floats
// above the pill and outlives the press, so while it is up it takes every
// pointer press and a press that misses it dismisses it.
//
// The row boxes are laid out during render() -- measuring a label means asking
// the renderer for its texture, which is only legal inside the pass -- so
// menuContains/menuClick answer against the LAST frame's geometry. That is the
// frame the user is looking at when they click, which is the one that matters.
bool openMenu(PHLMONITOR monitor, const Vector2D& point);
bool menuOpen();
void closeMenu();
bool menuContains(PHLMONITOR monitor, const Vector2D& point);
bool menuClick(PHLMONITOR monitor, const Vector2D& point);

// X34. A hotkey press. `number` is the reference's 1..10 -- the SLOT, so the
// tenth app is 10 even though its key is <Super>0 -- and not a keycap, so a
// config that rebinds the digits still names the same app. `shift` and `ctrl`
// are the modifier the binding carries and they pick the same three behaviours
// a click does: plain runs `click-action`, shift runs `shift-click-action`,
// ctrl opens a new window. Out of range is not an error -- the reference
// activates nothing and still shows the overlay, which is what tells you the
// slot is empty.
void hotkey(int number, bool shift, bool ctrl);

// X34. `<Super>q`: show the number overlay for `shortcut_timeout`, and reveal
// the dock while it is up if `hotkeys_show_dock`. Also runs after every hotkey.
void showOverlay();

// X34. Is the overlay up right now? For the acceptance rig, which has to know
// what the frame it is about to capture is supposed to contain.
// Damage the monitor when the pill's shape changes -- an app opening or closing,
// the dock being switched off, the hovered icon moving -- and every frame while a
// live preview is in it. MUST be called before the frame is rendered: damage
// asked for during the pass is cleared with the rest of the frame's ring.
//
// Returns whether the pill's appearance actually changed. The overview throttles
// scheduleFrame while it is open, so a plain damageMonitor from here is swallowed
// -- it has to answer with requestInputFrame() instead, and this is how it knows.
bool damageIfChanged(PHLMONITOR monitor);

// X30. Feed the autohide pressure barrier with RELATIVE pointer motion. The
// bus's mouse.move carries the absolute position, and at the bottom edge the
// cursor is clamped -- so its position stops changing while the user is still
// pushing into the barrier, and pressure derived from it would read every push
// as zero.
void feedPointerMotion(const Vector2D& delta);

// OVERVIEW_CPP_SPEC 13.12 X54. Minimize / restore WITH the shrink-into-the-icon
// flight. Everything that minimizes must come through these, not through
// Minimize:: directly -- the dispatcher did exactly that and so a keybind
// minimize never animated at all.
void minimizeWithFlight(PHLMONITOR monitor, PHLWINDOW window);
void restoreWithFlight(PHLMONITOR monitor, PHLWINDOW window);

}
