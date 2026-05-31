-- Standalone test for undo.lua. Stubs prefab_ops._remove to capture the
-- objects/ids that would be removed without actually calling DCS.
-- Run via: lua test_undo.lua  (cwd: tools/me-mod/test/)

package.preload['lfs'] = function()
    return { writedir = function() return '' end, mkdir = function() return true end,
             dir = function() return function() return nil end end }
end
package.preload['dcs_sms_me.selection'] = function()
    return { snapshot = function() return { ok = true, groups = {}, statics = {}, zones = {}, drawings = {} } end }
end

package.path = '../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

-- Stub out prefab_ops._remove BEFORE undo loads. Must use the qualified
-- name so the same module instance is shared with undo.lua's require.
local removed = { group = {}, zone = {}, drawing = {} }
local prefab_ops = require('dcs_sms_me.prefab_ops')
prefab_ops._remove = {
    group   = function(obj) removed.group[#removed.group + 1] = obj; return true end,
    zone    = function(id)  removed.zone[#removed.zone + 1] = id; return true end,
    drawing = function(obj) removed.drawing[#removed.drawing + 1] = obj; return true end,
}

local undo = require('undo')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1
    end
end

-- has_record() false initially.
check('has_record() initial false', undo.has_record() == false)

-- After record(), undo() removes everything in the record.
do
    local g1 = { __id = 101 }
    local g2 = { __id = 102 }
    local d1 = { __id = 901 }
    undo.record({
        prefab_name = 'farp_alpha',
        groups   = {
            { orig_name = 'G1', runtime_id = 101, group_obj = g1 },
            { orig_name = 'G2', runtime_id = 102, group_obj = g2 },
        },
        zones    = { { orig_name = 'Z1', runtime_id = 301 } },
        drawings = { { orig_name = 'D1', drawing_obj = d1 } },
        errors   = {},
    })
    check('has_record() after record', undo.has_record() == true)

    removed = { group = {}, zone = {}, drawing = {} }
    prefab_ops._remove.group   = function(obj) removed.group[#removed.group + 1] = obj; return true end
    prefab_ops._remove.zone    = function(id)  removed.zone[#removed.zone + 1] = id; return true end
    prefab_ops._remove.drawing = function(obj) removed.drawing[#removed.drawing + 1] = obj; return true end

    local ok, err = undo.undo()
    check('undo returns ok', ok == true, 'got ' .. tostring(ok) .. ', err=' .. tostring(err))
    check('removed 2 groups by obj',
          #removed.group == 2 and removed.group[1] == g1 and removed.group[2] == g2)
    check('removed 1 zone by id',
          #removed.zone == 1 and removed.zone[1] == 301)
    check('removed 1 drawing by obj',
          #removed.drawing == 1 and removed.drawing[1] == d1)
    check('has_record() false after undo', undo.has_record() == false)
end

-- undo() on empty slot returns nil + 'nothing to undo'.
do
    local ok, err = undo.undo()
    check('undo on empty slot returns nil', ok == nil)
    check('undo on empty slot returns reason', type(err) == 'string' and err:find('nothing') ~= nil)
end

-- record() replaces the slot (no stack).
do
    local g_a = { __id = 1 }
    local g_b = { __id = 2 }
    undo.record({ prefab_name = 'a', groups = { { orig_name = 'X', runtime_id = 1, group_obj = g_a } }, zones = {}, drawings = {}, errors = {} })
    undo.record({ prefab_name = 'b', groups = { { orig_name = 'Y', runtime_id = 2, group_obj = g_b } }, zones = {}, drawings = {}, errors = {} })

    removed = { group = {}, zone = {}, drawing = {} }
    prefab_ops._remove.group = function(obj) removed.group[#removed.group + 1] = obj; return true end

    undo.undo()
    check('second record overwrites first', #removed.group == 1 and removed.group[1] == g_b)
end

-- Per-entity remove failure: undo continues, slot still cleared.
do
    local g1 = { __id = 11 }
    local g2 = { __id = 12 }
    undo.record({
        prefab_name = 'c',
        groups   = {
            { orig_name = 'G1', runtime_id = 11, group_obj = g1 },
            { orig_name = 'G2', runtime_id = 12, group_obj = g2 },
        },
        zones = {}, drawings = {}, errors = {},
    })
    local calls = 0
    prefab_ops._remove.group = function(obj)
        calls = calls + 1
        if calls == 1 then return false, 'simulated failure' end
        return true
    end
    local ok = undo.undo()
    check('undo with one per-entity failure still returns ok', ok == true)
    check('all entities attempted', calls == 2)
    check('slot cleared after partial-failure undo', undo.has_record() == false)
end

-- ---------------------------------------------------------------------------
-- Airbase-snapshot undo path (rolls back warehouse_ops.apply splices).
-- ---------------------------------------------------------------------------

local warehouse_ops = require('dcs_sms_me.warehouse_ops')

-- add_airbase_snapshots augments the existing slot; undo() restores each
-- pre-write entry by calling warehouse_ops.apply.
do
    local restore_calls = {}
    warehouse_ops.apply = function(n, w)
        restore_calls[#restore_calls + 1] = { n = n, w = w }
        return true
    end
    -- prefab_ops._remove must be reset because earlier tests left a stub that
    -- counts calls; we don't care about per-entity removes here.
    prefab_ops._remove.group   = function() return true end
    prefab_ops._remove.zone    = function() return true end
    prefab_ops._remove.drawing = function() return true end

    local prev_68 = { unlimitedFuel = false, jet_fuel = { InitFuel = 33 } }
    local prev_12 = { unlimitedFuel = true }

    undo.record({ prefab_name = 'air', groups = {}, zones = {}, drawings = {}, errors = {} })
    undo.add_airbase_snapshots({
        { airdrome_number = 68, prev = prev_68 },
        { airdrome_number = 12, prev = prev_12 },
    })
    check('has_record() true after add_airbase_snapshots', undo.has_record() == true)

    local ok = undo.undo()
    check('undo with airbase snapshots returns ok', ok == true)
    check('restore called twice', #restore_calls == 2,
          'got ' .. tostring(#restore_calls))
    check('first restore: airdrome 68 with pre-write data',
          restore_calls[1].n == 68 and restore_calls[1].w == prev_68,
          'got n=' .. tostring(restore_calls[1].n))
    check('second restore: airdrome 12',
          restore_calls[2].n == 12 and restore_calls[2].w == prev_12)
    check('slot cleared after airbase undo', undo.has_record() == false)
end

-- Snapshots with prev=nil are skipped on undo (no clean DCS path to "remove
-- airport entry"; leaving the splice is the safer no-op).
do
    local restore_calls = {}
    warehouse_ops.apply = function(n, w)
        restore_calls[#restore_calls + 1] = { n = n }
        return true
    end

    undo.record({ prefab_name = 'air2', groups = {}, zones = {}, drawings = {}, errors = {} })
    undo.add_airbase_snapshots({
        { airdrome_number = 68, prev = { unlimitedFuel = false } },
        { airdrome_number = 12, prev = nil },         -- fresh-write, can't restore
        { airdrome_number = 99, prev = { unlimitedFuel = true } },
    })

    undo.undo()
    check('prev=nil snapshots skipped — only 2 of 3 restored', #restore_calls == 2,
          'got ' .. tostring(#restore_calls))
    check('skipped is the middle one',
          restore_calls[1].n == 68 and restore_calls[2].n == 99)
end

-- add_airbase_snapshots with no slot is a safe no-op.
do
    check('precondition: no slot', undo.has_record() == false)
    local ok = pcall(undo.add_airbase_snapshots, {
        { airdrome_number = 68, prev = { unlimitedFuel = false } },
    })
    check('add_airbase_snapshots without slot does not error', ok == true)
    check('still no slot after no-op call', undo.has_record() == false)
end

-- record() replacing the slot discards old airbase_snapshots too — single-slot
-- semantics apply to the airbase rollback list as well.
do
    local restore_calls = {}
    warehouse_ops.apply = function(n, w)
        restore_calls[#restore_calls + 1] = { n = n }
        return true
    end

    undo.record({ prefab_name = 'first', groups = {}, zones = {}, drawings = {}, errors = {} })
    undo.add_airbase_snapshots({ { airdrome_number = 68, prev = {} } })
    undo.record({ prefab_name = 'second', groups = {}, zones = {}, drawings = {}, errors = {} })
    undo.undo()
    check('record() replaces slot — old airbase_snapshots discarded',
          #restore_calls == 0, 'got ' .. tostring(#restore_calls))
end

-- ---------------------------------------------------------------------------
-- Generic handler-based API.
-- ---------------------------------------------------------------------------

-- register_handler + record_generic + dispatch.
do
    local captured = nil
    undo.register_handler('test_handler', function(payload)
        captured = payload
        return true
    end)
    undo.record_generic('test_handler', { foo = 'bar', n = 42 })
    check('has_record() true after record_generic', undo.has_record() == true)
    local ok = undo.undo()
    check('generic undo returns ok', ok == true)
    check('generic handler received payload',
          captured ~= nil and captured.foo == 'bar' and captured.n == 42)
    check('slot cleared after generic undo', undo.has_record() == false)
end

-- record_generic with unknown handler logs but does not crash; slot stays
-- empty so undo() returns the standard 'nothing to undo' error.
do
    undo.clear()
    local ok = pcall(undo.record_generic, 'unknown_handler', {})
    check('record_generic with unknown handler does not throw', ok == true)
    check('slot still empty after unknown handler', undo.has_record() == false)
end

-- record_generic replaces existing slot (single-slot semantics preserved).
do
    local handlerA_calls, handlerB_calls = 0, 0
    undo.register_handler('handlerA', function(p) handlerA_calls = handlerA_calls + 1; return true end)
    undo.register_handler('handlerB', function(p) handlerB_calls = handlerB_calls + 1; return true end)
    undo.record_generic('handlerA', {})
    undo.record_generic('handlerB', {})
    undo.undo()
    check('second record_generic overwrites first',
          handlerA_calls == 0 and handlerB_calls == 1)
end

-- The existing prefab path (via M.record) is preserved — still routes to
-- the prefab handler. We re-stub _remove and replay the original test
-- behaviour to confirm.
do
    removed = { group = {}, zone = {}, drawing = {} }
    prefab_ops._remove.group   = function(obj) removed.group[#removed.group + 1] = obj; return true end
    prefab_ops._remove.zone    = function(id)  removed.zone[#removed.zone + 1] = id; return true end
    prefab_ops._remove.drawing = function(obj) removed.drawing[#removed.drawing + 1] = obj; return true end

    local g = { __id = 999 }
    undo.record({
        prefab_name = 'preserved_path',
        groups   = { { orig_name = 'G', runtime_id = 999, group_obj = g } },
        zones    = {}, drawings = {}, errors = {},
    })
    undo.undo()
    check('existing M.record() still routes to prefab handler',
          #removed.group == 1 and removed.group[1] == g)
end

if failures > 0 then
    print(string.format('%d failure(s)', failures))
    os.exit(1)
end
print('All undo tests passed.')
