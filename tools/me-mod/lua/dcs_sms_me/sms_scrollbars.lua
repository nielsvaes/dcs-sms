-- sms_scrollbars.lua — shared themed scrollbar skinning for ME-mod tool windows.
--
-- The vanilla ME "Unit List" panel uses a thin, dark scrollbar skin that the
-- DCS-SMS tool windows want to match: the grid's thin dark vertical bar, plus a
-- horizontal bar refined to 15px tall with a dark 9-slice track, visible arrow
-- images, and a polzunok thumb that brightens on hover. This module is the one
-- home for that recipe; previously it was hand-built inline and duplicated
-- across me_hotkey_script_editor.lua, prefab_manager.lua, and sms_skins.lua.
--
-- Skin gotchas (all guarded so a future DCS build degrades instead of crashing):
--   * Skin.gridSkin_Multiplayer_roleNew() / editBoxSkin_ME() return a FRESH deep
--     copy per call, so mutating the returned table is widget-local — safe.
--   * Colours MUST be string form '0xRRGGBBAA'; numeric assignments silently
--     fail to parse.
--   * Everything is pcall-guarded.

local Skin; do local ok, m = pcall(require, 'Skin'); if ok then Skin = m end end

local M = {}

local FONT_MONO = 'DejaVuLGCSansMono.ttf'

-- Directory holding the horizontal scrollbar images (arrows + polzunok thumb).
local HZ = 'dxgui\\skins\\skinme\\images\\buttons\\scroll\\horz\\'

local HZ_TRACK_SLICES = {
    'left_top',    'center_top',    'right_top',
    'left_center', 'center_center', 'right_center',
    'left_bottom', 'center_bottom', 'right_bottom',
}

-- Apply the vanilla ME Unit List horizontal-bar refinement to a horzScrollBar
-- sub-skin (sourced from gridSkin_Multiplayer_roleNew). Replicates the override
-- in MissionEditor/modules/dialogs/me_units_list_panel.dlg:
--   * 15px tall (maxSize/minSize.vert) → thin, not the stock thick bar
--   * whole 9-slice track recoloured 0x363636ff to match the vertical bar (a
--     center-only recolour leaves the lighter edges as an outline the vert lacks)
--   * visible released arrow images (the grid's own only render on hover)
--   * polzunok thumb across released/hover/pressed so it brightens on hover
-- Mutates hz in place. Guarded so a different skin shape degrades quietly.
local function refine_horz_bar(hz)
    if not (hz and hz.skinData) then return end
    pcall(function()
        local sd = hz.skinData
        sd.params = sd.params or {}
        sd.params.maxSize = { vert = 15 }
        sd.params.minSize = { vert = 15 }
        -- Darken the WHOLE 9-slice track (not just center) — the grid horz bar
        -- is uniformly light, so a center-only recolour leaves the lighter
        -- edges as an outline the vertical bar lacks.
        local relbar = sd.states and sd.states.released and sd.states.released[1]
        if relbar and relbar.bkg then
            for _, k in ipairs(HZ_TRACK_SLICES) do
                relbar.bkg[k] = '0x363636ff'
            end
        end
        local function set_pic(btn, fname)
            local r = btn and btn.skinData and btn.skinData.states
                      and btn.skinData.states.released and btn.skinData.states.released[1]
            if r then r.picture = r.picture or {}; r.picture.file = HZ .. fname end
        end
        local sk = sd.skins or {}
        set_pic(sk.decreaseButton, 'down_normal.png')   -- left arrow
        set_pic(sk.increaseButton, 'up_normal.png')     -- right arrow
        -- Skin the thumb across ALL states with the polzunok image set so hover
        -- brightens (like the vertical bar) instead of the grid's faded
        -- horzscroll hover image.
        local function set_thumb(state, fname)
            local r = sk.thumb and sk.thumb.skinData and sk.thumb.skinData.states
                      and sk.thumb.skinData.states[state] and sk.thumb.skinData.states[state][1]
            if r then r.bkg = r.bkg or {}; r.bkg.file = HZ .. fname end
        end
        set_thumb('released', 'polzunok_normal.png')
        set_thumb('hover',    'polzunok_hover.png')
        set_thumb('pressed',  'polzunok_pressed.png')
    end)
end

-- Inject the themed grid scrollbars into a widget skin table.
--   skin : a skin table with skinData.skins (editbox / tree / scrollpane / grid)
--   opts.horizontal  (default true)  — also inject the horizontal bar
--   opts.refine_horz (default false) — apply the full Unit-List horz refinement
-- Always injects the grid's vertScrollBar. Mutates skin in place, returns it.
-- No-op (returns skin unchanged) if Skin or the required sub-tables are missing.
function M.apply(skin, opts)
    opts = opts or {}
    if not (skin and skin.skinData and skin.skinData.skins) then return skin end
    local horizontal = opts.horizontal ~= false
    pcall(function()
        local grid = Skin and Skin.gridSkin_Multiplayer_roleNew
                     and Skin.gridSkin_Multiplayer_roleNew()
        local gs = grid and grid.skinData and grid.skinData.skins
        if not gs then return end
        if gs.vertScrollBar then
            skin.skinData.skins.vertScrollBar = gs.vertScrollBar
        end
        if horizontal and gs.horzScrollBar then
            if opts.refine_horz then refine_horz_bar(gs.horzScrollBar) end
            skin.skinData.skins.horzScrollBar = gs.horzScrollBar
        end
    end)
    return skin
end

-- Convenience: a fresh editBoxSkin_ME() clone, themed and ready to setSkin.
--   opts.mono        (default false) — DejaVuLGCSansMono.ttf on every text state
--   opts.horizontal  (default true)  — forwarded to M.apply
--   opts.refine_horz (default true)  — forwarded to M.apply (editbox wants full)
-- Returns the themed skin, or nil if Skin/editBoxSkin_ME is unavailable.
function M.themed_editbox_skin(opts)
    opts = opts or {}
    if not (Skin and Skin.editBoxSkin_ME) then return nil end
    local s = Skin.editBoxSkin_ME()
    if not (s and s.skinData) then return nil end
    if opts.mono and s.skinData.states then
        pcall(function()
            for _, st in pairs(s.skinData.states) do
                if st[1] and st[1].text then st[1].text.font = FONT_MONO end
            end
        end)
    end
    local refine = opts.refine_horz
    if refine == nil then refine = true end
    M.apply(s, {
        horizontal  = opts.horizontal ~= false,
        refine_horz = refine,
    })
    return s
end

return M
