-- Regression test for the Paint Statics erase/undo stale-group guard.
--
-- Bug: painting statics, flying + exiting a mission (or File>New/Open), then
-- erasing (or undoing the paint) HARD-CRASHED DCS. The ME rebuilds every
-- mission table on reload, orphaning the group references the tool stored at
-- paint time; batch_remove_groups then called the C++ remove_group_map_objects
-- on a stale group whose map objects were freed → native fault pcall can't
-- catch. The fix: group_is_live() detects staleness in pure Lua (the running
-- mission must still index THIS exact table by name) and the removal path skips
-- stale groups entirely. This test covers that predicate.
--
-- paint_statics is heavily dxgui-coupled; the dxgui modules are pcall-guarded
-- so they degrade to nil, and we stub the bare-required dcs_sms_me siblings so
-- the module loads headless. We then exercise M._group_is_live directly.

package.path = '../?.lua;../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

-- Stub the bare-required sibling modules (paint_statics only stores references
-- at load; the functions are exercised in the live ME, not here). A catch-all
-- metatable answers any field with a no-op function.
local function stub_table()
    return setmetatable({}, { __index = function() return function() end end })
end
for _, name in ipairs({ 'sms_window', 'sms_slider', 'paint_scatter',
                        'static_catalog', 'prefab_ops' }) do
    package.preload['dcs_sms_me.' .. name] = function() return stub_table() end
end

-- verb_helpers.walk_groups drives the registry rebuild — give it a real walk
-- over a test-settable coalition tree (mirrors H.walk_groups' shape: it calls
-- cb(g, country, side_name, cat) for every group and stops if cb returns false).
local vh_tree = nil
package.preload['dcs_sms_me.verb_helpers'] = function()
    return setmetatable({
        walk_groups = function(cb)
            if type(vh_tree) ~= 'table' then return end
            for side_name, side in pairs(vh_tree.coalition or {}) do
                if type(side.country) == 'table' then
                    for _, country in ipairs(side.country) do
                        for _, cat in ipairs({ 'plane', 'helicopter', 'vehicle', 'ship', 'static' }) do
                            if country[cat] and type(country[cat].group) == 'table' then
                                for _, g in ipairs(country[cat].group) do
                                    if cb(g, country, side_name, cat) == false then return end
                                end
                            end
                        end
                    end
                end
            end
        end,
    }, { __index = function() return function() end end })
end
package.preload['dcs_sms_me.version'] = function() return '0.0.0-test' end
package.preload['dcs_sms_me.undo'] = function()
    return { register_handler = function() end, record_generic = function() end }
end
-- log.* used by log_write (not called at load, but keep it safe).
_G.log = setmetatable({ INFO = 1, WARNING = 2, ERROR = 3 }, { __index = function() return 0 end })

local ps = require('dcs_sms_me.paint_statics')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

check('M._group_is_live is exported', type(ps._group_is_live) == 'function')

local live = ps._group_is_live

-- A live group: the running mission indexes THIS exact table by its name.
do
    local g = { name = 'Barrel-01', groupId = 7 }
    local Mission = { group_by_name = { ['Barrel-01'] = g } }
    check('live group (same table indexed by name)', live(Mission, g) == true)
end

-- Stale after reload: a DIFFERENT table now owns the name (the reloaded static).
do
    local g       = { name = 'Barrel-01', groupId = 7 }
    local reloaded = { name = 'Barrel-01', groupId = 99 }
    local Mission = { group_by_name = { ['Barrel-01'] = reloaded } }
    check('stale group (name now owned by a different table)', live(Mission, g) == false)
end

-- Stale after reload: the name is simply gone from the rebuilt mission.
do
    local g = { name = 'Barrel-01', groupId = 7 }
    local Mission = { group_by_name = {} }
    check('stale group (name absent after reload)', live(Mission, g) == false)
end

-- Defensive: no group_by_name table at all.
do
    local g = { name = 'Barrel-01' }
    check('no group_by_name table → not live', live({}, g) == false)
end

-- Defensive: nil group / nil Mission never throw and are not live.
do
    check('nil group → not live', live({ group_by_name = {} }, nil) == false)
    check('nil Mission → not live', live(nil, { name = 'x' }) == false)
end

-- ---------------------------------------------------------------------------
-- rebuild_registry_from_marked: rebuild the erase registry from the live
-- mission's marked statics (the cross-reload persistence mechanism).
-- ---------------------------------------------------------------------------
check('M._MARKER is the _sms token', ps._MARKER == '_sms')
check('M._rebuild_registry_from_marked is exported', type(ps._rebuild_registry_from_marked) == 'function')

do
    local MK = ps._MARKER
    -- Marked + unmarked statics across two countries, plus a marked NON-static
    -- (a plane) that must be ignored — only tool-painted statics count.
    local crate = { name = 'Crate-01' .. MK, x = 10, y = 20, heading = 0,
        units = { { type = 'iso_container', shape_name = 'iso_container_small',
                    category = 'Cargos', rate = 100, heading = math.rad(90), x = 10, y = 20 } } }
    local barrel = { name = 'Barrel-02' .. MK .. ' #2', x = 30, y = 40, heading = 0,
        units = { { type = 'Barrels', shape_name = 'GROUP_Barrels',
                    category = 'Fortifications', rate = 100, heading = 0, x = 30, y = 40 } } }
    local sam = { name = 'SAM-1', x = 50, y = 60,
        units = { { type = 'Hawk ln', shape_name = '', category = 'Air Defence', heading = 0 } } }
    local marked_plane = { name = 'Viper' .. MK, units = { { type = 'F-16C_50' } } }
    vh_tree = {
        coalition = {
            blue = { country = { { name = 'USA',
                static = { group = { crate, sam } },
                plane  = { group = { marked_plane } } } } },
            red  = { country = { { name = 'Russia',
                static = { group = { barrel } } } } },
        },
    }

    local reg = ps._rebuild_registry_from_marked()
    check('rebuild returns the registry', type(reg) == 'table')
    check('rebuild selected exactly the 2 marked statics', #reg == 2)

    local by_name = {}
    for _, e in ipairs(reg) do by_name[e.name] = e end
    check('marked crate selected', by_name['Crate-01' .. MK] ~= nil)
    check('marked barrel (with #2 dedup) selected', by_name['Barrel-02' .. MK .. ' #2'] ~= nil)
    check('unmarked SAM static NOT selected', by_name['SAM-1'] == nil)
    check('marked non-static (plane) NOT selected', by_name['Viper' .. MK] == nil)

    local ec = by_name['Crate-01' .. MK]
    check('entry.group points at the LIVE table', ec.group == crate)
    check('entry x/y from the live static', ec.x == 10 and ec.y == 20)
    check('entry type from units[1]', ec.type == 'iso_container')
    check('entry shape_name from units[1]', ec.shape_name == 'iso_container_small')
    check('entry category from units[1]', ec.category == 'Cargos')
    check('entry rate from units[1]', ec.rate == 100)
    check('entry heading_deg from radians', math.abs(ec.heading_deg - 90) < 1e-6)
    check('entry country from the tree', ec.country == 'USA')

    local eb = by_name['Barrel-02' .. MK .. ' #2']
    check('barrel country = Russia', eb.country == 'Russia')
    check('barrel group points at live table', eb.group == barrel)

    check('rebuild replaced W.registry', ps._registry_size().size == 2)
end

do
    -- nil / missing tree → empty registry, no error.
    vh_tree = nil
    local reg = ps._rebuild_registry_from_marked()
    check('nil tree -> empty registry', type(reg) == 'table' and #reg == 0)
end

print('')
if failures == 0 then
    print('All paint_registry tests passed.')
    os.exit(0)
else
    print(failures .. ' paint_registry tests FAILED.')
    os.exit(1)
end
