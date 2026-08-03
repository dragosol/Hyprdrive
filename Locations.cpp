#include "Locations.hpp"

#include "Config.hpp"

#include <gio/gio.h>
#include <gio/gunixmounts.h>
#include <systemd/sd-bus.h>

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <string>
#include <string_view>
#include <unordered_set>
#include <vector>

#include <hyprutils/os/Process.hpp>

using namespace Hyprutils::OS;

namespace ScrollOverview::Locations {

namespace {

    constexpr const char* KEY_SHOW_TRASH  = "plugin:scrolloverview:dock:show_trash";
    constexpr const char* KEY_SHOW_MOUNTS = "plugin:scrolloverview:dock:show_mounts";
    constexpr const char* KEY_MOUNTS_NET  = "plugin:scrolloverview:dock:show_mounts_network";

    constexpr const char* TRASH_URI = "trash:///";

    // `UPDATE_TRASH_DELAY`. The reference debounces the trash monitor by this
    // much; here it is the poll period for the whole set, because the dock asks
    // items() once per frame and neither the trash count nor the mount table
    // moves at 120Hz.
    constexpr auto POLL = std::chrono::milliseconds{1000};

    // The hard ceiling on the one D-Bus round trip the poll makes. A poll that
    // costs longer than this is a dropped frame, and a dock item's running dot
    // is not worth one.
    constexpr uint64_t TIMEOUT_US = 20'000;

    // `FALLBACK_TRASH_ICON` / `FALLBACK_REMOVABLE_MEDIA_ICON`.
    constexpr const char* FALLBACK_TRASH = "user-trash";
    constexpr const char* FALLBACK_MEDIA = "drive-removable-media";

    std::vector<SLocation>                g_items;
    std::chrono::steady_clock::time_point g_polled{};
    bool                                  g_have = false;

    std::unordered_set<std::string>       g_openLocations;

    // The first name a GIcon offers, which is the one the icon theme is asked
    // for. A GFileIcon -- a custom per-directory icon -- has no name at all and
    // falls back: resolving it would mean teaching the render layer about file
    // paths for a case neither the trash nor a mount hits.
    std::string iconName(GIcon* icon) {
        if (!icon || !G_IS_THEMED_ICON(icon))
            return {};

        const char* const* NAMES = g_themed_icon_get_names(G_THEMED_ICON(icon));
        return NAMES && NAMES[0] ? std::string{NAMES[0]} : std::string{};
    }

    // `TrashAppInfo`. Empty-or-not, read as a DIRECTORY rather than as
    // `trash:///`.
    //
    // The reference asks GIO, and the first cut here did too -- and wedged the
    // compositor. `g_file_query_info("trash:///")` is a synchronous D-Bus round
    // trip to gvfsd-trash, on the render thread, once a second; when the
    // backend is slow or absent that is a stall the frame loop cannot absorb.
    // Measured 2026-08-03: the guest stopped answering hyprctl entirely.
    //
    // ponytail: the HOME trash only. Files deleted on another filesystem live
    // in `<mount>/.Trash-1000` and are not counted here, so the icon can read
    // empty while another disk's trash is not. Upgrade path is to walk the same
    // mount list readMounts() already reads and stat each one's `.Trash-$UID`.
    void readTrash(SLocation& out) {
        out.uri   = TRASH_URI;
        out.name  = "Trash";
        out.empty = true;

        const char* HOME = std::getenv("HOME");
        if (HOME) {
            const std::string FILES = std::string{HOME} + "/.local/share/Trash/files";
            std::error_code   error;
            out.empty = !std::filesystem::exists(FILES, error) || std::filesystem::is_empty(FILES, error) || error;
        }

        // The two names the icon theme spells the two states with, and the same
        // two GIO would have answered with.
        out.icon = out.empty ? FALLBACK_TRASH : std::string{FALLBACK_TRASH} + "-full";
    }

    // `volume.get_identifier('class') === 'network'`. That identifier is gvfs
    // metadata; the filesystem type is the same fact straight from the kernel,
    // and it is what the local backend classifies on too.
    constexpr bool networkFs(const char* fsType) {
        if (!fsType)
            return false;

        constexpr std::string_view NETWORK[] = {"nfs", "nfs4", "cifs", "smbfs", "smb3", "sshfs", "ftp", "davfs", "afp", "ceph", "glusterfs", "9p"};

        std::string_view type{fsType};
        if (type.starts_with("fuse."))
            type.remove_prefix(5);

        return std::ranges::contains(NETWORK, type);
    }

    // The one piece of X35 the pixel rig cannot reach -- mounting a real NFS
    // export in the test VM to prove a string comparison is not a trade worth
    // making -- so it is checked at COMPILE time instead, and a broken prefix
    // strip or a mistyped entry fails the build rather than the dock.
    static_assert(networkFs("nfs4"));
    static_assert(networkFs("fuse.sshfs"));  // the prefix the kernel actually reports
    static_assert(!networkFs("ext4"));
    static_assert(!networkFs("fuse."));      // the strip must not leave a match on nothing
    static_assert(!networkFs("nfs4x"));      // and it is whole-word, not a prefix test
    static_assert(!networkFs(nullptr));

    // ponytail: MOUNTED volumes only, read from the kernel's mount table.
    //
    // `show-mounts-only-mounted` is TRUE in the target config, and that is
    // exactly the set the mount table holds -- so this needs neither the gvfs
    // proxy volume monitor nor a GMainLoop to drive it, and it cannot go stale
    // between polls the way a monitor with no loop to pump it would.
    //
    // The ceiling: a volume that is present but NOT mounted -- an inserted disc,
    // an unmounted partition -- has no row here and so no icon, which is what
    // `show_mounts_only_mounted false` would have to show. Upgrade path is
    // `g_volume_monitor_get()` + `g_volume_monitor_get_volumes()` on a PRIVATE
    // GMainContext pumped with `g_main_context_iteration(ctx, FALSE)` at the top
    // of each poll -- private because iterating the default context inside the
    // compositor would dispatch whatever else glib has queued there.
    void readMounts(std::vector<SLocation>& out) {
        const bool NET = Config::getValue<bool>(KEY_MOUNTS_NET);

        GList* mounts = g_unix_mount_entries_get(nullptr);
        for (GList* l = mounts; l; l = l->next) {
            auto* entry = static_cast<GUnixMountEntry*>(l->data);
            if (!entry)
                continue;

            // `mount.is_shadowed()` and `!can_eject() && !can_unmount()` in one:
            // a mount the platform calls internal is /proc, /sys, the root and
            // every bind under them, and nothing there is unmountable by a user.
            if (g_unix_mount_entry_is_system_internal(entry) || !g_unix_mount_entry_guess_should_display(entry))
                continue;

            if (networkFs(g_unix_mount_entry_get_fs_type(entry)) && !NET)
                continue;

            const char* PATH = g_unix_mount_entry_get_mount_path(entry);
            if (!PATH)
                continue;

            char* uri   = g_filename_to_uri(PATH, nullptr, nullptr);
            char* label = g_unix_mount_entry_guess_name(entry);
            GIcon* icon = g_unix_mount_entry_guess_icon(entry);

            SLocation loc;
            loc.uri      = uri ? std::string{uri} : std::string{"file://"} + PATH;
            loc.name     = label ? std::string{label} : std::string{PATH};
            loc.icon     = iconName(icon);
            loc.mount    = true;
            loc.canEject = g_unix_mount_entry_guess_can_eject(entry);

            if (loc.icon.empty())
                loc.icon = FALLBACK_MEDIA;

            out.emplace_back(std::move(loc));

            if (icon)
                g_object_unref(icon);
            g_free(uri);
            g_free(label);
        }

        g_list_free_full(mounts, reinterpret_cast<GDestroyNotify>(g_unix_mount_entry_free));
    }

    // One connection for the lifetime of the process. Opening a user bus means
    // a connect and an auth handshake, and doing that once a second on the
    // render thread is a cost with no reason to exist.
    sd_bus* userBus() {
        static sd_bus* bus = [] {
            sd_bus* b = nullptr;
            return sd_bus_default_user(&b) < 0 ? nullptr : b;
        }();

        return bus;
    }

    // Every location any file-manager window currently shows. The property is
    // `a{sas}` -- window id -> locations -- and only the VALUES are read: which
    // window shows it is a question nothing here asks, and one with no reliable
    // answer under Wayland.
    //
    // Built by hand rather than with sd_bus_get_property because two things
    // about the call matter more than its brevity, and that helper exposes
    // neither: it must NOT activate Nautilus (a dock poll is not a reason to
    // start a file manager, and the activation wait is seconds long), and it
    // must give up fast. This runs on the render thread once a second.
    void readOpenLocations() {
        g_openLocations.clear();

        sd_bus* bus = userBus();
        if (!bus)
            return;

        sd_bus_message* call = nullptr;
        if (sd_bus_message_new_method_call(bus, &call, "org.freedesktop.FileManager1", "/org/freedesktop/FileManager1", "org.freedesktop.Properties", "Get") < 0 || !call)
            return;

        sd_bus_message_set_auto_start(call, 0);
        sd_bus_message_append(call, "ss", "org.freedesktop.FileManager1", "OpenWindowsWithLocations");

        sd_bus_error    error = SD_BUS_ERROR_NULL;
        sd_bus_message* reply = nullptr;

        const int R = sd_bus_call(bus, call, TIMEOUT_US, &error, &reply);
        sd_bus_message_unref(call);

        if (R >= 0 && reply && sd_bus_message_enter_container(reply, 'v', "a{sas}") > 0 && sd_bus_message_enter_container(reply, 'a', "{sas}") > 0) {
            while (sd_bus_message_enter_container(reply, 'e', "sas") > 0) {
                sd_bus_message_skip(reply, "s"); // the window id

                char** uris = nullptr;
                if (sd_bus_message_read_strv(reply, &uris) > 0 && uris) {
                    for (char** u = uris; *u; ++u) {
                        g_openLocations.insert(*u);
                        free(*u);
                    }
                    free(uris);
                }

                sd_bus_message_exit_container(reply);
            }
            sd_bus_message_exit_container(reply);
            sd_bus_message_exit_container(reply);
        }

        if (reply)
            sd_bus_message_unref(reply);
        sd_bus_error_free(&error);
    }

    void spawn(const std::string& binary, const std::vector<std::string>& args) {
        CProcess process(binary, args);
        process.runAsync();
    }
}

const std::vector<SLocation>& items() {
    const auto NOW = std::chrono::steady_clock::now();
    if (g_have && NOW - g_polled < POLL)
        return g_items;

    g_polled = NOW;
    g_have   = true;
    g_items.clear();

    // `Locations.getApps()`: removables first, then the trash.
    if (Config::getValue<bool>(KEY_SHOW_MOUNTS))
        readMounts(g_items);

    if (Config::getValue<bool>(KEY_SHOW_TRASH))
        readTrash(g_items.emplace_back());

    readOpenLocations();

    return g_items;
}

bool openWindows(const std::string& uri) {
    if (g_openLocations.contains(uri))
        return true;

    // Nautilus reports the trash as `trash:///`, `trash://` or `trash:`
    // depending on how the window was opened, so the one location with three
    // spellings is compared on all of them rather than missed two times in
    // three.
    if (uri == TRASH_URI)
        return g_openLocations.contains("trash://") || g_openLocations.contains("trash:");

    return false;
}

void activate(const std::string& uri) {
    if (uri.empty())
        return;

    // The URI is one argv element, never a word in a command line: a volume
    // label is user data and lands in this string.
    spawn("xdg-open", {uri});
}

void emptyTrash() {
    sd_bus* bus = userBus();
    if (!bus)
        return;

    sd_bus_error    error = SD_BUS_ERROR_NULL;
    sd_bus_message* msg   = nullptr;

    // ask_confirmation TRUE, exactly as `launchAction` passes it. The dialog is
    // Nautilus's, and it is the only thing between a stray click and the user's
    // files -- which is also why this asks Nautilus rather than emptying the
    // trash directory itself.
    if (sd_bus_message_new_method_call(bus, &msg, "org.gnome.Nautilus", "/org/gnome/Nautilus/FileOperations2", "org.gnome.Nautilus.FileOperations2", "EmptyTrash") >= 0 && msg) {
        sd_bus_message_append(msg, "b", 1);
        sd_bus_message_open_container(msg, 'a', "{sv}"); // platform_data: no parent handle to give
        sd_bus_message_close_container(msg);

        // Not bounded the way the poll is: this one is a USER ACTION, it may
        // legitimately have to start Nautilus, and it happens on a click rather
        // than once a second. Emptying the trash is worth a frame.
        sd_bus_call(bus, msg, 0, &error, nullptr);
        sd_bus_message_unref(msg);
    }

    sd_bus_error_free(&error);
}

void unmount(const std::string& uri, bool eject) {
    if (uri.empty())
        return;

    // `gio` is glib's own CLI and glib is already a hard dependency of this
    // build. It carries the polkit prompt and the "device is busy" reporting
    // that a raw umount(2) from in here would not.
    spawn("gio", {"mount", eject ? "-e" : "-u", uri});
}

}
