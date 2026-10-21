// See XGeometry.hpp.
#include "XGeometry.hpp"
#include "ConfigureHold.hpp"

#include <chrono>
#include <cmath>
#include <cstdlib>
#include <vector>

#include <xcb/xcb.h>

#include <hyprland/src/debug/log/Logger.hpp>
#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/managers/XWaylandManager.hpp>
#include <hyprland/src/managers/fullscreen/FullscreenController.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/xwayland/XSurface.hpp>
#include <hyprland/src/xwayland/XWayland.hpp>

namespace ScrollOverview::XGeometry {
    namespace {
        using Clock = std::chrono::steady_clock;

        // A client that keeps asking for its own box would otherwise be told
        // ours on every motion event.
        constexpr auto    RESEND = std::chrono::milliseconds(500);
        // The clip check costs a few X round trips; motion comes at 1 kHz.
        constexpr auto    CLIPCHECK = std::chrono::milliseconds(200);
        Clock::time_point g_lastSend;
        Clock::time_point g_lastClipCheck;

        // Our own X client: Hyprland's WM connection is private, and an
        // override-redirect window takes a configure from any client.
        xcb_connection_t* g_conn = nullptr;

        bool              differs(double a, double b) {
            return std::abs(std::round(a) - std::round(b)) > 1.0;
        }

        xcb_connection_t* connection() {
            if (g_conn && !xcb_connection_has_error(g_conn))
                return g_conn;
            shutdown();
            // Hyprland exports XWayland's display once it is up.
            const char* DISPLAY = getenv("DISPLAY");
            if (!g_pXWayland || !DISPLAY || !*DISPLAY)
                return nullptr;
            g_conn = xcb_connect(DISPLAY, nullptr);
            if (xcb_connection_has_error(g_conn)) {
                shutdown();
                return nullptr;
            }
            return g_conn;
        }

        bool inside(int px, int py, int x, int y, int w, int h) {
            return px >= x && py >= y && px < x + w && py < y + h;
        }

        void checkBox(const PHLWINDOW& window, const SP<CXWaylandSurface>& xsurface) {
            const auto HAS  = xsurface->m_geometry;
            const auto POS  = window->realToReportPosition();
            const auto SIZE = window->realToReportSize();
            if (!differs(HAS.x, POS.x) && !differs(HAS.y, POS.y) && !differs(HAS.width, SIZE.x) && !differs(HAS.height, SIZE.y))
                return;

            const auto NOW = Clock::now();
            if (NOW - g_lastSend < RESEND)
                return;
            g_lastSend = NOW;

            Log::logger->log(Log::DEBUG, "[hyprdrive] X has {} {}x{} at {},{}, Hyprland draws it {}x{} at {},{}: telling X again", window->m_class, HAS.width,
                             HAS.height, HAS.x, HAS.y, SIZE.x, SIZE.y, POS.x, POS.y);
            window->sendWindowSize(true);
        }

        void checkClip(const PHLWINDOW& window, const SP<CXWaylandSurface>& xsurface) {
            const auto NOW = Clock::now();
            if (NOW - g_lastClipCheck < CLIPCHECK)
                return;
            g_lastClipCheck = NOW;

            const auto BOX    = xsurface->m_geometry;
            const auto CURSOR = g_pXWaylandManager->waylandToXWaylandCoords(g_pInputManager->getMouseCoordsInternal());
            const int  CX = std::lround(CURSOR.x), CY = std::lround(CURSOR.y);
            if (!inside(CX, CY, BOX.x, BOX.y, BOX.width, BOX.height))
                return;

            const auto CONN = connection();
            if (!CONN)
                return;
            const auto ROOT = xcb_setup_roots_iterator(xcb_get_setup(CONN)).data->root;

            auto*      ptr = xcb_query_pointer_reply(CONN, xcb_query_pointer(CONN, ROOT), nullptr);
            if (!ptr)
                return;
            const int PX = ptr->root_x, PY = ptr->root_y;
            free(ptr);
            // XWayland is a motion event behind at most; a pinned pointer is
            // far off.
            if (std::abs(PX - CX) <= 2 && std::abs(PY - CY) <= 2)
                return;

            auto* tree = xcb_query_tree_reply(CONN, xcb_query_tree(CONN, ROOT), nullptr);
            if (!tree)
                return;
            const auto*                                  KIDS = xcb_query_tree_children(tree);
            const int                                    N    = xcb_query_tree_children_length(tree);
            std::vector<xcb_get_window_attributes_cookie_t> attrs;
            std::vector<xcb_get_geometry_cookie_t>          geoms;
            for (int i = 0; i < N; ++i) {
                attrs.push_back(xcb_get_window_attributes(CONN, KIDS[i]));
                geoms.push_back(xcb_get_geometry(CONN, KIDS[i]));
            }

            bool moved = false;
            for (int i = 0; i < N; ++i) {
                auto* a = xcb_get_window_attributes_reply(CONN, attrs[i], nullptr);
                auto* g = xcb_get_geometry_reply(CONN, geoms[i], nullptr);
                // The grab window: input-only, unmanaged, shown, holding X's
                // pointer where Hyprland's cursor is not.
                if (a && g && a->_class == XCB_WINDOW_CLASS_INPUT_ONLY && a->override_redirect && a->map_state == XCB_MAP_STATE_VIEWABLE &&
                    inside(PX, PY, g->x, g->y, g->width, g->height) && !inside(CX, CY, g->x, g->y, g->width, g->height)) {
                    Log::logger->log(Log::DEBUG, "[hyprdrive] {} clips the pointer to {}x{} at {},{} (X pointer {},{}, cursor {},{}): clipping to {}x{} at {},{}",
                                     window->m_class, g->width, g->height, g->x, g->y, PX, PY, CX, CY, BOX.width, BOX.height, BOX.x, BOX.y);
                    const uint32_t VALUES[] = {sc<uint32_t>(sc<int32_t>(BOX.x)), sc<uint32_t>(sc<int32_t>(BOX.y)), sc<uint32_t>(BOX.width), sc<uint32_t>(BOX.height)};
                    xcb_configure_window(CONN, KIDS[i], XCB_CONFIG_WINDOW_X | XCB_CONFIG_WINDOW_Y | XCB_CONFIG_WINDOW_WIDTH | XCB_CONFIG_WINDOW_HEIGHT, VALUES);
                    moved = true;
                }
                free(a);
                free(g);
            }
            free(tree);
            if (moved)
                xcb_flush(CONN);
        }
    }

    void check() {
        if (ConfigureHold::held())
            return;

        const auto WINDOW = Desktop::focusState()->window();
        if (!WINDOW || !WINDOW->m_isX11 || !WINDOW->m_isMapped || !Fullscreen::controller()->isFullscreen(WINDOW))
            return;
        if (WINDOW->positionAnimation()->isBeingAnimated() || WINDOW->sizeAnimation()->isBeingAnimated())
            return;

        const auto XSURFACE = WINDOW->m_xwaylandSurface.lock();
        if (!XSURFACE || !XSURFACE->m_mapped)
            return;

        checkBox(WINDOW, XSURFACE);
        checkClip(WINDOW, XSURFACE);
    }

    void shutdown() {
        if (g_conn)
            xcb_disconnect(g_conn);
        g_conn = nullptr;
    }
}
