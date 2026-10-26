// The "mosaic" layout: see Mosaic.hpp and MosaicPack.hpp.
#include "Mosaic.hpp"
#include "MosaicPack.hpp"
#include "MosaicCanvas.hpp"
#include "IOverview.hpp"
#include "DebugPaths.hpp"
#include "Dock.hpp"

#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/layout/algorithm/Algorithm.hpp>
#include <hyprland/src/layout/algorithm/TiledAlgorithm.hpp>
#include <hyprland/src/layout/space/Space.hpp>
#include <hyprland/src/layout/target/Target.hpp>
#include <hyprland/src/managers/fullscreen/FullscreenController.hpp>
#include <hyprland/src/managers/fullscreen/handler/FullscreenHandler.hpp>
#include <hyprland/src/config/ConfigValue.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/state/MonitorState.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/state/ViewState.hpp>
#include <hyprland/src/desktop/state/ViewHitTester.hpp>
#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/layout/LayoutManager.hpp>
#include <hyprland/src/layout/supplementary/DragController.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/managers/KeybindManager.hpp>
#include <hyprland/src/pointer/cursor/CursorShapeOverrideController.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <hyprland/src/config/shared/actions/ConfigActions.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include "Config.hpp"
#include <linux/input-event-codes.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <format>
#include <fstream>
#include <sstream>
#include <typeinfo>
#include <unordered_map>
#include <vector>

// main.cpp: Super held to pan the canvas is not a Super tap.
namespace ScrollOverview {
    void cancelSuperTap();
}

namespace ScrollOverview::Mosaic {

    class CMosaicAlgorithm;
    // Every live mosaic layout -- one per desktop on mosaic. Hyprland keeps the
    // algorithm behind a desktop private, so "is this window on a mosaic
    // desktop" is answered from here instead.
    static std::vector<CMosaicAlgorithm*> g_instances;

    // ---------------------------------------------------------- remembered sizes --
    // AN APP'S MOSAIC SIZE (user, 2026-10-11: "if i close a particular app at
    // that size DURING MOSAIC then that becomes the app's default size when
    // mosaic is open. dwindle and scrolling modes don't apply"). Keyed on the
    // app's class; learned only when a window CLOSES while its desktop is in the
    // mosaic arrangement (not its tiles), and used only by mosaic. One line per
    // app: class<TAB>width<TAB>height, in $XDG_STATE_HOME/hyprdrive/mosaic-sizes.
    namespace {
        std::unordered_map<std::string, Vector2D> g_sizes;
        bool                                      g_sizesLoaded = false;

        std::filesystem::path sizesPath() {
            if (const char* S = std::getenv("XDG_STATE_HOME"); S && *S)
                return std::filesystem::path{S} / "hyprdrive" / "mosaic-sizes";
            const char* HOME = std::getenv("HOME");
            return std::filesystem::path{HOME ? HOME : "/tmp"} / ".local" / "state" / "hyprdrive" / "mosaic-sizes";
        }

        void loadSizes() {
            if (g_sizesLoaded)
                return;
            g_sizesLoaded = true;
            std::ifstream in(sizesPath());
            std::string   line;
            while (std::getline(in, line)) {
                const auto T1 = line.find('\t'), T2 = line.find('\t', T1 == std::string::npos ? 0 : T1 + 1);
                if (T1 == std::string::npos || T2 == std::string::npos)
                    continue;
                try {
                    g_sizes[line.substr(0, T1)] = Vector2D{std::stod(line.substr(T1 + 1, T2 - T1 - 1)), std::stod(line.substr(T2 + 1))};
                } catch (...) {}
            }
        }

        void saveSize(const std::string& app, const Vector2D& size) {
            loadSizes();
            const auto OLD = g_sizes.find(app);
            if (OLD != g_sizes.end() && std::abs(OLD->second.x - size.x) < 1 && std::abs(OLD->second.y - size.y) < 1)
                return; // nothing new: no write
            g_sizes[app] = size;
            std::error_code ec;
            std::filesystem::create_directories(sizesPath().parent_path(), ec);
            std::ostringstream out;
            for (const auto& [K, V] : g_sizes)
                out << K << '\t' << std::lround(V.x) << '\t' << std::lround(V.y) << '\n';
            const auto TMP = sizesPath().string() + ".tmp";
            if (std::ofstream f(TMP); f) {
                f << out.str();
                f.close();
                std::filesystem::rename(TMP, sizesPath(), ec);
            }
        }

        std::string appOf(const PHLWINDOW& w) {
            if (!w)
                return {};
            return !w->m_initialClass.empty() ? w->m_initialClass : w->m_class;
        }

        // A WINDOW'S MOSAIC SIZE, for as long as the window lives (user,
        // 2026-10-15: "when I toggle out of mosaic into dwindle ... windows
        // remember their sizes during pure mosaic"). The layout's own list
        // dies with it: Super+L to dwindle destroys this desktop's mosaic, and
        // the one Super+L builds again was handed every window at its DWINDLE
        // tile (desiredGeometry() is the window's current size) -- 941x1056,
        // 941x616, 941x521 for three windows that had been 900x600, 380x636 and
        // 595x442 -- which no longer fit, so it came back tiled and stayed so.
        // The same held for a window moved to another desktop and back. Kept
        // per WINDOW (a weak reference: a closed window's entry lapses, and a
        // new window at a reused address is not mistaken for it), outside every
        // layout instance, and written whenever a mosaic lays its desktop out.
        //
        // One exception, the old rule: a window that was FLOATED and resized
        // there (Super+V, a new size, Super+V) comes back at its floating size.
        // Hyprland rewrites the floating size on every workspace move, so a
        // changed one alone proves nothing: it counts only when the window
        // really floated since it left (the window.floating event) and its
        // floating size moved from what it was when it left. A Super+drag move
        // floats the window too; that float is not counted (onFloating), so a
        // dragged window keeps its own size even if its client resized itself.
        struct SKept {
            PHLWINDOWREF window;
            Vector2D     size;
            Vector2D     floatAtLeave;      // its floating size when it left a mosaic
            bool         floatedSince = false;
            bool         trusted      = true; // MosaicPack::SNatural::trusted
        };
        std::vector<SKept> g_windowSizes;

        SKept* keptOf(const PHLWINDOW& w) {
            for (auto& e : g_windowSizes)
                if (e.window && e.window.lock() == w)
                    return &e;
            return nullptr;
        }

        void rememberWindow(const PHLWINDOW& w, const Vector2D& size, bool trusted = true) {
            if (!w)
                return;
            std::erase_if(g_windowSizes, [](const SKept& e) { return !e.window; });
            if (auto* e = keptOf(w)) {
                e->size         = size;
                e->floatedSince = false;
                e->trusted      = trusted;
                return;
            }
            g_windowSizes.push_back({.window = w, .size = size, .trusted = trusted});
        }
        bool keptTrusted(const PHLWINDOW& w) {
            const auto* e = keptOf(w);
            return !e || e->trusted;
        }

        void leftMosaic(const SP<Layout::ITarget>& t) {
            if (auto* e = keptOf(t ? t->window() : PHLWINDOW{})) {
                e->floatAtLeave = t->lastFloatingSize();
                e->floatedSince = false;
            }
        }

        void onFloating(const PHLWINDOW& w) {
            if (!w || !w->m_isFloating)
                return;
            // A Super+drag floats the window for the drag: that is not the
            // user floating it (user, 2026-10-15, fedora: dragging Steam --
            // an X11 client that resizes itself when floated -- came back at
            // 490x308, its kept 511x926 thrown away as "floated and resized").
            if (g_layoutManager)
                if (const auto DRAGGED = g_layoutManager->dragController()->target(); DRAGGED && DRAGGED->window() == w)
                    return;
            if (auto* e = keptOf(w))
                e->floatedSince = true;
        }

        // ACROSS A PLUGIN RELOAD (user, 2026-10-15: after a reload desktop 1
        // went to the tiles and never came back). Unloading hands every desktop
        // to dwindle, and a reloaded plugin starts with no kept sizes, so each
        // window re-arrived at its DWINDLE TILE as its own size (Pear Messages:
        // 1903x2094, full height) and the mosaic could never fit again. The
        // kept sizes now go to a file in XDG_RUNTIME_DIR on unload, stamped
        // with this Hyprland's instance, and come back on load before any
        // window re-arrives. Window addresses hold across a plugin reload.
        std::string keptStamp() {
            const char* SIG = std::getenv("HYPRLAND_INSTANCE_SIGNATURE");
            return SIG ? SIG : "";
        }
        void saveKept() {
            std::ofstream f(ScrollOverview::DebugPaths::path("hyprdrive-mosaic-kept"), std::ios::trunc);
            if (!f)
                return;
            f << keptStamp() << '\n';
            for (const auto& e : g_windowSizes)
                if (const auto W = e.window.lock())
                    f << std::format("{:x} {} {} {}\n", (uintptr_t)W.get(), e.size.x, e.size.y, e.trusted ? 1 : 0);
        }
        void loadKept() {
            const auto     PATH = ScrollOverview::DebugPaths::path("hyprdrive-mosaic-kept");
            std::ifstream  f(PATH);
            std::string    stamp;
            if (!f || !std::getline(f, stamp) || stamp != keptStamp() || stamp.empty())
                return;
            std::unordered_map<uintptr_t, std::pair<Vector2D, bool>> saved;
            std::string                                              line;
            while (std::getline(f, line)) {
                std::istringstream in(line);
                std::string        addr;
                double             w = 0, h = 0;
                int                trusted = 1;
                if (in >> addr >> w >> h) {
                    in >> trusted;
                    saved[std::stoull(addr, nullptr, 16)] = {Vector2D{w, h}, trusted != 0};
                }
            }
            for (const auto& W : Desktop::windowState()->windows())
                if (W)
                    if (const auto IT = saved.find((uintptr_t)W.get()); IT != saved.end())
                        rememberWindow(W, IT->second.first, IT->second.second);
            std::error_code ec;
            std::filesystem::remove(PATH, ec);
        }

        std::optional<Vector2D> rememberedWindow(const SP<Layout::ITarget>& t) {
            const auto* e = keptOf(t ? t->window() : PHLWINDOW{});
            if (!e)
                return std::nullopt;
            const auto F = t->lastFloatingSize();
            if (e->floatedSince && (std::abs(F.x - e->floatAtLeave.x) > 2 || std::abs(F.y - e->floatAtLeave.y) > 2))
                return std::nullopt; // floated and resized there: its floating size decides
            return e->size;
        }
    }

    // One window of the layout, in arrival order (the order the rows read).
    struct SMosaicEntry {
        WP<Layout::ITarget> target;
        Vector2D            natural; // the size the window keeps in the mosaic
        // Its leaf in the TILES' dwindle tree. The tree keeps its own splits,
        // so the tiles never change the size the mosaic gives back (user,
        // 2026-10-14: "coming out of the tiling hybrid mode, windows need to
        // assume the shape and size they were at pre-tiling").
        long long           id = 0;
        bool                trusted = true; // may become its app's size on close
    };

    // TRACE, for the next odd recording: `touch $XDG_RUNTIME_DIR/hyprdrive-mosaic.on`
    // and every resize step and arrangement decision lands in
    // $XDG_RUNTIME_DIR/hyprdrive-mosaic.log (DebugPaths.hpp).
    static bool traceOn() {
        static bool                                  on      = false;
        static std::chrono::steady_clock::time_point checked = {};
        const auto                                   NOW     = std::chrono::steady_clock::now();
        if (NOW - checked > std::chrono::seconds(1)) {
            checked = NOW;
            std::error_code ec;
            on      = std::filesystem::exists(ScrollOverview::DebugPaths::path("hyprdrive-mosaic.on"), ec);
        }
        return on;
    }
    static void trace(const std::string& line) {
        if (!traceOn())
            return;
        if (std::ofstream f(ScrollOverview::DebugPaths::path("hyprdrive-mosaic.log"), std::ios::app); f)
            f << std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count() % 100000000 << ' ' << line << '\n';
    }

    // THE INFINITE CANVAS (MosaicCanvas.hpp; user, 2026-10-26). Off: a mosaic
    // that no longer fits tiles, as before. On: it spills onto a canvas the view
    // pans across -- a strip (horizontal) or a grid (all directions).
    static bool canvasOn() {
        return ScrollOverview::Config::getValue<bool>("plugin:hyprdrive:mosaic:infinite_canvas");
    }
    static bool canvasAllDirections() {
        return ScrollOverview::Config::getValue<std::string>("plugin:hyprdrive:mosaic:canvas_directions") == "all";
    }
    // A swipe or a Super-pan is moving the view: focus landing on a window
    // under the pointer must not pull the view back to it mid-pan.
    static bool g_canvasPanning = false;

    class CMosaicAlgorithm : public Layout::ITiledAlgorithm {
      public:
        CMosaicAlgorithm() {
            g_instances.push_back(this);
            // The canvas follows focus (a click, Super+arrows, the dock, a new
            // window): the focused window is brought into view, as the
            // scrolling layout brings its column.
            // Not focus that follows the mouse: hovering a window half off the
            // edge would slide the canvas, put another window under the
            // pointer, focus that, and slide again. A click does reveal.
            m_focusHook = Event::bus()->m_events.window.active.listen([this](PHLWINDOW w, Desktop::eFocusReason reason) {
                if (m_asCanvas && !g_canvasPanning && w && holds(w) && reason != Desktop::FOCUS_REASON_FFM)
                    revealWindow(w);
            });
            // The canvas settings changed (the settings panel writes them and
            // Hyprland reloads): a desktop on the canvas re-arranges at once, and
            // one in the tiles goes onto the canvas when it was just turned on.
            m_reloadHook = Event::bus()->m_events.config.reloaded.listen([this] {
                if (m_asCanvas || (!m_asMosaic && !m_entries.empty() && canvasOn())) {
                    m_revealPending = true;
                    recalculate();
                }
            });
        }
        ~CMosaicAlgorithm() override {
            std::erase(g_instances, this);
        }

        // For the corner grab and the remembered sizes.
        bool holds(const PHLWINDOW& w) const {
            for (const auto& E : m_entries)
                if (const auto T = E.target.lock(); T && T->window() == w)
                    return true;
            return false;
        }
        bool arrangedAsMosaic() const {
            return m_asMosaic;
        }
        bool arrangedAsCanvas() const {
            return m_asCanvas;
        }

        // ---- the canvas's view (MosaicCanvas.hpp)
        std::optional<MosaicPack::SCanvasView> canvasViewNow() const {
            const auto AREA = area();
            if (!m_asCanvas || !AREA)
                return std::nullopt;
            return MosaicPack::canvasView(m_canvas.w, m_canvas.h, MosaicPack::SRect{AREA->x, AREA->y, AREA->w, AREA->h});
        }
        Vector2D canvasOffset() const {
            return m_canvasOffset;
        }
        Vector2D canvasSize() const {
            return Vector2D{m_canvas.w, m_canvas.h};
        }
        std::optional<CBox> canvasArea() const {
            return area();
        }
        void setCanvasOffset(const Vector2D& offset, bool warp) {
            m_canvasOffset = offset;
            layoutCanvas(warp);
        }
        void revealWindow(const PHLWINDOW& w) {
            const auto AREA = area();
            const auto VIEW = canvasViewNow();
            if (!AREA || !VIEW || m_canvas.rects.size() != m_entries.size())
                return;
            for (size_t i = 0; i < m_entries.size(); ++i)
                if (const auto T = m_entries[i].target.lock(); T && T->window() == w) {
                    const auto& R    = m_canvas.rects[i];
                    const auto  OLD  = m_canvasOffset;
                    m_canvasOffset.x = MosaicPack::revealAxis(m_canvasOffset.x, R.x, R.w, AREA->w, VIEW->maxX, innerGap());
                    m_canvasOffset.y = MosaicPack::revealAxis(m_canvasOffset.y, R.y, R.h, AREA->h, VIEW->maxY, innerGap());
                    if (std::abs(OLD.x - m_canvasOffset.x) > 0.5 || std::abs(OLD.y - m_canvasOffset.y) > 0.5)
                        layoutCanvas(false);
                    return;
                }
        }
        // The window showing the most of itself in the view (after a pan).
        PHLWINDOW mostVisible() const {
            const auto AREA = area();
            if (!m_asCanvas || !AREA)
                return nullptr;
            PHLWINDOW best;
            double    bestA = 0;
            for (const auto& E : m_entries)
                if (const auto T = E.target.lock(); T && T->window()) {
                    const CBox B = T->position();
                    const double W = std::min(B.x + B.w, AREA->x + AREA->w) - std::max(B.x, AREA->x), H = std::min(B.y + B.h, AREA->y + AREA->h) - std::max(B.y, AREA->y);
                    if (W > 0 && H > 0 && W * H / std::max(1.0, B.w * B.h) > bestA) {
                        bestA = W * H / std::max(1.0, B.w * B.h);
                        best  = T->window();
                    }
                }
            return best;
        }
        double visibleShare(const PHLWINDOW& w) const {
            const auto AREA = area();
            if (!AREA || !w)
                return 0;
            for (const auto& E : m_entries)
                if (const auto T = E.target.lock(); T && T->window() == w) {
                    const CBox   B = T->position();
                    const double W = std::min(B.x + B.w, AREA->x + AREA->w) - std::max(B.x, AREA->x), H = std::min(B.y + B.h, AREA->y + AREA->h) - std::max(B.y, AREA->y);
                    return W > 0 && H > 0 ? W * H / std::max(1.0, B.w * B.h) : 0.0;
                }
            return 0;
        }
        PHLWORKSPACE workspace() const {
            return m_parent && m_parent->space() ? m_parent->space()->workspace() : PHLWORKSPACE{};
        }
        std::optional<Vector2D> naturalOf(const PHLWINDOW& w) const {
            for (const auto& E : m_entries)
                if (const auto T = E.target.lock(); T && T->window() == w)
                    return E.natural;
            return std::nullopt;
        }
        bool trustedOf(const PHLWINDOW& w) const {
            for (const auto& E : m_entries)
                if (const auto T = E.target.lock(); T && T->window() == w)
                    return E.trusted;
            return false;
        }

        void newTarget(SP<Layout::ITarget> target) override {
            m_revealPending = true;
            // A Super+drag let go is the same window put down, not one arriving:
            // the tiles keep their hold (m_tiledHold) through it.
            const bool DROP = droppingNow();
            m_dragHold.reset();
            if (!DROP)
                m_tiledHold = false;
            forgetArrangement();
            arriveWithNatural(target, true);
            placeInTiles(target, std::nullopt, DROP);
            placeDropped(target, std::nullopt);
            recalculate();
        }

        void movedTarget(SP<Layout::ITarget> target, std::optional<Vector2D> focalPoint = std::nullopt) override {
            m_revealPending = true;
            const bool DROP = droppingNow();
            m_dragHold.reset();
            if (indexOf(target) < 0) {
                forgetArrangement();
                arriveWithNatural(target, false);
                placeInTiles(target, focalPoint, DROP);
                placeDropped(target, focalPoint);
            }
            recalculate();
        }

        // Hyprland is putting down a window a Super+drag carried.
        static bool droppingNow() {
            return g_layoutManager && g_layoutManager->dragController()->wasDraggingWindow();
        }

        // THE TILES TAKE A WINDOW AS DWINDLE DOES (user, 2026-10-23: "when
        // mosaic goes to dwindle (hybrid) it should behave exactly like
        // dwindle ... I can't swap positions of all windows with super+drag").
        // DwindleAlgorithm::addTarget, with the user's dwindle options: the tile
        // it splits (OPENINGON) and which half it takes. A window let go after a
        // Super+drag splits the tile under the pointer, on the half the pointer
        // is in -- it used to split the newest tile wherever it was dropped. A
        // window moved by direction splits the tile at its focal point; a new
        // window splits the focused one (use_active_for_splits) on the side
        // force_split says. preselect and smart_split as dwindle has them.
        // Only while the tiles stand: in the mosaic the packer places everyone.
        void placeInTiles(const SP<Layout::ITarget>& target, std::optional<Vector2D> focal, bool drop) {
            const long long PICKED = std::exchange(m_dragLeaf, -1);
            if (m_tree.empty())
                return;
            const int  I    = indexOf(target);
            const auto AREA = tilesArea();
            if (I < 0 || !AREA)
                return;
            const auto      O     = treeOpts();
            const Vector2D  MOUSE = g_pInputManager->getMouseCoordsInternal();
            const Vector2D  AT    = focal.value_or(MOUSE);
            long long       near  = -1;
            if (PICKED >= 0 && m_tree.has(PICKED)) {
                // THE DRAG HOLD kept every other tile where it was, and this
                // window's own tile empty. Let go over that hole (or nowhere
                // else): it goes back into its own tile, sizes and all.
                if (drop) {
                    near = m_tree.leafAt(MOUSE.x, MOUSE.y, *AREA, O);
                    if (near == PICKED || near < 0) {
                        m_entries[sc<size_t>(I)].id = PICKED;
                        return;
                    }
                }
                m_tree.remove(PICKED);
            }

            static auto PUSEACTIVE  = CConfigValue<::Config::INTEGER>("dwindle:use_active_for_splits");
            static auto PFORCESPLIT = CConfigValue<::Config::INTEGER>("dwindle:force_split");
            static auto PSMARTSPLIT = CConfigValue<::Config::INTEGER>("dwindle:smart_split");
            static auto PPRECISE    = CConfigValue<::Config::INTEGER>("dwindle:precise_mouse_move");
            static auto PPERMANENT  = CConfigValue<::Config::INTEGER>("dwindle:permanent_direction_override");

            if (near < 0) {
                if (focal || drop)
                    near = m_tree.leafAt(AT.x, AT.y, *AREA, O);
                else if (*PUSEACTIVE) {
                    // The focused window, if it is a tile here and not this one.
                    if (const auto F = Desktop::focusState()->window(); F && F != target->window())
                        for (const auto& E : m_entries)
                            if (const auto T = E.target.lock(); T && T->window() == F && m_tree.has(E.id))
                                near = E.id;
                    if (near < 0)
                        near = m_tree.leafAt(MOUSE.x, MOUSE.y, *AREA, O);
                } else
                    near = m_tree.leafAt(MOUSE.x, MOUSE.y, *AREA, O);
            }

            const MosaicPack::SRect BOX    = m_tree.cellOf(near, *AREA, O).value_or(*AREA);
            bool                    first  = false;
            int                     orient = -1;
            if (m_overrideDir != Math::DIRECTION_DEFAULT) {
                orient = m_overrideDir == Math::DIRECTION_UP || m_overrideDir == Math::DIRECTION_DOWN ? 1 : 0;
                first  = m_overrideDir == Math::DIRECTION_UP || m_overrideDir == Math::DIRECTION_LEFT;
                if (!*PPERMANENT)
                    m_overrideDir = Math::DIRECTION_DEFAULT;
            } else if (*PSMARTSPLIT || (*PPRECISE && drop)) {
                const double DX = AT.x - (BOX.x + BOX.w / 2.0), DY = AT.y - (BOX.y + BOX.h / 2.0);
                if (BOX.w > 0 && std::abs(DX) > 1e-9 && std::abs(DY / DX) < BOX.h / BOX.w) {
                    orient = 0;
                    first  = DX <= 0;
                } else {
                    orient = 1;
                    first  = DY <= 0;
                }
            } else if (*PFORCESPLIT == 0 || focal || drop) {
                static auto PMULT = CConfigValue<::Config::FLOAT>("dwindle:split_width_multiplier");
                const bool  SIDE  = BOX.w > BOX.h * *PMULT;
                first             = SIDE ? AT.x < BOX.x + BOX.w / 2.0 : AT.y < BOX.y + BOX.h / 2.0;
            } else
                first = *PFORCESPLIT == 1;

            // The split takes the two windows' mosaic areas (the tiles look
            // like the mosaic, CDwindleTree::buildWeighted), where dwindle halves.
            const auto AREAOF = [&](long long id) {
                for (const auto& E : m_entries)
                    if (E.id == id)
                        return std::max(0.0, E.natural.x * E.natural.y);
                return 0.0;
            };
            const double WN = AREAOF(m_entries[sc<size_t>(I)].id), WO = AREAOF(near);
            const double SHARE =
                WN + WO > 0 ? std::clamp(WN / (WN + WO), MosaicPack::CDwindleTree::WEIGHT_MIN, 1.0 - MosaicPack::CDwindleTree::WEIGHT_MIN) : 0.5;
            m_tree.insertAt(m_entries[sc<size_t>(I)].id, near, first, SHARE, orient, *AREA, O);
        }

        // The tiles' space, and the dwindle options they follow.
        std::optional<MosaicPack::SRect> tilesArea() const {
            const auto A = area();
            if (!A)
                return std::nullopt;
            return MosaicPack::SRect{A->x, A->y, A->w, A->h};
        }
        static MosaicPack::STreeOpts treeOpts() {
            static auto PPRESERVE   = CConfigValue<::Config::INTEGER>("dwindle:preserve_split");
            static auto PSMARTSPLIT = CConfigValue<::Config::INTEGER>("dwindle:smart_split");
            static auto PPRECISE    = CConfigValue<::Config::INTEGER>("dwindle:precise_mouse_move");
            static auto PMULT       = CConfigValue<::Config::FLOAT>("dwindle:split_width_multiplier");
            return MosaicPack::STreeOpts{.preserve = *PPRESERVE || *PSMARTSPLIT || *PPRECISE, .widthMult = std::max(0.01, sc<double>(*PMULT))};
        }
        long long idOf(const SP<Layout::ITarget>& t) const {
            const int I = indexOf(t);
            return I < 0 ? -1 : m_entries[sc<size_t>(I)].id;
        }
        SP<Layout::ITarget> targetOfId(long long id) const {
            for (const auto& E : m_entries)
                if (E.id == id)
                    return E.target.lock();
            return nullptr;
        }

        // DROP TO REARRANGE (MosaicPack::PackHint). A Super+drag floats the
        // window for the drag; letting go hands it back here, at the end of
        // the order. When it came back from a drag (or with a focal point), the
        // point it was let go at goes to pack() as the hint: the window lands
        // on that side of the cluster (or at the point, dropped inside it),
        // still one tight cluster. The order itself is not touched -- the
        // packer is any-order.
        void placeDropped(const SP<Layout::ITarget>& target, std::optional<Vector2D> focalPoint) {
            if (!focalPoint && !(g_layoutManager && g_layoutManager->dragController()->wasDraggingWindow()))
                return;
            const int I = indexOf(target);
            if (I < 0 || m_entries.size() < 2)
                return;
            const auto AREA = area();
            if (!AREA)
                return;
            const Vector2D AT = focalPoint.value_or(g_pInputManager->getMouseCoordsInternal());
            trace(std::format("drop {} at {}x{}", appOf(target->window()), AT.x, AT.y));
            m_dropAt = SDropAt{target, AT};
        }

        // A window this session already gave a mosaic size comes back at that
        // size, as it was: it is not new, and resizing it
        // here would overwrite the size it is meant to keep.
        void arriveWithNatural(const SP<Layout::ITarget>& target, bool fresh) {
            const auto N = naturalFor(target, fresh);
            arrive(target, Vector2D{N.size.w, N.size.h}, N.trusted);
        }

        // A WINDOW ARRIVES (user, 2026-10-14: "opening new windows ... seems to
        // continue shrinking mosaic windows ... I said this should never
        // happen. Existing windows should not be resized"). Nobody already
        // there changes size -- and NEITHER DOES THE NEWCOMER (user,
        // 2026-10-15: "it should never spawn a window smaller than my default
        // - at that point it should go into dwindle"; it used to come in down
        // to half its size to fit). It keeps its size; if it does not fit, the
        // desktop tiles. The eased margin and any-order rows/columns
        // (MosaicPack) are what keep the tiles from coming too easily.
        void arrive(const SP<Layout::ITarget>& target, Vector2D want, bool trusted = true) {
            m_entries.push_back({target, want, ++m_nextId, trusted});
            trace(std::format("arrive {} want={}x{}{}", appOf(target ? target->window() : PHLWINDOW{}), want.x, want.y, fits() ? "" : " -> tiles"));
        }

        // Does everyone fit as a mosaic at their own sizes?
        bool fits() const {
            const auto AREA = area();
            if (!AREA)
                return false;
            std::vector<MosaicPack::SRect> sizes;
            for (const auto& E : m_entries)
                sizes.push_back({0, 0, E.natural.x, E.natural.y});
            return MosaicPack::fitsEased(sizes, MosaicPack::SRect{AREA->x, AREA->y, AREA->w, AREA->h}, looseArea(), innerGap());
        }

        void removeTarget(SP<Layout::ITarget> target) override {
            if (m_resize) {
                setDim(false, *m_resize);
                m_resize.reset();
            }
            // Pulled out by a Super+drag: not a window leaving -- the tiles keep
            // their hold, and its tile waits for it (placeInTiles).
            const bool DRAGGED = target && g_layoutManager && g_layoutManager->dragController()->target() == target;
            if (!DRAGGED)
                m_tiledHold = false;
            forgetArrangement();
            leftMosaic(target);
            if (DRAGGED)
                m_dragLeaf = m_tree.empty() ? -1 : idOf(target);
            std::erase_if(m_entries, [&](const SMosaicEntry& e) { return !e.target || e.target.lock() == target; });
            // Pulled out by a drag: the others hold still until it is let go.
            if (DRAGGED) {
                m_dragHold = target;
                return;
            }
            recalculate();
        }

        // The drag that pulled a window out is over (or took it to another
        // desktop): the cluster may close up now.
        bool holdingFor() const {
            return !m_dragHold.expired();
        }
        void releaseDragHold() {
            if (m_dragHold.expired())
                return;
            m_dragHold.reset();
            m_dragLeaf = -1; // let go elsewhere: its tile goes (syncTree)
            recalculate();
        }
        // Still in the air over this desktop?
        bool dragHoldLive() const {
            const auto T = m_dragHold.lock();
            if (!T || !g_layoutManager || g_layoutManager->dragController()->target() != T)
                return false;
            const auto W = T->window();
            return W && W->m_workspace && W->m_workspace == workspace();
        }

        // A RESIZE in the mosaic (user, 2026-10-14: "if I resize a window beyond
        // what the current arrangement supports, it should never force other
        // windows to get smaller"). For the length of the drag the other windows
        // are FROZEN where they are, and the resized one grows from its fixed
        // opposite corner up to its CALCULATED LIMIT: the largest size at which
        // some mosaic arrangement of everyone, at their current sizes, still
        // fits (MosaicPack::limitFor -- worked out, not shown). Pushed past the
        // limit, the window stops growing and the rest of the desktop darkens:
        // letting go there tiles, keeping sizes as well as it can. Letting go
        // anywhere else applies the limit's arrangement.
        //
        // In the TILES it is dwindle's resize, live (2026-10-23); letting go
        // lets the window's mosaic size shrink toward its tile -- so shrinking
        // windows in the tiles is the way back to the mosaic once everyone
        // fits again.
        void resizeTarget(const Vector2D& delta, SP<Layout::ITarget> target, Layout::eRectCorner corner = Layout::CORNER_NONE) override {
            const int I = indexOf(target);
            if (I < 0)
                return;
            // IN THE TILES, DWINDLE'S RESIZE (user, 2026-10-23: "behave exactly
            // like dwindle"): live, the splits DwindleAlgorithm::resizeTarget
            // moves (dwindle:smart_resizing or not), every tile following.
            // Letting go still lets the window's mosaic size shrink toward its
            // tile (finishResize).
            if (!m_tree.empty() && !m_asMosaic) {
                if (!m_resize || m_resize->target.lock() != target)
                    beginResize(target, corner);
                const auto AREA = tilesArea();
                if (!m_resize || !AREA)
                    return;
                static auto PSMART = CConfigValue<::Config::INTEGER>("dwindle:smart_resizing");
                const MosaicPack::CDwindleTree::SEdges EDGES{
                    .left = Layout::edgeLeft(corner), .right = Layout::edgeRight(corner), .top = Layout::edgeTop(corner), .bottom = Layout::edgeBottom(corner)};
                m_tree.resizeDwindle(m_entries[sc<size_t>(I)].id, delta.x, delta.y, EDGES, *PSMART != 0, *AREA, treeOpts());
                layoutTiles();
                // A drag snaps every tile, as dwindle does (no animation
                // chasing the pointer).
                if (g_layoutManager && g_layoutManager->dragController()->target() == target)
                    for (const auto& E : m_entries)
                        if (const auto T = E.target.lock())
                            T->warpPositionSize();
                if (corner == Layout::CORNER_NONE)
                    finishResize();
                return;
            }
            // The window grows toward the corner being dragged: a left or top
            // corner pulled outward is a BIGGER window, not a smaller one. No
            // corner (a keyboard resizeactive): the delta is the size change.
            Vector2D grow = delta;
            if (corner != Layout::CORNER_NONE) {
                grow.x = Layout::edgeLeft(corner) ? -delta.x : delta.x;
                grow.y = Layout::edgeTop(corner) ? -delta.y : delta.y;
            }

            if (!m_resize || m_resize->target.lock() != target)
                beginResize(target, corner);
            if (!m_resize)
                return;
            if (corner == Layout::CORNER_NONE)
                m_resize->requested = m_resize->requested + grow;
            else {
                // A DRAG follows the POINTER, measured from the corner that
                // stays put -- not a sum of deltas, which can only drift. The
                // grab's own offset from the corner is kept.
                const Vector2D P = g_pInputManager->getMouseCoordsInternal() + m_resize->grabOffset;
                const CBox&    S = m_resize->start;
                const double   AX = Layout::edgeLeft(corner) ? S.x + S.w : S.x, AY = Layout::edgeTop(corner) ? S.y + S.h : S.y;
                // An EDGE (user, 2026-10-15) moves one side only: the other
                // axis stays at its size.
                const bool     HORIZ = corner & (Layout::CORNER_LEFT | Layout::CORNER_RIGHT), VERT = corner & (Layout::CORNER_TOP | Layout::CORNER_BOTTOM);
                m_resize->requested  = Vector2D{HORIZ ? std::max(MIN_SIDE, Layout::edgeLeft(corner) ? AX - P.x : P.x - AX) : S.w,
                                               VERT ? std::max(MIN_SIDE, Layout::edgeTop(corner) ? AY - P.y : P.y - AY) : S.h};
            }
            stepResize();
            // A keyboard resize is one step: settle at once.
            if (corner == Layout::CORNER_NONE)
                finishResize();
        }

        // The drag ended (Mosaic::onButton / onMove see the drag controller let go).
        bool resizing() const {
            return m_resize.has_value();
        }
        bool resizingTarget(const SP<Layout::ITarget>& t) const {
            return m_resize && m_resize->target.lock() == t;
        }
        void finishResize() {
            if (!m_resize)
                return;
            const auto SESSION = *m_resize;
            m_resize.reset();
            setDim(false, SESSION);

            const int I = indexOf(SESSION.target.lock());
            if (SESSION.tiled) {
                // A tile let go: its dwindle split moves to the size it was
                // dragged to. Its mosaic size may only SHRINK toward it, per
                // side (user, 2026-10-15: "mosaic ... wont leave tiled mode" --
                // tiles are big, so taking the tile's size as the mosaic size
                // made Zen 1911x1209 and the desktop could never fit again).
                // Shrinking a tile is the way out of the tiles; growing one no
                // longer locks the desktop in them.
                if (I >= 0) {
                    // The splits already moved, live (resizeTarget); the size
                    // the tile ended at is the one the mosaic may shrink to.
                    const auto     T     = SESSION.target.lock();
                    const Vector2D SHOWN = T ? T->position().size() : SESSION.shown;
                    auto&          n     = m_entries[sc<size_t>(I)].natural;
                    n                    = Vector2D{std::max(MIN_SIDE, std::min(n.x, SHOWN.x)), std::max(MIN_SIDE, std::min(n.y, SHOWN.y))};
                    // A tile's size is the tiles', not the app's.
                    m_entries[sc<size_t>(I)].trusted = false;
                }
                if (m_tiledHold && fits())
                    m_tiledHold = false;
            } else {
                // Everyone keeps the size they were frozen at, so the next pass
                // finds the arrangement the limit already proved exists.
                for (size_t k = 0; k < m_entries.size(); ++k) {
                    const auto T = m_entries[k].target.lock();
                    for (const auto& [WT, BOX] : SESSION.frozen)
                        if (WT.lock() == T && T)
                            m_entries[k].natural = Vector2D{std::max(MIN_SIDE, BOX.w), std::max(MIN_SIDE, BOX.h)};
                }
                if (I >= 0) {
                    // The mosaic keeps the size the window had when the tiles
                    // took over -- its limit -- so it comes back exactly so.
                    m_entries[sc<size_t>(I)].natural = SESSION.shown;
                    // The user sized it in the mosaic: that is its size now.
                    m_entries[sc<size_t>(I)].trusted = true;
                    // Past the limit: tiles, until shrinking a tile (or a window
                    // leaving or arriving) lets the mosaic fit again.
                    if (SESSION.past)
                        m_tiledHold = true;
                }
            }
            trace(std::format("finish past={} shown={}x{} requested={}x{}", SESSION.past, SESSION.shown.x, SESSION.shown.y, SESSION.requested.x, SESSION.requested.y));
            recalculate();
        }

        void recalculate(Layout::eRecalculateReason reason = Layout::RECALCULATE_REASON_UNKNOWN) override {
            (void)reason;
            std::erase_if(m_entries, [](const SMosaicEntry& e) { return !e.target; });
            // Every window's mosaic size outlives this layout (g_windowSizes).
            for (const auto& E : m_entries)
                if (const auto T = E.target.lock())
                    rememberWindow(T->window(), E.natural, E.trusted);
            if (m_entries.empty() || !m_parent || !m_parent->space())
                return;

            // A fullscreen window owns the desktop: everything else is the
            // fullscreen handler's to place, as in every built-in layout.
            const auto SPACE = m_parent->space();
            if (Fullscreen::controller()->hasFullscreen(SPACE->workspace(), true)) {
                m_defaultFullscreenHandler->syncTargetSizeAndPosition();
                return;
            }

            // A window in the air (the drag hold): everyone stays put.
            if (dragHoldLive())
                return;

            // Mid-resize in the mosaic, the frozen arrangement stands, whatever
            // asked. (A tile resizes live: the tiles below lay it out.)
            if (m_resize && !m_resize->tiled) {
                applyResize();
                return;
            }

            const auto AREAOPT = area();
            if (!AREAOPT)
                return;
            const CBox AREA = *AREAOPT;

            std::vector<MosaicPack::SRect> sizes;
            sizes.reserve(m_entries.size());
            for (const auto& E : m_entries)
                sizes.push_back({0, 0, E.natural.x, E.natural.y});

            const MosaicPack::SRect AREAR{AREA.x, AREA.y, AREA.w, AREA.h};
            m_asMosaic = false;
            const bool WASCANVAS = m_asCanvas;
            m_asCanvas = false;
            // After a resize pushed past its limit the desktop stays tiled until
            // a window arrives or leaves (m_tiledHold).
            std::optional<MosaicPack::PackHint> hint;
            if (m_dropAt)
                if (const int I = indexOf(m_dropAt->target.lock()); I >= 0)
                    hint = MosaicPack::PackHint{.idx = sc<size_t>(I), .x = m_dropAt->at.x, .y = m_dropAt->at.y};
            // m_entries stays in ARRIVAL order. pack() is any-order but not
            // order-blind (ties), so the same list in the same order is the same
            // cluster on every pass; re-sorting it by what came back (the old
            // regrouped order) made a different cluster in 139 of 348 bench sets.
            auto PLACED = m_tiledHold ? std::nullopt : MosaicPack::packEased(sizes, AREAR, looseArea(), innerGap(), hint ? &*hint : nullptr);
            traceEntries(PLACED ? "mosaic" : "tiles");
            if (PLACED) {
                m_asMosaic = true;
                // Back in the mosaic: the next time the tiles take over they
                // start from a fresh, balanced tree.
                m_tree.clear();
                // THE MOSAIC: each window exactly where the pack put it. A
                // non-empty visual box is placed as given -- Hyprland adds no
                // tile gaps to it -- and the logical box is the same rect.
                for (size_t i = 0; i < m_entries.size(); ++i) {
                    const auto& R = (*PLACED)[i];
                    const CBox  BOX{R.x, R.y, R.w, R.h};
                    if (const auto T = m_entries[i].target.lock())
                        T->setPositionGlobal(Layout::STargetBox{.logicalBox = BOX, .visualBox = BOX});
                }
                return;
            }

            // THE INFINITE CANVAS instead of the tiles (mosaic:infinite_canvas):
            // everyone at their mosaic size, past the screen, the view panned.
            if (canvasOn()) {
                m_tree.clear();
                m_tiledHold = false;
                arrangeCanvas(WASCANVAS);
                return;
            }

            // THE TILES (user, 2026-10-14): a dwindle tree (MosaicPack::
            // CDwindleTree), each split where the user left it. Plain cells, so Hyprland insets them by gaps_in exactly
            // as it does dwindle's. They never touch `natural`: the mosaic that
            // comes back has every window as it was.
            trace(std::format("tiles n={} hold={}", m_entries.size(), m_tiledHold));
            layoutTiles();
        }

        void arrangeCanvas(bool wasCanvas) {
            const auto AREA = area();
            if (!AREA)
                return;
            // A window let go on the canvas takes its place in the order next to
            // the window it was dropped by (the groups follow the order).
            if (m_dropAt) {
                const int I = indexOf(m_dropAt->target.lock());
                if (I >= 0 && m_entries.size() > 1) {
                    int    nearest = -1;
                    double bestD   = 1e18;
                    for (size_t k = 0; k < m_entries.size(); ++k)
                        if (const auto T = m_entries[k].target.lock(); T && sc<int>(k) != I) {
                            const auto D = T->position().middle() - m_dropAt->at;
                            if (D.x * D.x + D.y * D.y < bestD) {
                                bestD   = D.x * D.x + D.y * D.y;
                                nearest = sc<int>(k);
                            }
                        }
                    if (nearest >= 0) {
                        const auto NT     = m_entries[sc<size_t>(nearest)].target.lock();
                        const bool BEFORE = NT && m_dropAt->at.x < NT->position().middle().x;
                        auto       moved  = m_entries[sc<size_t>(I)];
                        m_entries.erase(m_entries.begin() + I);
                        int at = nearest > I ? nearest - 1 : nearest;
                        m_entries.insert(m_entries.begin() + (BEFORE ? at : at + 1), moved);
                    }
                }
                m_dropAt.reset();
            }
            std::vector<MosaicPack::SRect> sizes;
            for (const auto& E : m_entries)
                sizes.push_back({0, 0, E.natural.x, E.natural.y});
            m_canvas   = MosaicPack::packCanvas(sizes, MosaicPack::SRect{AREA->x, AREA->y, AREA->w, AREA->h}, looseArea(), innerGap(), canvasAllDirections());
            m_asCanvas = true;
            trace(std::format("canvas n={} groups={} size={}x{}", m_entries.size(), m_canvas.groups, m_canvas.w, m_canvas.h));
            if (!wasCanvas)
                m_canvasOffset = {};
            layoutCanvas(false);
            // The arrangement changed (a window came, went or moved): the focused
            // one stays in view.
            if (!wasCanvas || std::exchange(m_revealPending, false))
                if (const auto F = Desktop::focusState()->window(); F && holds(F))
                    revealWindow(F);
        }

        // Every window at its canvas place for the current view.
        void layoutCanvas(bool warp) {
            const auto VIEW = canvasViewNow();
            if (!VIEW || m_canvas.rects.size() != m_entries.size())
                return;
            m_canvasOffset.x = std::clamp(m_canvasOffset.x, 0.0, VIEW->maxX);
            m_canvasOffset.y = std::clamp(m_canvasOffset.y, 0.0, VIEW->maxY);
            for (size_t i = 0; i < m_entries.size(); ++i) {
                const auto& R = m_canvas.rects[i];
                const CBox  BOX{std::round(VIEW->originX + R.x - m_canvasOffset.x), std::round(VIEW->originY + R.y - m_canvasOffset.y), R.w, R.h};
                if (const auto T = m_entries[i].target.lock()) {
                    T->setPositionGlobal(Layout::STargetBox{.logicalBox = BOX, .visualBox = BOX});
                    if (warp)
                        T->warpPositionSize();
                }
            }
        }

        void layoutTiles() {
            const auto AREA = tilesArea();
            if (!AREA)
                return;
            syncTree();
            for (const auto& [ID, R] : m_tree.layout(*AREA, treeOpts()))
                if (const auto T = targetOfId(ID))
                    T->setPositionGlobal(Layout::STargetBox{.logicalBox = CBox{R.x, R.y, R.w, R.h}, .visualBox = {}});
        }

        // The desktop the mosaic lays out in.
        std::optional<CBox> area() const {
            if (!m_parent || !m_parent->space())
                return std::nullopt;
            const auto SPACE = m_parent->space();
            CBox       AREA  = SPACE->workArea();
            // THE DOCK'S BAND (dock:windows_make_room, autohide off): DockRoom
            // shortens any tile under the pill after the fact, which would squash
            // the mosaic's bottom row out of its proportions. The mosaic keeps
            // out of that band instead -- one tile gap above the pill, the gap
            // DockRoom leaves -- and centres in what is left.
            if (const auto MON = SPACE->workspace() ? SPACE->workspace()->m_monitor.lock() : PHLMONITOR{}) {
                const CBox PILL = Dock::roomPillGlobal(MON);
                if (PILL.w >= 1 && PILL.h >= 1) {
                    static auto  PBORDER = CConfigValue<::Config::INTEGER>("general:border_size");
                    const double LIMIT   = PILL.y - innerGap() - std::max<int64_t>(0, *PBORDER);
                    AREA.h               = std::min(AREA.h, LIMIT - AREA.y);
                }
            }
            if (AREA.w < 1 || AREA.h < 1)
                return std::nullopt;
            return AREA;
        }

        // THE EASED MARGIN (MosaicPack::packEased): the area with each
        // screen-edge margin eased from gaps_out down to gaps_in, tried only
        // when the windows do not fit area(). The dock's band stays out of
        // bounds: a bottom edge area() pulled up above the pill is not eased.
        std::optional<MosaicPack::SRect> looseArea() const {
            const auto AREA = area();
            if (!AREA || !m_parent || !m_parent->space())
                return std::nullopt;
            static auto PGAPSOUT = CConfigValue<::Config::IComplexConfigValue>("general:gaps_out");
            static auto PGAPSIN  = CConfigValue<::Config::IComplexConfigValue>("general:gaps_in");
            const auto* OUT      = sc<::Config::CCssGapData*>(PGAPSOUT.ptr());
            const auto* IN       = sc<::Config::CCssGapData*>(PGAPSIN.ptr());
            if (!OUT || !IN)
                return std::nullopt;
            const auto   EASE = [](int64_t out, int64_t in) { return sc<double>(std::max<int64_t>(0, out - in)); };
            const double L = EASE(OUT->m_left, IN->m_left), R = EASE(OUT->m_right, IN->m_right), T = EASE(OUT->m_top, IN->m_top);
            const CBox   WORK     = m_parent->space()->workArea();
            const bool   PILLCUT  = AREA->y + AREA->h < WORK.y + WORK.h - 0.5;
            const double B        = PILLCUT ? 0.0 : EASE(OUT->m_bottom, IN->m_bottom);
            if (L + R + T + B < 0.5)
                return std::nullopt;
            return MosaicPack::SRect{AREA->x - L, AREA->y - T, AREA->w + L + R, AREA->h + T + B};
        }

        // Two windows trade places: their slots in the order (the mosaic) AND
        // their cells in the tiles. A cell is a leaf of the dwindle tree,
        // keyed by the entry's id, so the ids stay where they were and the
        // windows -- with their own sizes -- move between them; swapping whole
        // entries carried each window's cell along and the tiles never moved.
        void tradePlaces(size_t a, size_t b) {
            if (a == b || a >= m_entries.size() || b >= m_entries.size())
                return;
            // THE MOSAIC is any-order: the order no longer IS the arrangement,
            // so a swap is the moved window -- the focused one of the two --
            // dropped where the other one stands (PackHint): it lands there,
            // the cluster stays one tight bunch.
            const auto             TA = m_entries[a].target.lock(), TB = m_entries[b].target.lock();
            const auto             FOCUS = Desktop::focusState()->window();
            std::optional<SDropAt> swapDrop;
            if (m_asMosaic && TA && TB)
                swapDrop = FOCUS && TB->window() == FOCUS ? SDropAt{TB, TA->position().middle()} : SDropAt{TA, TB->position().middle()};
            std::swap(m_entries[a], m_entries[b]);
            std::swap(m_entries[a].id, m_entries[b].id);
            m_dropAt = swapDrop;
        }

        SP<Layout::ITarget> getNextCandidate(SP<Layout::ITarget> old) override {
            if (m_entries.empty())
                return nullptr;
            // In the tiles, dwindle's: the tile nearest where the old one was.
            if (const auto AREA = tilesArea(); AREA && !m_tree.empty() && old) {
                const auto M = old->position().middle();
                if (const auto T = targetOfId(m_tree.leafAt(M.x, M.y, *AREA, treeOpts(), idOf(old))); T && T != old)
                    return T;
            }
            const int I = indexOf(old);
            if (I < 0)
                return m_entries.back().target.lock();
            return m_entries[(sc<size_t>(I) + 1) % m_entries.size()].target.lock();
        }

        void swapTargets(SP<Layout::ITarget> a, SP<Layout::ITarget> b) override {
            m_revealPending = true;
            const int IA = indexOf(a), IB = indexOf(b);
            if (IA >= 0 && IB >= 0)
                tradePlaces(sc<size_t>(IA), sc<size_t>(IB));
            recalculate();
        }

        // Moving a window: it trades places with the nearest window in that
        // direction (the order is the arrangement). Past the edge, the monitor
        // in that direction takes it, as binds:window_direction_monitor_fallback
        // asks of every layout.
        void moveTargetInDirection(SP<Layout::ITarget> t, Math::eDirection dir, bool silent) override {
            m_revealPending = true;
            (void)silent;
            const int I = indexOf(t);
            if (I < 0 || !t)
                return;
            // IN THE TILES, DWINDLE'S MOVE: the window leaves its tile and splits
            // the one at its focal point that way -- past the edge, the monitor
            // there (binds:window_direction_monitor_fallback) -- and lands on
            // the far side of a lone sibling it moves straight at.
            if (const auto AREA = tilesArea(); AREA && !m_tree.empty() && m_tree.has(m_entries[sc<size_t>(I)].id)) {
                static auto PFALLBACK = CConfigValue<::Config::INTEGER>("binds:window_direction_monitor_fallback");
                const auto  FOCAL     = focalPointForDir(t, dir);
                const auto  WSMON     = workspace() ? workspace()->m_monitor.lock() : PHLMONITOR{};
                const auto  FOCALMON  = State::monitorState()->query().vec(FOCAL.value_or(t->position().middle())).run();
                if (FOCALMON != WSMON) {
                    if (*PFALLBACK && FOCALMON && FOCALMON->m_activeWorkspace) {
                        if (t->window())
                            t->window()->setAnimationsToMove();
                        t->assignToSpace(FOCALMON->m_activeWorkspace->m_space, FOCAL);
                    }
                    return;
                }
                const long long ID = m_entries[sc<size_t>(I)].id;
                if (m_tree.towardLoneSibling(ID, sc<int>(dir), *AREA, treeOpts()))
                    m_overrideDir = dir;
                if (t->window())
                    t->window()->setAnimationsToMove();
                const Vector2D ORIGIN = t->position().middle();
                m_tree.remove(ID);
                placeInTiles(t, FOCAL.value_or(ORIGIN), false);
                recalculate();
                if (silent)
                    if (const auto BACK = targetOfId(m_tree.leafAt(ORIGIN.x, ORIGIN.y, *AREA, treeOpts())); BACK && BACK->window())
                        Desktop::focusState()->fullWindowFocus(BACK->window(), Desktop::FOCUS_REASON_KEYBIND);
                return;
            }
            const CBox FROM = t->position();
            const auto C0   = FROM.middle();
            int        best = -1;
            double     bestD = 1e18;
            for (size_t k = 0; k < m_entries.size(); ++k) {
                const auto O = m_entries[k].target.lock();
                if (!O || O == t)
                    continue;
                const auto C = O->position().middle();
                const auto D = C - C0;
                const bool AHEAD = (dir == Math::DIRECTION_LEFT && D.x < -1) || (dir == Math::DIRECTION_RIGHT && D.x > 1) || (dir == Math::DIRECTION_UP && D.y < -1) ||
                    (dir == Math::DIRECTION_DOWN && D.y > 1);
                if (!AHEAD)
                    continue;
                const double DIST = D.x * D.x + D.y * D.y;
                if (DIST < bestD) {
                    bestD = DIST;
                    best  = sc<int>(k);
                }
            }
            if (best >= 0) {
                tradePlaces(sc<size_t>(I), sc<size_t>(best));
                recalculate();
                return;
            }

            static auto PMONITORFALLBACK = CConfigValue<::Config::INTEGER>("binds:window_direction_monitor_fallback");
            if (!*PMONITORFALLBACK || !t->space() || !t->space()->workspace())
                return;
            const auto PMONITOR  = t->space()->workspace()->m_monitor.lock();
            const auto PMONINDIR = State::monitorState()->query().relativeTo(PMONITOR).inDirection(dir).run();
            if (PMONINDIR && PMONINDIR != PMONITOR && PMONINDIR->m_activeWorkspace) {
                if (t->window())
                    t->window()->setAnimationsToMove();
                t->assignToSpace(PMONINDIR->m_activeWorkspace->m_space, focalPointForDir(t, dir));
            }
        }

        std::optional<std::string> layoutName() const override {
            return std::string{"mosaic"};
        }

        // DWINDLE'S LAYOUTMSGS in the tiles: togglesplit, swapsplit,
        // rotatesplit [angle], movetoroot [window] [unstable], preselect <dir>,
        // splitratio <delta> [exact]. In the mosaic there are no splits: the
        // split ones do nothing (no error popup for a bind pressed there);
        // preselect is kept for the tiles.
        ::Config::ErrorResult layoutMsg(const std::string_view& sv) override {
            std::vector<std::string> args;
            {
                std::istringstream in{std::string{sv}};
                for (std::string w; in >> w;)
                    args.push_back(w);
            }
            const auto ARG = [&](size_t i) { return i < args.size() ? args[i] : std::string{}; };
            using ::Config::eConfigErrorCode;
            using ::Config::eConfigErrorLevel;
            const std::string CMD = ARG(0);

            if (CMD == "preselect") {
                const std::string D = ARG(1);
                if (D.empty())
                    return ::Config::configError("No direction for preselect", eConfigErrorLevel::ERROR, eConfigErrorCode::INVALID_ARGUMENT);
                switch (D.front()) {
                    case 'u':
                    case 't': m_overrideDir = Math::DIRECTION_UP; break;
                    case 'd':
                    case 'b': m_overrideDir = Math::DIRECTION_DOWN; break;
                    case 'r': m_overrideDir = Math::DIRECTION_RIGHT; break;
                    case 'l': m_overrideDir = Math::DIRECTION_LEFT; break;
                    default: m_overrideDir = Math::DIRECTION_DEFAULT; break;
                }
                return {};
            }
            const bool KNOWN = CMD == "togglesplit" || CMD == "swapsplit" || CMD == "rotatesplit" || CMD == "movetoroot" || CMD == "splitratio";
            if (!KNOWN)
                return ::Config::configError(std::format("Unknown mosaic layoutmsg: {}", sv), eConfigErrorLevel::ERROR, eConfigErrorCode::INVALID_ARGUMENT);
            const auto AREA = tilesArea();
            if (m_tree.empty() || !AREA)
                return {};

            long long id = -1;
            if (const auto F = Desktop::focusState()->window())
                for (const auto& E : m_entries)
                    if (const auto T = E.target.lock(); T && T->window() == F)
                        id = E.id;
            const auto O = treeOpts();
            if (const auto F = Desktop::focusState()->window(); F && Fullscreen::controller()->isFullscreen(F) && CMD != "splitratio")
                return ::Config::configError(std::format("can't {} in the current workspace", CMD), eConfigErrorLevel::WARNING, eConfigErrorCode::INVALID_STATE);

            if (CMD == "togglesplit") {
                if (id >= 0 && !m_tree.toggleSplit(id, *AREA, O))
                    return ::Config::configError("can't togglesplit in the current workspace", eConfigErrorLevel::WARNING, eConfigErrorCode::INVALID_STATE);
            } else if (CMD == "swapsplit") {
                if (id >= 0 && !m_tree.swapSplit(id))
                    return ::Config::configError("can't swapsplit in the current workspace", eConfigErrorLevel::WARNING, eConfigErrorCode::INVALID_STATE);
            } else if (CMD == "rotatesplit") {
                int angle = 90;
                if (!ARG(1).empty()) {
                    try {
                        angle = std::stoi(ARG(1));
                    } catch (...) { return ::Config::configError("Invalid angle argument", eConfigErrorLevel::ERROR, eConfigErrorCode::INVALID_ARGUMENT); }
                }
                if (id >= 0)
                    m_tree.rotateSplit(id, angle, *AREA, O);
            } else if (CMD == "movetoroot") {
                long long which = id;
                if (!ARG(1).empty())
                    if (const auto W = Desktop::viewState()->query().selector(ARG(1)).runWindow())
                        for (const auto& E : m_entries)
                            if (const auto T = E.target.lock(); T && T->window() == W)
                                which = E.id;
                if (!m_tree.moveToRoot(which, ARG(2).empty() || ARG(2) != "unstable"))
                    return ::Config::configError("can't movetoroot in the current workspace", eConfigErrorLevel::WARNING, eConfigErrorCode::INVALID_STATE);
            } else if (CMD == "splitratio") {
                const std::string R = ARG(1);
                if (R.empty())
                    return ::Config::configError("splitratio requires an arg", eConfigErrorLevel::ERROR, eConfigErrorCode::INVALID_ARGUMENT);
                double value = 0;
                try {
                    value = std::stod(R);
                } catch (...) { return ::Config::configError(std::format("failed to parse \"{}\" as a delta", R), eConfigErrorLevel::ERROR, eConfigErrorCode::INVALID_ARGUMENT); }
                if (id < 0 || !m_tree.splitRatio(id, value, ARG(2).starts_with("exact")))
                    return ::Config::configError("cannot alter split ratio on no / single node", eConfigErrorLevel::WARNING, eConfigErrorCode::INVALID_STATE);
            }
            recalculate();
            return {};
        }

      private:
        static constexpr double MIN_SIDE  = 120.0;

        std::vector<SMosaicEntry> m_entries;
        bool                      m_asMosaic  = false; // the last arrangement was the mosaic, not its tiles
        bool                      m_tiledHold = false; // a resize went past its limit: tiles until the mosaic fits unshrunk
        bool                      m_asCanvas  = false; // the last arrangement was the infinite canvas
        MosaicPack::SCanvasPack   m_canvas;            // where everyone sits on it
        Vector2D                  m_canvasOffset;      // the view, 0..SCanvasView::max
        bool                      m_revealPending = false;
        CHyprSignalListener       m_focusHook;
        CHyprSignalListener       m_reloadHook;
        // THE USER'S ARRANGEMENT (2026-10-16): a drop (or a swap) put a window
        // where it is -- it keeps to that point (MosaicPack::PackHint) until a
        // window arrives or leaves; then the mosaic regroups tight.
        struct SDropAt {
            WP<Layout::ITarget> target;
            Vector2D            at; // global logical, where it was let go
        };
        std::optional<SDropAt>    m_dropAt;
        // THE DRAG HOLD (user, 2026-10-16: "when I start dragging a window to
        // move it around in the cluster, you should wait to rearrange other
        // windows until I drop the window or it moves to another desktop"). A
        // Super+drag floats the window out of the layout; while it is in the
        // air the others stay exactly where they are. It ends when the window
        // comes back (newTarget/movedTarget: the drop), lands on another
        // desktop, or the drag is over (Mosaic::onMove asks, releaseDragHold).
        WP<Layout::ITarget>       m_dragHold;
        void                      forgetArrangement() {
            m_dropAt.reset();
        }
        MosaicPack::CDwindleTree  m_tree;              // the tiles; empty while the mosaic stands
        long long                 m_nextId = 0;
        long long                 m_dragLeaf = -1;     // the tile a Super+drag picked its window out of
        Math::eDirection          m_overrideDir = Math::DIRECTION_DEFAULT; // dwindle's preselect

        // TRACE: every window's mosaic size at each arrangement decision.
        void traceEntries(const char* what) const {
            if (!traceOn())
                return;
            std::string line = std::format("arrange {} hold={} area={}x{} n={}", what, m_tiledHold, area() ? area()->w : 0.0, area() ? area()->h : 0.0, m_entries.size());
            for (const auto& E : m_entries) {
                const auto T = E.target.lock();
                const auto W = T ? T->window() : PHLWINDOW{};
                line += std::format(" [{} {:x} natural={}x{}]", appOf(W), (uintptr_t)W.get(), E.natural.x, E.natural.y);
            }
            trace(line);
        }

        // The tree follows the windows. Empty (the tiles just took over from
        // the mosaic): a balanced tree of everyone, in mosaic order. Otherwise
        // a window gone is removed (its sibling takes the space) and a window
        // new to the tiles splits the FOCUSED window's tile, as in dwindle.
        void syncTree() {
            // Tiles sized like the mosaic (CDwindleTree::buildWeighted): each
            // window weighs its mosaic area.
            const auto WEIGHT = [this](long long id) {
                for (const auto& E : m_entries)
                    if (E.id == id)
                        return E.natural.x * E.natural.y;
                return 0.0;
            };
            if (m_tree.empty()) {
                std::vector<long long> ids;
                std::vector<double>    weights;
                for (const auto& E : m_entries) {
                    ids.push_back(E.id);
                    weights.push_back(E.natural.x * E.natural.y);
                }
                m_tree.buildWeighted(ids, weights);
                return;
            }
            for (const auto ID : m_tree.ids())
                if (std::ranges::none_of(m_entries, [&](const SMosaicEntry& e) { return e.id == ID; }))
                    m_tree.remove(ID);
            long long focusedId = -1;
            if (const auto F = Desktop::focusState()->window())
                for (const auto& E : m_entries)
                    if (const auto T = E.target.lock(); T && T->window() == F)
                        focusedId = E.id;
            for (const auto& E : m_entries)
                if (!m_tree.has(E.id)) {
                    // The window that just arrived holds the focus by now; split
                    // the one focused before it, or the newest tile.
                    m_tree.insert(E.id, focusedId == E.id ? -1 : focusedId, WEIGHT);
                }
        }

        // How far past the calculated limit the pointer must ask before the
        // desktop darkens and letting go means tiles: enough that the limit
        // itself is a comfortable place to stop.
        static constexpr double PUSH_PAST = 48.0;
        static constexpr float  DIM       = 0.45F;

        struct SResize {
            WP<Layout::ITarget>                             target;
            Layout::eRectCorner                             corner = Layout::CORNER_NONE;
            CBox                                            start;     // the window's box when the drag began
            Vector2D                                        requested; // the size the pointer asks for
            Vector2D                                        shown;     // the size granted: requested, clamped to the limit
            Vector2D                                        grabOffset; // corner minus pointer, at the press
            bool                                            past  = false;
            bool                                            tiled = false; // began in the tiles: no limit, no dim
            std::vector<std::pair<WP<Layout::ITarget>, CBox>> frozen; // every OTHER window, where it stands
        };
        std::optional<SResize> m_resize;

        void beginResize(const SP<Layout::ITarget>& target, Layout::eRectCorner corner) {
            if (m_resize)
                finishResize();
            SResize r;
            r.target    = target;
            r.corner    = corner;
            r.tiled     = !m_asMosaic && !m_asCanvas;
            r.start     = target->position();
            r.requested = r.start.size();
            r.shown     = r.start.size();
            if (corner != Layout::CORNER_NONE) {
                const Vector2D CORNERPOS{Layout::edgeLeft(corner) ? r.start.x : r.start.x + r.start.w, Layout::edgeTop(corner) ? r.start.y : r.start.y + r.start.h};
                r.grabOffset = CORNERPOS - g_pInputManager->getMouseCoordsInternal();
            }
            for (const auto& E : m_entries)
                if (const auto T = E.target.lock(); T && T != target)
                    r.frozen.emplace_back(E.target, T->position());
            m_resize = std::move(r);
        }

        void stepResize() {
            if (!m_resize)
                return;
            const auto TARGET = m_resize->target.lock();
            const auto AREA   = area();
            if (!TARGET || !AREA) {
                m_resize.reset();
                return;
            }
            // In the layout's own order: the arrangement the limit proves is the
            // one recalculate() will build from the same sizes on release.
            std::vector<MosaicPack::SRect> sizes;
            size_t                         idx = 0;
            for (const auto& E : m_entries) {
                const auto T = E.target.lock();
                if (!T)
                    continue;
                if (T == TARGET) {
                    idx = sizes.size();
                    sizes.push_back({0, 0, m_resize->start.w, m_resize->start.h});
                    continue;
                }
                CBox box = T->position();
                for (const auto& [WT, BOX] : m_resize->frozen)
                    if (WT.lock() == T)
                        box = BOX;
                sizes.push_back({0, 0, box.w, box.h});
            }
            const MosaicPack::SRect AREAR{AREA->x, AREA->y, AREA->w, AREA->h};
            // THE CANVAS has no limit: a window that outgrows the screen's
            // mosaic sends the desktop onto the canvas when it is let go.
            if (canvasOn()) {
                m_resize->shown = Vector2D{std::clamp(m_resize->requested.x, MIN_SIDE, std::max(MIN_SIDE, AREA->w)),
                                           std::clamp(m_resize->requested.y, MIN_SIDE, std::max(MIN_SIDE, AREA->h))};
                applyResize();
                return;
            }
            const auto LIMIT = MosaicPack::limitFor(sizes, idx, m_resize->requested.x, m_resize->requested.y, AREAR, innerGap(), MIN_SIDE, looseArea());
            m_resize->shown  = Vector2D{LIMIT.w, LIMIT.h};
            const bool PAST  = !LIMIT.reached && (m_resize->requested.x > LIMIT.w + PUSH_PAST || m_resize->requested.y > LIMIT.h + PUSH_PAST);
            trace(std::format("step n={} start={}x{} requested={}x{} limit={}x{} reached={} past={} area={}x{}", sizes.size(), m_resize->start.w, m_resize->start.h,
                              m_resize->requested.x, m_resize->requested.y, LIMIT.w, LIMIT.h, LIMIT.reached, PAST, AREA->w, AREA->h));
            if (PAST != m_resize->past) {
                m_resize->past = PAST;
                setDim(PAST, *m_resize);
            }
            applyResize();
        }

        // The frozen windows where they stand, the resized one grown from its
        // opposite corner and kept on the desktop.
        void applyResize() {
            if (!m_resize)
                return;
            const auto TARGET = m_resize->target.lock();
            const auto AREA   = area();
            if (!TARGET || !AREA)
                return;
            for (const auto& [WT, BOX] : m_resize->frozen)
                if (const auto T = WT.lock())
                    T->setPositionGlobal(Layout::STargetBox{.logicalBox = BOX, .visualBox = BOX});
            const CBox&    S    = m_resize->start;
            const Vector2D SIZE = m_resize->shown;
            const auto     C    = m_resize->corner;
            // The corner opposite the one dragged stays put (a keyboard resize
            // grows about the centre).
            double x = C == Layout::CORNER_NONE ? S.x + (S.w - SIZE.x) / 2.0 : Layout::edgeLeft(C) ? S.x + S.w - SIZE.x : S.x;
            double y = C == Layout::CORNER_NONE ? S.y + (S.h - SIZE.y) / 2.0 : Layout::edgeTop(C) ? S.y + S.h - SIZE.y : S.y;
            if (!m_asCanvas) {
                x = std::clamp(x, AREA->x, std::max(AREA->x, AREA->x + AREA->w - SIZE.x));
                y = std::clamp(y, AREA->y, std::max(AREA->y, AREA->y + AREA->h - SIZE.y));
            }
            const CBox BOX{std::round(x), std::round(y), std::round(SIZE.x), std::round(SIZE.y)};
            TARGET->setPositionGlobal(Layout::STargetBox{.logicalBox = BOX, .visualBox = BOX});
        }

        // Past the limit: every OTHER window dims, so the desktop reads as about
        // to change. Hyprland's own per-window dim, handed back to dim_inactive
        // and friends afterwards.
        void setDim(bool on, const SResize& r) {
            for (const auto& [WT, BOX] : r.frozen) {
                const auto T = WT.lock();
                const auto W = T ? T->window() : PHLWINDOW{};
                if (!W)
                    continue;
                if (on)
                    *W->m_dimPercent = DIM;
                else
                    W->updateDecorationValues();
            }
        }

        int indexOf(const SP<Layout::ITarget>& t) const {
            for (size_t i = 0; i < m_entries.size(); ++i)
                if (m_entries[i].target.lock() == t)
                    return sc<int>(i);
            return -1;
        }

        // The space between two neighbours: the same as between two tiles, each
        // of which is inset by its side's gaps_in.
        double innerGap() const {
            static auto PGAPSIN = CConfigValue<::Config::IComplexConfigValue>("general:gaps_in");
            const auto* GAPS    = sc<::Config::CCssGapData*>(PGAPSIN.ptr());
            return GAPS ? sc<double>(GAPS->m_left + GAPS->m_right) : 10.0;
        }

        // THE SIZE A WINDOW KEEPS, decided once, when it arrives
        // (MosaicPack::chooseNatural has the order). desiredGeometry() is the
        // window's CURRENT size, so it is only the client's own choice the
        // moment a NEW window maps; one moving in from another layout carries
        // that layout's tile -- which is why a window this session already
        // sized in a mosaic keeps that size first. Nothing: three fifths of the
        // desktop.
        MosaicPack::SNatural naturalFor(const SP<Layout::ITarget>& t, bool fresh) const {
            CBox AREA{0, 0, 1280, 720};
            if (m_parent && m_parent->space())
                AREA = m_parent->space()->workArea();
            const auto SZ = [](const Vector2D& v) { return MosaicPack::SSize{v.x, v.y}; };
            MosaicPack::SNaturalInputs in{.fallback = {std::round(AREA.w * 0.6), std::round(AREA.h * 0.6)}, .fresh = fresh};
            if (t) {
                if (const auto KEPT = rememberedWindow(t)) {
                    in.kept        = SZ(*KEPT);
                    in.keptTrusted = keptTrusted(t->window());
                }
                loadSizes();
                if (const auto IT = g_sizes.find(appOf(t->window())); IT != g_sizes.end())
                    in.app = SZ(IT->second);
                in.floating = SZ(t->lastFloatingSize());
                if (const auto D = t->desiredGeometry(); D)
                    in.desired = SZ(D->size);
            }
            return MosaicPack::chooseNatural(in, MIN_SIDE);
        }
    };

    // ------------------------------------------------------------ corner grab --
    // CORNER RESIZE (user, 2026-10-11: "if I hold down super and go to the
    // corner of a window i can resize it, that or corner resize is always
    // available in mosaic"). Both:
    //   - on a mosaic desktop, a plain left press on a window's corner resizes
    //     it, and the pointer shows the resize cursor over a corner;
    //   - with Super held, the same press resizes on ANY layout, in place of
    //     Omarchy's Super+drag move -- which still moves from anywhere else.
    // The resize is Hyprland's own drag (beginDragTarget with the corner
    // forced), so tiled layouts get resizeTarget and floating windows their
    // usual live resize. The press is claimed, so Hyprland's bind handler never
    // sees it and would never end the drag: the matching release ends it here.
    namespace {
        bool        g_ourDrag   = false;
        bool        g_hoverSet  = false;
        // How far INSIDE a window a corner reaches. Outside, it is Hyprland's
        // own border grab width; inside, only this much, so an app's own
        // controls in its corners keep their clicks.
        constexpr double INNER = 6.0;

        bool onMosaic(const PHLWINDOW& w) {
            return w && std::ranges::any_of(g_instances, [&](const CMosaicAlgorithm* a) { return a->holds(w); });
        }

        // The corner -- or EDGE -- of `w` under `p`, or CORNER_NONE. EDGES (user,
        // 2026-10-15: "drag edges to resize in mosaic ... it only works on
        // corners and not on top/bottom edges"): a side reaches out into the
        // gap like a corner, but INSIDE the window only with Super held, so an
        // app's own top row (a browser's tabs) keeps its clicks.
        Layout::eRectCorner cornerAt(const PHLWINDOW& w, const Vector2D& p, bool superHeld) {
            static auto PBORDER = CConfigValue<::Config::INTEGER>("general:border_size");
            static auto PEXTEND = CConfigValue<::Config::INTEGER>("general:extend_border_grab_area");
            const double OUT    = std::max<double>(8.0, sc<double>(*PBORDER + *PEXTEND));
            const CBox   B      = w->geometricBox(Desktop::View::IGeometric::GEOMETRIC_CURRENT);
            const bool   LEFT   = p.x >= B.x - OUT && p.x <= B.x + INNER;
            const bool   RIGHT  = p.x >= B.x + B.w - INNER && p.x <= B.x + B.w + OUT;
            const bool   TOP    = p.y >= B.y - OUT && p.y <= B.y + INNER;
            const bool   BOTTOM = p.y >= B.y + B.h - INNER && p.y <= B.y + B.h + OUT;
            if (TOP && LEFT)
                return Layout::CORNER_TOPLEFT;
            if (TOP && RIGHT)
                return Layout::CORNER_TOPRIGHT;
            if (BOTTOM && LEFT)
                return Layout::CORNER_BOTTOMLEFT;
            if (BOTTOM && RIGHT)
                return Layout::CORNER_BOTTOMRIGHT;
            const double IN    = superHeld ? INNER : 0.0;
            const bool   SPANX = p.x >= B.x && p.x <= B.x + B.w, SPANY = p.y >= B.y && p.y <= B.y + B.h;
            if (SPANX && p.y >= B.y - OUT && p.y <= B.y + IN)
                return Layout::CORNER_TOP;
            if (SPANX && p.y >= B.y + B.h - IN && p.y <= B.y + B.h + OUT)
                return Layout::CORNER_BOTTOM;
            if (SPANY && p.x >= B.x - OUT && p.x <= B.x + IN)
                return Layout::CORNER_LEFT;
            if (SPANY && p.x >= B.x + B.w - IN && p.x <= B.x + B.w + OUT)
                return Layout::CORNER_RIGHT;
            return Layout::CORNER_NONE;
        }

        const char* cursorFor(Layout::eRectCorner c) {
            switch (c) {
                case Layout::CORNER_TOPLEFT: return "nw-resize";
                case Layout::CORNER_TOPRIGHT: return "ne-resize";
                case Layout::CORNER_BOTTOMLEFT: return "sw-resize";
                case Layout::CORNER_TOP: return "n-resize";
                case Layout::CORNER_BOTTOM: return "s-resize";
                case Layout::CORNER_LEFT: return "w-resize";
                case Layout::CORNER_RIGHT: return "e-resize";
                default: return "se-resize";
            }
        }

        // Which window's corner the pointer is on, if any. The corner zone
        // reaches past the window into the gap, where the hit test finds no
        // window -- so every window of the visible desktops is asked, the
        // focused one first (floating windows overlap).
        //
        // A zone COVERED by a floating window is not a zone (user, 2026-10-19:
        // "floating windows over tiled/scrolling/mosaic windows don't let me
        // click in the floating window"). The zones are geometry, not hit tests,
        // so a tiled window's edge and its reach into the gap went on claiming
        // presses inside a floating window drawn over them. The window really
        // under the pointer, border grab area included, decides: a floating one
        // that is not `w` hides w's zone, and gets its own corners when asked.
        std::pair<PHLWINDOW, Layout::eRectCorner> cornerTarget(const Vector2D& p, bool superHeld) {
            const auto TOP =
                Desktop::viewState()->hitTest().windowAt(p, Desktop::View::RESERVED_EXTENTS | Desktop::View::INPUT_EXTENTS | Desktop::View::ALLOW_FLOATING);
            const bool TOPFLOATS = TOP && TOP->layoutTarget() && TOP->layoutTarget()->floating();
            const auto TRY       = [&](const PHLWINDOW& w) -> Layout::eRectCorner {
                if (!w || !w->m_isMapped || w->isHidden() || !w->m_workspace || !w->m_workspace->isVisible() || Fullscreen::controller()->isFullscreen(w) ||
                    (w->m_isX11 && w->isX11OverrideRedirect()) || !w->layoutTarget())
                    return Layout::CORNER_NONE;
                if (TOPFLOATS && TOP != w)
                    return Layout::CORNER_NONE;
                // Without Super only a TILED window of a mosaic desktop has corners.
                if (!superHeld && (w->layoutTarget()->floating() || !onMosaic(w)))
                    return Layout::CORNER_NONE;
                return cornerAt(w, p, superHeld);
            };
            if (const auto F = Desktop::focusState()->window(); F)
                if (const auto C = TRY(F); C != Layout::CORNER_NONE)
                    return {F, C};
            for (const auto& W : Desktop::windowState()->windows())
                if (const auto C = TRY(W); C != Layout::CORNER_NONE)
                    return {W, C};
            return {nullptr, Layout::CORNER_NONE};
        }

        // Plain (no modifier) or Super alone; anything else is someone's chord.
        int modsNow() {
            return sc<int>(g_pInputManager->getModsFromAllKBs());
        }
    }

    // A mosaic resize ends when the drag controller lets the window go --
    // whoever started the drag (our corner grab, or Super + right-drag). Asked
    // when our own drag ends, and on every pointer motion.
    static void checkResizeEnded() {
        const auto DRAGGED = g_layoutManager ? g_layoutManager->dragController()->target() : SP<Layout::ITarget>{};
        for (auto* A : g_instances)
            if (A->resizing() && !(DRAGGED && A->resizingTarget(DRAGGED)))
                A->finishResize();
    }

    bool onButton(const IPointer::SButtonEvent& e, bool blocked) {
        const bool PRESSED = e.state == WL_POINTER_BUTTON_STATE_PRESSED;
        if (!PRESSED) {
            if (g_ourDrag && e.button == BTN_LEFT) {
                g_ourDrag = false;
                if (g_layoutManager && g_layoutManager->dragController()->target())
                    g_layoutManager->endDragTarget();
                // Our drag is over now: settle the resize at once. (A drag
                // Hyprland started -- Super+right-drag -- ends after this hook;
                // the next pointer motion settles it. No doLater: one still
                // queued at unload jumps into unmapped code.)
                checkResizeEnded();
                return true;
            }
            return false;
        }
        if (blocked || e.button != BTN_LEFT || !g_layoutManager || g_layoutManager->dragController()->target())
            return false;
        const int MODS = modsNow();
        if (MODS != 0 && MODS != HL_MODIFIER_META)
            return false;
        const auto [W, CORNER] = cornerTarget(g_pInputManager->getMouseCoordsInternal(), MODS == HL_MODIFIER_META);
        if (!W || CORNER == Layout::CORNER_NONE)
            return false;
        g_layoutManager->beginDragTarget(W->layoutTarget(), MBIND_RESIZE, CORNER);
        g_ourDrag = g_layoutManager->dragController()->target() != nullptr;
        return g_ourDrag;
    }

    // ------------------------------------------------------------ the canvas view --
    static CMosaicAlgorithm* canvasOf(const PHLWORKSPACE& ws) {
        if (!ws)
            return nullptr;
        for (auto* A : g_instances)
            if (A->workspace() == ws && A->arrangedAsCanvas())
                return A;
        return nullptr;
    }

    SCanvasProbe canvasProbe(const PHLWORKSPACE& ws) {
        SCanvasProbe p;
        const auto*  A = canvasOf(ws);
        const auto   V = A ? A->canvasViewNow() : std::nullopt;
        if (!V)
            return p;
        p.offset    = A->canvasOffset().x;
        p.maxOffset = V->maxX;
        p.usable    = V->maxX > 1.0;
        return p;
    }

    void canvasSetOffset(const PHLWORKSPACE& ws, double offsetX, bool warp) {
        if (auto* A = canvasOf(ws))
            A->setCanvasOffset(Vector2D{offsetX, A->canvasOffset().y}, warp);
    }

    std::optional<CBox> canvasBox(const PHLWORKSPACE& ws) {
        const auto* A = canvasOf(ws);
        const auto  V = A ? A->canvasViewNow() : std::nullopt;
        const auto  S = A ? A->canvasSize() : Vector2D{};
        if (!V || S.x < 1 || S.y < 1)
            return std::nullopt;
        return CBox{V->originX - A->canvasOffset().x, V->originY - A->canvasOffset().y, S.x, S.y};
    }

    void canvasPanning(bool on) {
        g_canvasPanning = on;
    }

    void canvasSettle(const PHLWORKSPACE& ws) {
        g_canvasPanning = false;
        const auto* A = canvasOf(ws);
        if (!A)
            return;
        // Keys go to a window you can see: the focused one if it is still
        // mostly in view, else the one showing most of itself.
        const auto F = Desktop::focusState()->window();
        if (F && A->holds(F) && A->visibleShare(F) >= 0.5)
            return;
        if (const auto BEST = A->mostVisible())
            Desktop::focusState()->fullWindowFocus(BEST, Desktop::FOCUS_REASON_KEYBIND);
    }

    bool canvasStep(const PHLWORKSPACE& ws, int dir) {
        auto*      A    = canvasOf(ws);
        const auto V    = A ? A->canvasViewNow() : std::nullopt;
        const auto AREA = A ? A->canvasArea() : std::nullopt;
        if (!V || !AREA || V->maxX <= 1.0)
            return false;
        const double X = A->canvasOffset().x;
        if ((dir > 0 && X >= V->maxX - 0.5) || (dir < 0 && X <= 0.5))
            return false; // at that end: the step goes on to the next desktop
        A->setCanvasOffset(Vector2D{std::clamp(X + dir * AREA->w * 0.5, 0.0, V->maxX), A->canvasOffset().y}, false);
        if (const auto BEST = A->mostVisible(); BEST && A->visibleShare(Desktop::focusState()->window()) < 0.5) {
            g_canvasPanning = true;
            Desktop::focusState()->fullWindowFocus(BEST, Desktop::FOCUS_REASON_KEYBIND);
            g_canvasPanning = false;
        }
        return true;
    }

    // ALL DIRECTIONS (user, 2026-10-26: "I can hold down super and my cursor
    // movement maps to the entire collection of the screens so that ... the
    // top/bottom portions of the screen result in my cursor being at the
    // top/bottom of the canvas"). Super alone held, no button: the pointer's
    // place on its monitor is the view's place on the canvas, both axes.
    static bool superPan(bool blocked) {
        if (blocked || !canvasAllDirections() || (g_layoutManager && g_layoutManager->dragController()->target()))
            return false;
        if (modsNow() != HL_MODIFIER_META)
            return false;
        const Vector2D P   = g_pInputManager->getMouseCoordsInternal();
        const auto     MON = State::monitorState()->query().vec(P).run();
        if (!MON || MON->m_activeSpecialWorkspace || openScrollOverviewForMonitor(MON))
            return false;
        auto*      A = canvasOf(MON->m_activeWorkspace);
        const auto V = A ? A->canvasViewNow() : std::nullopt;
        if (!V || (V->maxX <= 1.0 && V->maxY <= 1.0))
            return false;
        const CBox   B  = MON->logicalBox();
        const double FX = B.w > 0 ? std::clamp((P.x - B.x) / B.w, 0.0, 1.0) : 0.0, FY = B.h > 0 ? std::clamp((P.y - B.y) / B.h, 0.0, 1.0) : 0.0;
        const Vector2D WANT{FX * V->maxX, FY * V->maxY};
        if (std::abs(WANT.x - A->canvasOffset().x) < 0.5 && std::abs(WANT.y - A->canvasOffset().y) < 0.5)
            return true;
        g_canvasPanning = true;
        A->setCanvasOffset(WANT, true);
        // Super was held to pan, not tapped: no overview on its release.
        ScrollOverview::cancelSuperTap();
        return true;
    }

    void onMove(bool blocked) {
        if (!superPan(blocked) && g_canvasPanning && modsNow() != HL_MODIFIER_META) {
            // The Super-pan is over: the focused window is where the pointer is.
            g_canvasPanning = false;
        }
        if (std::ranges::any_of(g_instances, [](const CMosaicAlgorithm* a) { return a->resizing(); }))
            checkResizeEnded();
        // A drag hold whose window was let go elsewhere, or carried to another
        // desktop: close up now.
        for (auto* A : g_instances)
            if (A->holdingFor() && !A->dragHoldLive())
                A->releaseDragHold();
        const bool DRAGGING = g_layoutManager && g_layoutManager->dragController()->target();
        Layout::eRectCorner corner = Layout::CORNER_NONE;
        if (!blocked && !DRAGGING) {
            const int MODS = modsNow();
            if (MODS == 0 || MODS == HL_MODIFIER_META)
                corner = cornerTarget(g_pInputManager->getMouseCoordsInternal(), MODS == HL_MODIFIER_META).second;
        }
        if (corner != Layout::CORNER_NONE) {
            Pointer::Cursor::overrideController->setOverride(cursorFor(corner), Pointer::Cursor::CURSOR_OVERRIDE_WINDOW_EDGE);
            g_hoverSet = true;
        } else if (g_hoverSet && !DRAGGING) {
            Pointer::Cursor::overrideController->unsetOverride(Pointer::Cursor::CURSOR_OVERRIDE_WINDOW_EDGE);
            g_hoverSet = false;
        }
    }

    void shutdown() {
        if (g_ourDrag && g_layoutManager && g_layoutManager->dragController()->target())
            g_layoutManager->endDragTarget();
        g_ourDrag = false;
        if (g_hoverSet)
            Pointer::Cursor::overrideController->unsetOverride(Pointer::Cursor::CURSOR_OVERRIDE_WINDOW_EDGE);
        g_hoverSet = false;
    }

    void onWindowClose(const PHLWINDOW& w) {
        const auto APP = appOf(w);
        if (APP.empty())
            return;
        for (const auto* A : g_instances)
            if (A->holds(w)) {
                // Only a size the app or the user chose (SNatural::trusted):
                // never a tile or a size inherited from another layout.
                if ((A->arrangedAsMosaic() || A->arrangedAsCanvas()) && A->trustedOf(w))
                    if (const auto N = A->naturalOf(w))
                        saveSize(APP, *N);
                return;
            }
    }

    // FOCUS BY DIRECTION (user, 2026-10-14: "I need super+arrowkeys to be able
    // to switch focus between windows in mosaic"). Hyprland's own movefocus
    // looks for a window whose edge lines up with the focused one's across the
    // gap -- what dwindle and scrolling always have, and a mosaic's centred,
    // bunched cluster mostly does not. hl.plugin.hyprdrive.focus("l"|"r"|"u"|"d"),
    // bound to Super+arrows while Mosaic is on (the panel's fragment): on a
    // mosaic desktop, the window whose centre lies that way, nearest along the
    // direction and closest across it; anywhere else -- or with nothing that
    // way -- exactly Hyprland's movefocus, so dwindle and scrolling (and the
    // move to the next monitor at the edge) are unchanged.
    static Math::eDirection dirOf(const std::string& arg) {
        const char C = arg.empty() ? 'l' : arg[0];
        return C == 'r' ? Math::DIRECTION_RIGHT : C == 'u' ? Math::DIRECTION_UP : C == 'd' ? Math::DIRECTION_DOWN : Math::DIRECTION_LEFT;
    }

    // The window that way from `from` on its mosaic desktop: its centre lies
    // that way, nearest along the direction and closest across it. Null off a
    // mosaic desktop, or with nothing that way.
    // In the TILES the windows share edges, as in dwindle: Hyprland's own
    // movefocus/swapwindow are dwindle's, so the mosaic's centre rule stands
    // aside there (user, 2026-10-23: the tiles "should behave exactly like
    // dwindle").
    static PHLWINDOW mosaicNeighbour(const PHLWINDOW& from, Math::eDirection dir) {
        if (!from || !from->m_workspace ||
            !std::ranges::any_of(g_instances, [&](const CMosaicAlgorithm* a) { return a->holds(from) && (a->arrangedAsMosaic() || a->arrangedAsCanvas()); }))
            return nullptr;
        const Vector2D D  = dir == Math::DIRECTION_RIGHT ? Vector2D{1, 0} : dir == Math::DIRECTION_LEFT ? Vector2D{-1, 0} : dir == Math::DIRECTION_UP ? Vector2D{0, -1} : Vector2D{0, 1};
        const auto     C0 = from->middle();
        PHLWINDOW      best;
        double         bestScore = 1e18;
        for (const auto& W : Desktop::windowState()->windows()) {
            if (!W || W == from || !W->m_isMapped || W->isHidden() || W->m_workspace != from->m_workspace || !onMosaic(W))
                continue;
            const auto   V     = W->middle() - C0;
            const double ALONG = V.x * D.x + V.y * D.y;
            if (ALONG <= 1.0)
                continue;
            const double ACROSS = std::abs(V.x * D.y - V.y * D.x);
            const double SCORE  = ALONG + 2.0 * ACROSS;
            if (SCORE < bestScore) {
                bestScore = SCORE;
                best      = W;
            }
        }
        return best;
    }

    static SDispatchResult onFocusDispatcher(std::string arg) {
        const auto DIR = dirOf(arg);
        if (const auto BEST = mosaicNeighbour(Desktop::focusState()->window(), DIR)) {
            (void)::Config::Actions::focus(BEST);
            return {};
        }
        (void)::Config::Actions::moveFocus(DIR);
        return {};
    }

    // SWAP BY DIRECTION (user, 2026-10-16: "I also need windows to be switchable
    // with keyboard commands like in pure dwindle, while in mosaic").
    // hl.plugin.hyprdrive.swap("l"|"r"|"u"|"d"), bound to Super+Shift+arrows
    // with the focus binds: Hyprland's swapwindow looks for the window across a
    // shared edge, as movefocus does, and finds none in a bunched cluster. On a
    // mosaic desktop the focused window trades places with the window focus
    // would move to (Hyprland's own swap, so the layout's swapTargets: the
    // focused window is dropped where the other stood -- MosaicPack::PackHint
    // -- still one cluster with no holes);
    // anywhere else, exactly Hyprland's swapwindow.
    static SDispatchResult onSwapDispatcher(std::string arg) {
        const auto DIR     = dirOf(arg);
        const auto FOCUSED = Desktop::focusState()->window();
        if (const auto BEST = mosaicNeighbour(FOCUSED, DIR)) {
            (void)::Config::Actions::swapWith(BEST, FOCUSED);
            return {};
        }
        (void)::Config::Actions::swapInDirection(DIR);
        return {};
    }

    // A WINDOW THAT OPENS FLOATING (user, 2026-10-14: "windows that already
    // come up as floating do not get properly included into the mosaic group").
    // A float -- by a window rule, or because the app asked -- belongs to
    // Hyprland's floating layout, which the mosaic never sees, so it landed on
    // top of the cluster instead of in it. On a mosaic desktop, where every
    // window keeps its own size anyway, it joins the mosaic. Real dialogs stay
    // afloat: anything with a parent window (a transient, an X11 child), a
    // modal, an override-redirect popup, a pinned or fullscreen window. So
    // does a float a window rule tags `hyprdrive-float` (user, 2026-10-15: a
    // Sushi preview joined the mosaic and every window re-packed around it,
    // then back when it closed): a preview or a picker is a passing overlay,
    // not a member of the desktop. 25-rules.lua tags Sushi; a user tags any
    // other app the same way.
    static CHyprSignalListener g_openLateHook;
    static CHyprSignalListener g_floatingHook; // g_windowSizes: a window floated

    static bool onMosaicWorkspace(const PHLWORKSPACE& ws) {
        return ws && std::ranges::any_of(g_instances, [&](const CMosaicAlgorithm* a) { return a->workspace() == ws; });
    }

    static void adoptFloating(const PHLWINDOW& w) {
        if (!w || !w->m_isMapped || !w->m_isFloating || !onMosaicWorkspace(w->m_workspace))
            return;
        if (w->parent() || w->isModal() || w->m_pinned || Fullscreen::controller()->isFullscreen(w) || (w->m_isX11 && (w->isX11OverrideRedirect() || w->x11Parent())))
            return;
        if (w->m_ruleApplicator && w->m_ruleApplicator->m_tagKeeper.isTagged("hyprdrive-float"))
            return;
        trace(std::format("adopt floating window {:x} into the mosaic", (uintptr_t)w.get()));
        (void)::Config::Actions::floatWindow(::Config::Actions::TOGGLE_ACTION_DISABLE, w);
    }

    void registerLayout(HANDLE handle) {
        // Before the algo exists: windows re-arrive inside addTiledAlgo.
        loadKept();
        HyprlandAPI::addTiledAlgo(handle, "mosaic", &typeid(CMosaicAlgorithm), [] { return makeUnique<CMosaicAlgorithm>(); });
        ScrollOverview::Config::registerDispatcher("focus", onFocusDispatcher);
        ScrollOverview::Config::registerDispatcher("swap", onSwapDispatcher);
        // After the window's rules are in (openLate). Directly, never a
        // doLater: a deferred call still queued when the plugin unloads jumps
        // into unmapped code (the unload SEGVs, 2026-09).
        g_openLateHook = Event::bus()->m_events.window.openLate.listen([](PHLWINDOW w) { adoptFloating(w); });
        g_floatingHook = Event::bus()->m_events.window.floating.listen([](PHLWINDOW w) { onFloating(w); });
    }

    void unregisterLayout(HANDLE handle) {
        g_openLateHook.reset();
        g_floatingHook.reset();
        // Before the algo goes: removing it hands the desktops to dwindle.
        saveKept();
        HyprlandAPI::removeAlgo(handle, "mosaic");
    }
}
