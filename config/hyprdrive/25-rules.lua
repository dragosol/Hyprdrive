-- hyprdrive fragment 25-rules -- window rules the house presentation needs.
--
-- MACHINE-OWNED above the raw-snippet marker; USER-OWNED below it. Everything
-- above BEGIN is rewritten wholesale when this fragment is regenerated;
-- everything between BEGIN and END is carried across verbatim.
--
-- These are rules for windows the plugin CAUSES but does not own. A preview
-- the dock opened is still an ordinary toplevel belonging to another process.
--
-- PLAIN hl.window_rule, not Omarchy's `o.window` helper. On plain Hyprland
-- there is no `o`, and `o.window(...)` was a Lua runtime error here: Hyprland's
-- require() catches it, but the loader then never reached 30-keybinds.lua, so a
-- vanilla install lost the overview submap and the 3-finger gestures
-- (measured headless on 0.56.2). o.window is only a wrapper that moves its
-- first table into `match` and calls hl.window_rule, so this is the same rule.

-- GNOME Sushi / Nautilus Previewer -- SPACE over a dock stack item, and
-- Nautilus's own spacebar, both open this window. Float and centre it; leave
-- opacity and blur to the desktop's own window rules so a preview is not the
-- one surface that ignores the theme.
hl.window_rule({
    match = { class = [[^(org\.gnome\.NautilusPreviewer)$]] },
    float = true,
    center = true,
})

-- OMARCHY ONLY. Restate default-opacity after plugin load so mapped windows
-- keep a rule. Values match Omarchy's ~/.config/hypr/windows.lua (0.985
-- focused / 0.85 unfocused); apps that opt out (`-default-opacity`) are
-- untouched. The `default-opacity` tag is Omarchy's, so on any other desktop
-- this rule would match nothing -- it is skipped there rather than left as a
-- rule about a tag nobody sets. Still written through `o.window` when Omarchy's
-- helper is there, exactly as before.
if hyprdrive_omarchy and hyprdrive_omarchy() then
    local rule = { opacity = "0.985 override 0.85 override" }
    if type(o) == "table" and type(o.window) == "function" then
        o.window({ tag = "default-opacity" }, rule)
    else
        rule.match = { tag = "default-opacity" }
        hl.window_rule(rule)
    end
end
