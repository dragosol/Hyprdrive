-- hyprdrive fragment 00-plugin -- load the plugin, and the guards every later
-- fragment uses: hyprdrive_loaded() and hyprdrive_integration()/hyprdrive_omarchy().
--
-- MACHINE-OWNED above the raw-snippet marker; USER-OWNED below it. Everything
-- above BEGIN is rewritten wholesale when this fragment is regenerated;
-- everything between BEGIN and END is carried across verbatim. Put hand edits
-- THERE, not here.

local function file_exists(path)
    local f = io.open(path, "r")
    if f then
        f:close()
        return true
    end
    return false
end

local home = os.getenv("HOME") or ""

-- WHICH .so, first hit wins:
--   1. $HYPRDRIVE_SO                         a dev build, a test
--   2. <PREFIX>/lib/hyprdrive/hyprdrive.so   where `make install PREFIX=...` put it
--                                            (substituted at install time)
--   3. ~/.local/lib/hyprdrive/hyprdrive.so   the default PREFIX, and every install
--                                            made before PREFIX was honoured here
--   4. /var/cache/hyprpm/$USER/Hyprdrive/hyprdrive.so   a hyprpm install. hyprpm
--      loads it itself on `hyprpm reload`; loading it here as well only makes the
--      overview's binds below exist on the first parse. hyprpm skips a plugin
--      that is already loaded, so the two do not double-load.
local prefix = [==[@HYPRDRIVE_PREFIX@]==]
local candidates = {}
local so = os.getenv("HYPRDRIVE_SO")
if so and so ~= "" then
    candidates[#candidates + 1] = so
end
if prefix ~= "" and not prefix:find("^@") then
    candidates[#candidates + 1] = prefix .. "/lib/hyprdrive/hyprdrive.so"
end
candidates[#candidates + 1] = home .. "/.local/lib/hyprdrive/hyprdrive.so"
candidates[#candidates + 1] = "/var/cache/hyprpm/" .. (os.getenv("USER") or "") .. "/Hyprdrive/hyprdrive.so"

so = nil
for _, path in pairs(candidates) do
    if file_exists(path) then
        so = path
        break
    end
end

-- hl.plugin.load is PARSE-TIME only: this line is what makes the plugin survive
-- a reboot, and it is a no-op on `hyprctl reload`. Manual equivalent:
--   hyprctl plugin load ~/.local/lib/hyprdrive/hyprdrive.so
if so then
    hl.plugin.load(so)
end

-- hl.config runs at parse time and the plugin:hyprdrive:* keys do not exist
-- until the .so has registered them, so an unguarded config block throws
-- "unknown config key" for every property on boot and on reload.
-- pairs() not ipairs(): omarchy-menu-keybindings scans this file with a stub
-- `hl` whose __index always returns a value, and ipairs never terminates on
-- that table. Super+K (the keybindings menu) hung in this loop.
function hyprdrive_loaded()
    local ok, plugins = pcall(function()
        return hl.get_loaded_plugins()
    end)
    if not ok or type(plugins) ~= "table" then
        return false
    end
    for _, v in pairs(plugins) do
        if (type(v) == "table" and v.name or v) == "hyprdrive" then
            return true
        end
    end
    return false
end

-- "omarchy" | "none" -- Integration.hpp's answer, for fragments: is this an
-- Omarchy desktop? The plugin's hl.plugin.hyprdrive.integration() when it is
-- loaded (it also sees plugin:hyprdrive:integration); otherwise the same rule
-- here, minus the config key (which cannot exist without the plugin):
--   HYPRDRIVE_NO_OMARCHY=1 -> none; HYPRDRIVE_INTEGRATION=omarchy|none -> that;
--   else omarchy only if an `omarchy` file is on PATH AND the omarchy state dir
--   exists. (Lua cannot test the exec bit without spawning, and Hyprland reaps
--   its own children, so "on PATH" here is "a readable file named omarchy".)
-- The type checks are for Omarchy's keybinding scanner, whose stub `hl`
-- answers every lookup with a table.
function hyprdrive_integration()
    local ok, name = pcall(function()
        return hl.plugin.hyprdrive.integration()
    end)
    if ok and (name == "omarchy" or name == "none") then
        return name
    end

    if os.getenv("HYPRDRIVE_NO_OMARCHY") == "1" then
        return "none"
    end
    local forced = os.getenv("HYPRDRIVE_INTEGRATION")
    if forced == "omarchy" or forced == "none" then
        return forced
    end

    local on_path = false
    for dir in string.gmatch(os.getenv("PATH") or "", "[^:]+") do
        if file_exists(dir .. "/omarchy") then
            on_path = true
            break
        end
    end
    local state = os.getenv("XDG_STATE_HOME")
    if not state or state == "" then
        state = home .. "/.local/state"
    end
    -- io.open on a directory succeeds on Linux, so this is "exists".
    return (on_path and file_exists(state .. "/omarchy/current")) and "omarchy" or "none"
end

function hyprdrive_omarchy()
    return hyprdrive_integration() == "omarchy"
end
