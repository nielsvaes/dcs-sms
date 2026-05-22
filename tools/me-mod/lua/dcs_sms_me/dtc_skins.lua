-- dtc_skins.lua — DTC-style skin builders.
--
-- The DTC editor dialog (modules/dialogs/me_DTCnew.dlg) uses a different
-- skin set than the rest of the dxgui Skin module:
--
--   * Buttons:   inline override of toggleButtonSkin_ME with btnmean2.png
--                (small dark-blue rectangular buttons — the ADD/EDIT look).
--                Not registered in skin_names.lua, so we clone the base
--                skin at runtime and swap each `bkg.file` reference.
--   * Grid:      gridSkin_Multiplayer_roleNew  + selectionColor 0x2da1beff
--                (registered in skin_names.lua → grid4mulnew.skin.lua).
--   * Headers:   gridHeaderCellSkinNew (registered → grid_header_cell5snew).
--
-- All builders return a freshly cloned skin table so callers can mutate
-- without affecting the cached Skin module copy.

local Skin;  do local ok, m = pcall(require, 'Skin'); if ok then Skin = m end end

local M = {}

-- Recursively swap any `["file"] = "...btn_ME_all_*.png"` reference inside
-- the cloned toggleButtonSkin_ME for the DTC btnmean2 image. Same image is
-- used across all states; per-state color modulation in the base skin
-- (released = full alpha, hover = brighter, pressed = dimmer, etc.) is
-- preserved automatically.
local DTC_BTN_IMAGE = 'dxgui\\skins\\skinme\\images\\m1\\buttons\\btnmini\\btnmean2.png'

local function swap_btn_image(node)
    if type(node) ~= 'table' then return end
    for k, v in pairs(node) do
        if k == 'file' and type(v) == 'string' and v:find('btn_ME_all') then
            node[k] = DTC_BTN_IMAGE
        elseif type(v) == 'table' then
            swap_btn_image(v)
        end
    end
end

function M.button()
    local s = Skin.toggleButtonSkin_ME and Skin.toggleButtonSkin_ME() or nil
    if not s then return nil end
    if s.skinData and s.skinData.states then
        swap_btn_image(s.skinData.states)
    end
    return s
end

-- Tinted button variants for tri-state buttons (tri_state_button.lua).
-- Builds on M.button() and overrides the label color in every state so the
-- text reads green / red across hover / pressed / released alike. Bkg image
-- stays the same (btnmean2) — only the label tint changes.
local function button_colored(hex)
    local s = M.button()
    if not (s and s.skinData and s.skinData.states) then return s end
    for _, state_name in pairs({'released', 'hover', 'pressed', 'disabled', 'checked'}) do
        local st = s.skinData.states[state_name]
        if type(st) == 'table' then
            for _, layer in pairs(st) do
                if type(layer) == 'table' and type(layer.text) == 'table' then
                    layer.text.color = hex
                end
            end
        end
    end
    return s
end

function M.button_on()  return button_colored('0x44dd44ff') end  -- green
function M.button_off() return button_colored('0xff5555ff') end  -- red

-- Translucent button variant: clones M.button() and scales every
-- 0xRRGGBBAA hex color in the skin tree by an alpha multiplier (default
-- 0.75 = 75% opacity). Used for inline clear-buttons (clearable_edit)
-- and other affordances that should sit visually softer than the
-- standard chunky dtc_button.
local function scale_hex_alpha(hex_str, factor)
    if type(hex_str) ~= 'string' or #hex_str ~= 10 then return hex_str end
    if not hex_str:match('^0x%x+$') then return hex_str end
    local rgb       = hex_str:sub(1, 8)
    local alpha_hex = hex_str:sub(9, 10)
    local alpha = tonumber(alpha_hex, 16)
    if not alpha then return hex_str end
    local new_alpha = math.floor(alpha * factor + 0.5)
    if new_alpha > 255 then new_alpha = 255 end
    if new_alpha < 0   then new_alpha = 0   end
    return rgb .. string.format('%02x', new_alpha)
end

local function scale_all_alpha(node, factor, depth)
    if type(node) ~= 'table' or (depth or 0) > 10 then return end
    for k, v in pairs(node) do
        if type(v) == 'string' then
            node[k] = scale_hex_alpha(v, factor)
        elseif type(v) == 'table' then
            scale_all_alpha(v, factor, (depth or 0) + 1)
        end
    end
end

function M.button_translucent(opacity)
    local s = M.button()
    if not (s and s.skinData and s.skinData.states) then return s end
    scale_all_alpha(s.skinData.states, tonumber(opacity) or 0.75)
    return s
end

function M.grid()
    local s = Skin.gridSkin_Multiplayer_roleNew and Skin.gridSkin_Multiplayer_roleNew() or nil
    if not s then return nil end
    -- The DTC dialog overrides selectionColor inline. Copy that here so a
    -- selected row gets the teal-blue highlight rather than the default
    -- grayish 0x3c3e40.
    if s.skinData and s.skinData.params then
        s.skinData.params.selectionColor = '0x2da1beff'
    end
    return s
end

function M.grid_header()
    return Skin.gridHeaderCellSkinNew and Skin.gridHeaderCellSkinNew() or nil
end

-- ScrollPane skin that pairs the modern-blue pane background from
-- me_managerDTC.dlg's scrollPane_modul_noinserts with the thin "tools"
-- scrollbar definition that grid4mulnew.skin.lua (gridSkin_Multiplayer_-
-- roleNew) defines inline. The stock noinserts skin references
-- vertScrollBarSkinSV by name — that's the dark-gray legacy look that
-- visually clashes with the grid's lighter scrollbar.
--
-- We can't override one named skin from another with a stock name —
-- skin_names.lua doesn't ship a thin-scrollbar pane preset. So we
-- runtime-clone noinserts and inject the grid's vertScrollBar table.
function M.scroll_pane()
    local pane = Skin.scrollPane_modul_noinserts and Skin.scrollPane_modul_noinserts() or nil
    if not (pane and pane.skinData and pane.skinData.skins) then return pane end

    local grid = Skin.gridSkin_Multiplayer_roleNew and Skin.gridSkin_Multiplayer_roleNew() or nil
    if grid and grid.skinData and grid.skinData.skins and grid.skinData.skins.vertScrollBar then
        pane.skinData.skins.vertScrollBar = grid.skinData.skins.vertScrollBar
    end
    return pane
end

-- Icon-bearing Static skin: clone staticSkin and inject a 64x64 picture into
-- released[1] so a plain Static renders the ME's warning/question glyph.
-- Mirrors how msg_window.dlg's staticWarning / staticQuestion declare an
-- inline picture override on top of the staticSkin base.
local ICON_PATHS = {
    warning  = 'dxgui\\skins\\skinME\\images\\mission_editor\\static_ME_Warning.png',
    question = 'dxgui\\skins\\skinME\\images\\mission_editor\\static_ME_Question.png',
}

-- Coloured-text variant of staticSkin_ME for the status bar. Clones
-- staticSkin_ME and overrides released[1].text.color — dxgui Static has no
-- setColor API, so a per-severity skin swap is the cleanest way to flip
-- the foreground color at runtime.
local function static_colored(hex)
    local s = Skin.staticSkin_ME and Skin.staticSkin_ME() or nil
    if not (s and s.skinData and s.skinData.states) then return nil end
    local rel = s.skinData.states.released
    if rel and rel[1] and rel[1].text then
        rel[1].text.color = hex
    end
    return s
end

function M.static_yellow() return static_colored('0xffd700ff') end  -- warning
function M.static_red()    return static_colored('0xff5555ff') end  -- error (softened from pure red)
function M.static_green()  return static_colored('0x44dd44ff') end  -- placement / success

-- Coalition-tinted Static variants. Render the cell's text in the
-- coalition color so the group treeview's Country column visually echoes
-- the colored marker the country ComboList already shows on its
-- ListBoxItem entries. Hex values match the existing dtc palette where
-- possible (red = static_red's hex; neutral = static_yellow's hex).
function M.coal_red()     return static_colored('0xff5555ff') end
function M.coal_blue()    return static_colored('0x5599ffff') end
function M.coal_neutral() return static_colored('0xffd700ff') end

-- Thin horizontal-rule skin for sectioning the prefab manager. dxgui has
-- no native separator widget, so we override a Static's released-state bkg
-- with a darker tone — when the Static is sized 1px tall and stretched
-- across the row it renders as a divider line. Subtle on top of the
-- windowSkinME panel background.
function M.separator()
    return {
        skinData = {
            states = {
                released = {
                    [1] = {
                        bkg = {
                            center_center = '0x00000060',
                            file          = '',
                            insets = { bottom = 0, left = 0, right = 0, top = 0 },
                        },
                    },
                },
            },
            type = 'Static',
        },
        version = 1,
    }
end

-- Vertical drag-handle skin for the mass_edit pane splitter. Same
-- structure as separator(), but a lighter neutral color so the user
-- sees a visible grab bar between the panes (dxgui has no setCursor
-- API so we can't show a horizontal-resize cursor on hover — the
-- visible bar IS the affordance).
function M.splitter()
    return {
        skinData = {
            states = {
                released = {
                    [1] = {
                        bkg = {
                            center_center = '0x6c6e70ff',
                            file          = '',
                            insets = { bottom = 0, left = 0, right = 0, top = 0 },
                        },
                    },
                },
            },
            type = 'Static',
        },
        version = 1,
    }
end

-- ToggleButton skin for the Mass Edit window's scope tab strip
-- (Group/Unit/Waypoint/Zone/Drawing). Inactive tabs render as text only
-- against the panel background (no chrome). Active tabs fill with the same
-- teal as the grid's row selection color (0x2da1beff) so the tab strip
-- visually rhymes with selection elsewhere in the window. Hover state is
-- low-alpha teal so mouse-over offers a subtle preview without competing
-- with the active state.
function M.tab()
    local TEXT_FONT  = 'DejaVuLGCSansCondensed-Bold.ttf'
    local TEXT_SIZE  = 12
    local INSETS     = { bottom = 0, left = 0, right = 0, top = 0 }
    local function text_layer(color)
        return {
            blur          = 0,
            color         = color,
            font          = TEXT_FONT,
            fontSize      = TEXT_SIZE,
            horzAlign     = { type = 'middle' },
            vertAlign     = { type = 'middle' },
            shadowOffset  = { horz = 0, vert = 0 },
        }
    end
    return {
        skinData = {
            type   = 'ToggleButton',
            states = {
                released = {
                    [1] = {
                        bkg  = {},
                        text = text_layer('0x9faab2ff'),
                    },
                },
                hover = {
                    [1] = {
                        bkg = {
                            center_center = '0x2da1be40',
                            file          = '',
                            insets        = INSETS,
                        },
                        text = text_layer('0xeeeeeeff'),
                    },
                },
                pressed = {
                    [1] = {
                        bkg = {
                            center_center = '0x2da1beff',
                            file          = '',
                            insets        = INSETS,
                        },
                        text = text_layer('0xffffffff'),
                    },
                },
            },
        },
        version = 1,
    }
end

-- ME's static-panel dial visual: clone dialSkin_ME and swap the picture
-- file in both released + disabled states to the m1/elements version, with
-- middle-alignment (not stretch). me_static_panel.dlg's d_heading does this
-- inline; we replicate it programmatically since dxgui only exposes the
-- raw "stretchy/gray" dialSkin_ME via the named-skin API.
local DIAL_PIC_FILE = 'dxgui\\skins\\skinme\\images\\m1\\elements\\dial_me.png'

function M.dial()
    local s = Skin.dialSkin_ME and Skin.dialSkin_ME() or nil
    if not (s and s.skinData and s.skinData.states) then return nil end
    local function patch(state)
        if type(state) ~= 'table' or type(state[1]) ~= 'table' then return end
        local p = state[1].picture or {}
        p.file      = DIAL_PIC_FILE
        p.horzAlign = { type = 'middle', offset = 0 }
        p.vertAlign = { type = 'middle', offset = 0 }
        state[1].picture = p
    end
    patch(s.skinData.states.released)
    patch(s.skinData.states.disabled)
    return s
end

function M.icon_static(kind)
    local file = ICON_PATHS[kind]
    if not file then return nil end
    local s = Skin.staticSkin and Skin.staticSkin() or nil
    if not (s and s.skinData and s.skinData.states) then return nil end
    -- rect={0,0,0,0} + size={0,0} = "render at the texture's natural size",
    -- the same idiom msg_window.dlg's staticWarning/staticQuestion use. The
    -- ME PNGs are 49x41 / 42x42, not 64x64, so an explicit 64 source rect
    -- reads off the texture edge and tiles/wraps.
    s.skinData.states.released = s.skinData.states.released or {}
    s.skinData.states.released[1] = s.skinData.states.released[1] or {}
    s.skinData.states.released[1].picture = {
        color     = '0xffffffff',
        file      = file,
        horzAlign = { type = 'middle', offset = 0 },
        vertAlign = { type = 'middle', offset = 0 },
        rect      = { x1 = 0, x2 = 0, y1 = 0, y2 = 0 },
        size      = { horz = 0, vert = 0 },
    }
    return s
end

return M
