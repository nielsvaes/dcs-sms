-- Standalone test for sms_scrollbars (themed scrollbar skin injection).

package.path = '../?.lua;../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

-- Fake Skin module: returns freshly-built skin tables with the nested shape the
-- module mutates. Each builder returns a NEW table per call (mirrors the real
-- Skin module's fresh-deep-copy-per-call contract).
local function fresh_grid()
    return {
        skinData = {
            skins = {
                vertScrollBar = { __id = 'grid_vert' },
                horzScrollBar = {
                    __id = 'grid_horz',
                    skinData = {
                        states = {
                            released = { [1] = { bkg = {
                                left_top='x', center_top='x', right_top='x',
                                left_center='x', center_center='x', right_center='x',
                                left_bottom='x', center_bottom='x', right_bottom='x',
                            } } },
                        },
                        skins = {
                            decreaseButton = { skinData = { states = { released = { [1] = {} } } } },
                            increaseButton = { skinData = { states = { released = { [1] = {} } } } },
                            thumb = { skinData = { states = {
                                released = { [1] = { bkg = {} } },
                                hover    = { [1] = { bkg = {} } },
                                pressed  = { [1] = { bkg = {} } },
                            } } },
                        },
                    },
                },
            },
        },
    }
end

local function fresh_editbox()
    return {
        skinData = {
            states = {
                released = { [1] = { text = { font = 'default.ttf' } } },
                hover    = { [1] = { text = { font = 'default.ttf' } } },
            },
            skins = {},
        },
    }
end

package.preload['Skin'] = function()
    return {
        gridSkin_Multiplayer_roleNew = fresh_grid,
        editBoxSkin_ME = fresh_editbox,
    }
end

local sms_scrollbars = require('dcs_sms_me.sms_scrollbars')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

local function target()
    return { skinData = { skins = {} } }
end

-- Case 1: vertScrollBar injected.
do
    local t = target()
    sms_scrollbars.apply(t)
    check('apply injects vertScrollBar', t.skinData.skins.vertScrollBar ~= nil)
end

-- Case 2: horizontal default true injects horzScrollBar.
do
    local t = target()
    sms_scrollbars.apply(t)
    check('apply injects horzScrollBar by default', t.skinData.skins.horzScrollBar ~= nil)
end

-- Case 3: horizontal=false skips horzScrollBar.
do
    local t = target()
    sms_scrollbars.apply(t, { horizontal = false })
    check('horizontal=false: vert injected', t.skinData.skins.vertScrollBar ~= nil)
    check('horizontal=false: horz NOT injected', t.skinData.skins.horzScrollBar == nil)
end

-- Case 4: refine_horz default false leaves grid horz unrefined.
do
    local t = target()
    sms_scrollbars.apply(t)
    local hz = t.skinData.skins.horzScrollBar
    check('default refine_horz=false: no 15px maxSize',
          hz and hz.skinData and (hz.skinData.params == nil or hz.skinData.params.maxSize == nil))
end

-- Case 5: refine_horz=true applies the full Unit-List treatment.
do
    local t = target()
    sms_scrollbars.apply(t, { refine_horz = true })
    local hz = t.skinData.skins.horzScrollBar
    local sd = hz and hz.skinData
    check('refine: 15px maxSize', sd and sd.params and sd.params.maxSize and sd.params.maxSize.vert == 15)
    check('refine: 15px minSize', sd and sd.params and sd.params.minSize and sd.params.minSize.vert == 15)
    local relbkg = sd and sd.states and sd.states.released and sd.states.released[1]
                   and sd.states.released[1].bkg
    local all_dark = relbkg ~= nil
    for _, k in ipairs({'left_top','center_top','right_top','left_center','center_center',
                        'right_center','left_bottom','center_bottom','right_bottom'}) do
        if not relbkg or relbkg[k] ~= '0x363636ff' then all_dark = false end
    end
    check('refine: all 9 track slices 0x363636ff', all_dark)
    local sk = sd and sd.skins
    check('refine: left arrow picture set',
          sk and sk.decreaseButton.skinData.states.released[1].picture
          and sk.decreaseButton.skinData.states.released[1].picture.file:find('down_normal.png') ~= nil)
    check('refine: right arrow picture set',
          sk and sk.increaseButton.skinData.states.released[1].picture
          and sk.increaseButton.skinData.states.released[1].picture.file:find('up_normal.png') ~= nil)
    local th = sk and sk.thumb.skinData.states
    check('refine: thumb released image',
          th and th.released[1].bkg.file and th.released[1].bkg.file:find('polzunok_normal.png') ~= nil)
    check('refine: thumb hover image',
          th and th.hover[1].bkg.file and th.hover[1].bkg.file:find('polzunok_hover.png') ~= nil)
    check('refine: thumb pressed image',
          th and th.pressed[1].bkg.file and th.pressed[1].bkg.file:find('polzunok_pressed.png') ~= nil)
end

-- Case 6: themed_editbox_skin({mono=true}) sets mono font + refined horz + vert.
do
    local s = sms_scrollbars.themed_editbox_skin({ mono = true })
    check('editbox skin returned', s ~= nil)
    local font_ok = s and s.skinData and s.skinData.states
        and s.skinData.states.released[1].text.font == 'DejaVuLGCSansMono.ttf'
        and s.skinData.states.hover[1].text.font == 'DejaVuLGCSansMono.ttf'
    check('editbox mono font on text states', font_ok)
    local hz = s and s.skinData and s.skinData.skins and s.skinData.skins.horzScrollBar
    check('editbox has refined horz (15px)',
          hz and hz.skinData and hz.skinData.params and hz.skinData.params.maxSize
          and hz.skinData.params.maxSize.vert == 15)
    check('editbox has vertScrollBar', s and s.skinData.skins.vertScrollBar ~= nil)
end

-- Case 7: graceful on odd input.
do
    local ok1 = pcall(sms_scrollbars.apply, nil)
    check('apply(nil) does not throw', ok1)
    local ok2 = pcall(sms_scrollbars.apply, { skinData = {} })
    check('apply(skin without skins) does not throw', ok2)
end

-- Case 8: the refactored call-site files still parse (syntax gate for the
-- refactor tasks; loadfile compiles without running their requires).
do
    for _, rel in ipairs({
        '../lua/dcs_sms_me/sms_scrollbars.lua',
        '../lua/dcs_sms_me/me_hotkey_script_editor.lua',
        '../lua/dcs_sms_me/prefab_manager.lua',
        '../lua/dcs_sms_me/dtc_skins.lua',
    }) do
        local fn, err = loadfile(rel)
        check('parses: ' .. rel, fn ~= nil, err)
    end
end

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All sms_scrollbars tests passed.')
