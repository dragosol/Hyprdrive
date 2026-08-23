-- hyprdrive fragment 25-rules -- window rules the house presentation needs.
--
-- MACHINE-OWNED above the raw-snippet marker; USER-OWNED below it. Everything
-- above BEGIN is rewritten wholesale when this fragment is regenerated;
-- everything between BEGIN and END is carried across verbatim.
--
-- 25, so it lands after the theme and layout values and BEFORE the settings
-- app's own panes (40+) -- a pane that later wants to override one of these
-- can, and this file will not fight it.
--
-- These are rules for windows the plugin CAUSES but does not own. A preview
-- the dock opened is still an ordinary toplevel belonging to another process,
-- and left alone it maps wherever the compositor puts it, opaque, with the
-- frost the rest of this desktop has. Dressing it is a config act, not a
-- plugin act, which is why it is here and not in C++.

-- V11 SPEC V5. GNOME-SUSHI, the previewer SPACE opens -- from a dock stack's
-- fan or grid, and from Nautilus's own spacebar, which calls the same service.
-- The window reports class `org.gnome.NautilusPreviewer` (measured with
-- hyprctl clients while a preview was up; the binary is
-- /usr/libexec/org.gnome.NautilusPreviewer, and on Fedora the package that
-- ships it is called `sushi`: `dnf install gnome-sushi` resolves nothing there,
-- and nothing provides that name either.)
--
-- FLOAT and CENTRE: a preview is a glance at one file, not a window to manage.
-- Sushi sizes itself to its content, so no size rule -- a rule here would make
-- every preview the same shape regardless of what it is previewing.
local SUSHI = [[^(org\.gnome\.NautilusPreviewer)$]]

hl.window_rule({match = {class = SUSHI}, float  = true})
hl.window_rule({match = {class = SUSHI}, center = true})

-- FROST. User law: on by default, on every surface, and an OPAQUE app defeats
-- compositor blur outright -- there is nothing to blur BEHIND a window that
-- covers what is behind it. So the frost is two rules, not one: blur allowed,
-- and an opacity for it to show through. 0.92/0.92 is the value this rice
-- already gives every window (custom/rules.lua reads it from
-- custom/blur.json); a preview is not the place to be the one exception, and
-- active and inactive are equal because a preview that dimmed when you looked
-- away from it would dim exactly when you are looking at it.
hl.window_rule({match = {class = SUSHI}, no_blur = false})
hl.window_rule({match = {class = SUSHI}, opacity = "0.92 0.92"})

-- BEGIN raw-snippet (hand edits below survive regeneration)
-- END raw-snippet
