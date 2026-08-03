-- Dedicated VM regression configuration.  No physical monitor/device, ASUS,
-- personal-service, proxy, Bluetooth, storage, or boot behavior is embedded.

hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })

hl.config({
    general = {
        gaps_in = 5,
        gaps_out = 12,
        border_size = 2,
        layout = "dwindle",
    },
    decoration = {
        rounding = 8,
    },
    input = {
        kb_layout = "us",
        follow_mouse = 1,
        repeat_delay = 250,
        repeat_rate = 40,
        touchpad = {
            tap_to_click = true,
            natural_scroll = true,
        },
    },
    misc = {
        disable_hyprland_logo = true,
        disable_splash_rendering = true,
    },
})

hl.bind("SUPER + Return", hl.dsp.exec_cmd("kitty"))
hl.bind("SUPER + D", hl.dsp.exec_cmd("fuzzel"))
hl.bind("SUPER + Q", hl.dsp.window.close(), { repeating = false })
hl.bind("SUPER + SHIFT + E", hl.dsp.exit())
for i = 1, 5 do
    hl.bind("SUPER + " .. i, hl.dsp.focus({ workspace = i }))
    hl.bind("SUPER + SHIFT + " .. i, hl.dsp.window.move({ workspace = i }))
end

-- Plain Hyprland does not activate graphical-session.target.  Start DMS and
-- Fcitx5 once with self-match-safe guards; Niri uses package/systemd XDG owners.
hl.on("hyprland.start", function()
    hl.exec_cmd("pgrep -f '[q]s -p /usr/share/quickshell/dms' >/dev/null || dms run -d")
    hl.exec_cmd("pgrep -x fcitx5 >/dev/null || fcitx5 -d")
end)

hl.env("XCURSOR_SIZE", "24")
hl.env("HYPRCURSOR_SIZE", "24")
