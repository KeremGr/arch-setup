-- arch-setup: personal Hyprland overrides (loaded last by Caelestia's config).
-- Edit freely; `hyprctl reload` applies changes.

-- Monitors: any screen gets its native resolution, placed left to right.
-- First login replaces this block with each detected monitor at its native resolution + highest refresh rate.
-- BEGIN arch-setup monitors
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })
-- END arch-setup monitors

-- BEGIN arch-setup nvidia (removed on machines without an NVIDIA-only GPU)
hl.env("LIBVA_DRIVER_NAME", "nvidia")
hl.env("__GLX_VENDOR_LIBRARY_NAME", "nvidia")
hl.env("NVD_BACKEND", "direct")
hl.env("__GL_GSYNC_ALLOWED", "1")   -- let games use G-Sync/FreeSync
hl.env("__GL_VRR_ALLOWED", "1")
-- END arch-setup nvidia

hl.config({
    input = {
        kb_layout  = "@XKB_LAYOUT@",    -- chosen during install
        kb_variant = "@XKB_VARIANT@",
    },
    misc = {
        vrr = 2,            -- adaptive sync for fullscreen apps only (no desktop flicker)
    },
    general = {
        allow_tearing = true,          -- only windows tagged "game" (immediate) may tear: lowest input lag
    },
    render = {
        direct_scanout        = 2,     -- fullscreen games skip the compositor (auto, games only)
        new_render_scheduling = true,  -- triple-buffer when a frame is late instead of halving FPS
    },
})

-- Music & chat apps open as normal tiled windows on the current workspace
-- (Caelestia puts them on special workspaces, which cover everything else).
for _, tag in ipairs({ "music_player", "communication_app" }) do
    hl.window_rule({ match = { tag = tag }, workspace = "unset" })
end
