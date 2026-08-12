-- hyprdrive fragment 00-plugin -- load the plugin, and the guard every later
-- fragment uses.
--
-- MACHINE-OWNED above the raw-snippet marker; USER-OWNED below it. Everything
-- above BEGIN is rewritten wholesale when this fragment is regenerated (by the
-- settings app, or by `scripts/fragment.py write`); everything between BEGIN
-- and END is carried across verbatim. Put hand edits THERE, not here.
--
-- Fragments load in filename order, so the numeric prefix is the load order.
-- This one is 00 because nothing else can run until the .so has registered its
-- config keys.

-- hl.plugin.load is PARSE-TIME only: this line is what makes the plugin survive
-- a reboot, and it is a no-op on `hyprctl reload`. Manual equivalent:
--   hyprctl plugin load ~/overview-cpp/hyprdrive.so
hl.plugin.load(HOME .. "/overview-cpp/hyprdrive.so")

-- hl.config runs at parse time and the plugin:hyprdrive:* keys do not exist
-- until the .so has registered them, so an unguarded config block throws
-- "unknown config key" for every property on boot and on reload.
function hyprdrive_loaded()
    -- entries are tables: {name, author, version, description}
    for _, v in ipairs(hl.get_loaded_plugins() or {}) do
        if (type(v) == "table" and v.name or v) == "hyprdrive" then
            return true
        end
    end
    return false
end
