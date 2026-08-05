-- Standalone round-trip test for the airbase-supplies plumbing through
-- distill / save / load / scan_dir.
-- Run via: lua test_prefab_ops_airbases.lua  (cwd: tools/me-mod/test/)

local fake_writedir = 'C:\\fake-saved-games\\'
package.preload['lfs'] = function()
    return {
        writedir = function() return fake_writedir end,
        mkdir = function() return true end,
        attributes = function() return { mode = 'file' } end,
        dir = function() local i = 0; return function() i = i + 1; return nil end end,
    }
end

-- Capture writes.
local captured = { path = nil, content = nil }
local real_open = io.open
io.open = function(path, mode)
    if mode == 'w' then
        return {
            write = function(_, c) captured.path = path; captured.content = c end,
            close = function() end,
        }
    end
    return real_open(path, mode)
end

package.preload['Mission.TheatreOfWarData'] = function()
    return { getName = function() return 'Syria' end }
end

-- Selection stub matching the existing save tests.
package.preload['dcs_sms_me.selection'] = function()
    return {
        snapshot = function()
            return {
                ok = true, timestamp_utc = '2026-05-05T12:00:00Z', selection_mode = 'multi',
                groups = {
                    { name='G1', x=100, y=200,
                      units={ { name='U1', type='F-16C_50', x=100, y=200, heading=0 } },
                      boss = { id=2, name='USA' } },
                },
                statics = {}, zones = {}, drawings = {}, nav_points = {}, raw = {},
            }
        end,
    }
end

package.path = '../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path
local prefab_ops = require('prefab_ops')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1
    end
end

-- Case: round-trip via load() — saved file is loadable and meta.airbases is intact.
do
    captured.path, captured.content = nil, nil
    local airbases = {
        {
            name                    = 'Muwaffaq Salti',
            airdrome_number_at_save = 68,
            warehouse = {
                coalition = 'BLUE',
                unlimitedFuel = false,
                jet_fuel  = { InitFuel = 50 },
                aircrafts = { helicopters = { ["AH-64D"] = { initialAmount = 100 } }, planes = {} },
            },
        },
        {
            name                    = 'Khalde',
            airdrome_number_at_save = 12,
            warehouse = { coalition = 'NEUTRAL', jet_fuel = { InitFuel = 80 } },
        },
    }
    local ok, _ = prefab_ops.save_selection('two_bases', false, airbases)
    check('save returns ok', ok == true)

    -- Eval the captured serialized content.
    local fn, err = loadstring(captured.content)
    check('captured content loads', fn ~= nil, tostring(err))
    local prefab = fn and fn()
    check('prefab table returned', type(prefab) == 'table' and prefab.meta ~= nil)
    check('prefab.meta.sms_prefab_version == 0.7.0', prefab.meta.sms_prefab_version == '0.7.0',
          'got ' .. tostring(prefab and prefab.meta and prefab.meta.sms_prefab_version))
    check('prefab.meta.airbases has 2 entries',
          type(prefab.meta.airbases) == 'table' and #prefab.meta.airbases == 2,
          'got ' .. tostring(prefab.meta.airbases and #prefab.meta.airbases))
    check('first airbase name preserved', prefab.meta.airbases[1].name == 'Muwaffaq Salti')
    check('first airbase coalition preserved', prefab.meta.airbases[1].warehouse.coalition == 'BLUE')
    check('first airbase nested AH-64D preserved',
          prefab.meta.airbases[1].warehouse.aircrafts
          and prefab.meta.airbases[1].warehouse.aircrafts.helicopters
          and prefab.meta.airbases[1].warehouse.aircrafts.helicopters['AH-64D']
          and prefab.meta.airbases[1].warehouse.aircrafts.helicopters['AH-64D'].initialAmount == 100)
    check('second airbase preserved', prefab.meta.airbases[2].name == 'Khalde')
end

-- Case: save without airbases omits meta.airbases entirely (no churn for non-airbase prefabs).
do
    captured.path, captured.content = nil, nil
    local ok = prefab_ops.save_selection('no_bases')
    check('save without airbases returns ok', ok == true)
    check('content does not contain "airbases"',
          captured.content and not captured.content:find('airbases', 1, true),
          'unexpected airbases field')
end

-- Case: load() reads an airbases-bearing prefab from disk.
do
    -- os.tmpname() on the Windows LuaBinaries build returns paths rooted at
    -- '\' (e.g. '\s5vg.'), which resolve to C:\ — not writable for normal
    -- users. Prepend %TEMP% when the path looks root-relative so the test
    -- runs on those interpreters without requiring admin rights.
    local tmppath = os.tmpname()
    if tmppath:sub(1, 1) == '\\' or tmppath:sub(1, 1) == '/' then
        tmppath = (os.getenv('TEMP') or os.getenv('TMP') or '.') .. tmppath
    end
    local f = real_open(tmppath, 'w')
    f:write([[return {
  meta = {
    sms_prefab_version = "0.3.0",
    name = "abtest",
    theatre = "Syria",
    world_anchor = { x = 0, y = 0 },
    airbases = {
      { name = "Muwaffaq Salti", airdrome_number_at_save = 68, warehouse = { coalition = "BLUE" } },
      { name = "Khalde",         airdrome_number_at_save = 12, warehouse = { coalition = "NEUTRAL" } },
    },
  },
  groups = {}, statics = {}, zones = {}, drawings = {},
}]])
    f:close()

    local p = prefab_ops.load(tmppath)
    check('load() reads airbases-bearing prefab', p ~= nil and p.meta ~= nil)
    check('loaded prefab.meta.airbases has 2 entries',
          type(p.meta.airbases) == 'table' and #p.meta.airbases == 2,
          'got ' .. tostring(p.meta.airbases and #p.meta.airbases))
    os.remove(tmppath)
end

-- ---------------------------------------------------------------------------
-- apply_airbases tests — exercise the apply pipeline with stubbed controllers.
-- ---------------------------------------------------------------------------

-- Airdrome list: name → airdromeNumber. Only airdromes present in the live
-- mission can be applied to.
local airdromes_in_mission = {
    { name = 'Muwaffaq Salti', n = 68 },
    { name = 'Khalde',         n = 12 },
    -- 'H4' deliberately absent so we test the not-found branch.
}
local function rebuild_airdromes()
    local out = {}
    for _, e in ipairs(airdromes_in_mission) do
        out[#out + 1] = {
            x = 0, y = 0,
            getName             = function(self) return e.name end,
            getAirdromeNumber   = function(self) return e.n end,
        }
    end
    return out
end

-- Capture warehouse_ops.apply calls.
local apply_calls = {}
package.loaded['Mission.AirdromeController'] = {
    getAirdromes        = function() return rebuild_airdromes() end,
    getAirdromeId       = function(n) return 'id-' .. tostring(n) end,
    setAirdromeCoalition= function() end,
}
package.loaded['Mission.CoalitionController'] = {
    redCoalitionName = function() return 'red' end,
    blueCoalitionName = function() return 'blue' end,
    neutralCoalitionName = function() return 'neutral' end,
}

-- Stub me_mission.mission.AirportsEquipment so warehouse_ops.apply has somewhere to write.
local live_airports = { [12] = {}, [68] = {} }
package.preload['me_mission'] = function()
    return { mission = { AirportsEquipment = { airports = live_airports } } }
end
package.loaded['me_mission'] = nil  -- force a re-require so the new stub is picked up
package.loaded['dcs_sms_me.warehouse_ops'] = nil
package.loaded['prefab_ops'] = nil
prefab_ops = require('prefab_ops')

-- Patch warehouse_ops.apply to capture calls AFTER prefab_ops has require'd it.
local warehouse_ops_real = require('dcs_sms_me.warehouse_ops')
warehouse_ops_real.apply = function(n, w)
    apply_calls[#apply_calls + 1] = { n = n, w = w }
    live_airports[n] = w  -- emulate splice for downstream assertions
    return true
end

-- Case: apply_airbases applies all named airdromes that are present.
do
    apply_calls = {}
    local prefab = {
        meta = {
            theatre  = 'Syria',
            airbases = {
                { name = 'Muwaffaq Salti', airdrome_number_at_save = 68,
                  warehouse = { coalition = 'BLUE', jet_fuel = { InitFuel = 50 } } },
                { name = 'Khalde',         airdrome_number_at_save = 12,
                  warehouse = { coalition = 'NEUTRAL' } },
            },
        }
    }
    local ok, summary = prefab_ops.apply_airbases(prefab, { current_theatre = 'Syria' })
    check('apply_airbases returns ok', ok == true, 'summary err: ' .. tostring(summary and summary.error))
    check('apply called twice', #apply_calls == 2, 'got ' .. #apply_calls)
    check('summary applied count == 2',
          summary and summary.applied == 2, 'got ' .. tostring(summary and summary.applied))
    check('summary skipped count == 0',
          summary and summary.skipped == 0, 'got ' .. tostring(summary and summary.skipped))
end

-- Case: apply_airbases skips airdromes not present in destination.
do
    apply_calls = {}
    local prefab = {
        meta = {
            theatre  = 'Syria',
            airbases = {
                { name = 'Muwaffaq Salti', airdrome_number_at_save = 68,
                  warehouse = { coalition = 'BLUE' } },
                { name = 'H4', airdrome_number_at_save = 80,   -- not in airdromes_in_mission
                  warehouse = { coalition = 'BLUE' } },
            },
        }
    }
    local ok, summary = prefab_ops.apply_airbases(prefab, { current_theatre = 'Syria' })
    check('apply_airbases returns ok with partial application', ok == true)
    check('apply called once (only the present airdrome)', #apply_calls == 1)
    check('summary applied == 1', summary.applied == 1)
    check('summary skipped == 1', summary.skipped == 1)
    check('summary missing list mentions H4',
          type(summary.missing) == 'table' and summary.missing[1] == 'H4',
          'got ' .. tostring(summary.missing and summary.missing[1]))
end

-- Case: theatre mismatch refuses the whole apply step.
do
    apply_calls = {}
    local prefab = {
        meta = {
            theatre  = 'Syria',
            airbases = {
                { name = 'Muwaffaq Salti', warehouse = { coalition = 'BLUE' } },
            },
        }
    }
    local ok, summary = prefab_ops.apply_airbases(prefab, { current_theatre = 'Caucasus' })
    check('apply_airbases refused on theatre mismatch', ok == nil)
    check('no apply calls fired', #apply_calls == 0)
    check('summary indicates theatre mismatch',
          type(summary) == 'table' and summary.error and summary.error:find('theatre', 1, true) ~= nil)
end

-- Case: prefab carrying airbases but no meta.theatre is refused (we can't
-- verify the destination map is the right one). Older 0.2.0 saves predate
-- theatre capture; if airbases were retroactively attached, blindly applying
-- them to a different map would be the cross-theatre catastrophe.
do
    apply_calls = {}
    local prefab = {
        meta = {
            -- theatre deliberately absent
            airbases = {
                { name = 'Muwaffaq Salti', warehouse = { coalition = 'BLUE' } },
            },
        }
    }
    local ok, summary = prefab_ops.apply_airbases(prefab, { current_theatre = 'Syria' })
    check('apply_airbases refused on missing prefab.meta.theatre', ok == nil)
    check('no apply calls fired (missing-theatre)', #apply_calls == 0)
    check('summary error mentions theatre',
          type(summary) == 'table' and summary.error and summary.error:find('theatre', 1, true) ~= nil,
          'got: ' .. tostring(summary and summary.error))
end

-- Case: empty meta.theatre is treated the same as nil — refuse.
do
    apply_calls = {}
    local prefab = {
        meta = {
            theatre  = '',
            airbases = {
                { name = 'Muwaffaq Salti', warehouse = { coalition = 'BLUE' } },
            },
        }
    }
    local ok, summary = prefab_ops.apply_airbases(prefab, { current_theatre = 'Syria' })
    check('apply_airbases refused on empty prefab.meta.theatre', ok == nil)
    check('no apply calls fired (empty-theatre)', #apply_calls == 0)
end

-- Case: prefab without meta.airbases is a no-op (returns ok with applied=0).
do
    apply_calls = {}
    local prefab = { meta = { theatre = 'Syria' } }
    local ok, summary = prefab_ops.apply_airbases(prefab, { current_theatre = 'Syria' })
    check('apply_airbases no-op returns ok', ok == true)
    check('no apply calls', #apply_calls == 0)
    check('summary applied == 0', summary.applied == 0)
end

-- Case: summary.snapshots captures pre-write live state for each successfully
-- applied airbase. Consumed by undo.lua to roll back the splice.
do
    apply_calls = {}
    local prev_68 = { unlimitedFuel = false, jet_fuel = { InitFuel = 33 }, coalition = 'BLUE' }
    local prev_12 = { unlimitedFuel = true, coalition = 'NEUTRAL' }
    live_airports[68] = prev_68
    live_airports[12] = prev_12

    local prefab = {
        meta = {
            theatre  = 'Syria',
            airbases = {
                { name = 'Muwaffaq Salti', airdrome_number_at_save = 68,
                  warehouse = { coalition = 'BLUE', jet_fuel = { InitFuel = 99 } } },
                { name = 'Khalde', airdrome_number_at_save = 12,
                  warehouse = { coalition = 'NEUTRAL' } },
            },
        }
    }
    local ok, summary = prefab_ops.apply_airbases(prefab, { current_theatre = 'Syria' })
    check('summary.snapshots is a table', type(summary.snapshots) == 'table')
    check('summary.snapshots has 2 entries',
          type(summary.snapshots) == 'table' and #summary.snapshots == 2,
          'got ' .. tostring(summary.snapshots and #summary.snapshots))
    check('first snapshot.airdrome_number == 68',
          summary.snapshots[1] and summary.snapshots[1].airdrome_number == 68)
    check('first snapshot.prev captures pre-write InitFuel=33',
          summary.snapshots[1] and summary.snapshots[1].prev
          and summary.snapshots[1].prev.jet_fuel
          and summary.snapshots[1].prev.jet_fuel.InitFuel == 33,
          'got ' .. tostring(summary.snapshots[1] and summary.snapshots[1].prev
                             and summary.snapshots[1].prev.jet_fuel
                             and summary.snapshots[1].prev.jet_fuel.InitFuel))
    check('first snapshot.prev is a deep copy (not aliased to live)',
          summary.snapshots[1].prev ~= prev_68
          and summary.snapshots[1].prev.jet_fuel ~= prev_68.jet_fuel)
    check('second snapshot.airdrome_number == 12',
          summary.snapshots[2] and summary.snapshots[2].airdrome_number == 12)
end

-- Case: airbases that fail name resolution don't get a snapshot — only
-- successfully-applied entries do. Undo should only roll back what was written.
do
    apply_calls = {}
    live_airports[68] = { unlimitedFuel = false }

    local prefab = {
        meta = {
            theatre  = 'Syria',
            airbases = {
                { name = 'Muwaffaq Salti', airdrome_number_at_save = 68,
                  warehouse = { coalition = 'BLUE' } },
                { name = 'H4', airdrome_number_at_save = 80,    -- absent from destination
                  warehouse = { coalition = 'BLUE' } },
            },
        }
    }
    local _, summary = prefab_ops.apply_airbases(prefab, { current_theatre = 'Syria' })
    check('snapshots length matches applied count',
          type(summary.snapshots) == 'table' and #summary.snapshots == summary.applied
          and summary.applied == 1,
          'snapshots=' .. tostring(#(summary.snapshots or {})) .. ' applied=' .. tostring(summary.applied))
    check('the one snapshot is for the resolved airdrome (68)',
          summary.snapshots[1] and summary.snapshots[1].airdrome_number == 68)
end

-- Case: opts.override_coalition replaces the saved coalition on every applied
-- airbase. The saved warehouse table itself must NOT be mutated — apply
-- builds a wrapper for the override so subsequent calls still see the
-- original.
do
    apply_calls = {}
    local saved_warehouse = { coalition = 'BLUE', jet_fuel = { InitFuel = 50 } }
    local prefab = {
        meta = {
            theatre  = 'Syria',
            airbases = {
                { name = 'Muwaffaq Salti', airdrome_number_at_save = 68,
                  warehouse = saved_warehouse },
                { name = 'Khalde', airdrome_number_at_save = 12,
                  warehouse = { coalition = 'NEUTRAL' } },
            },
        }
    }
    local ok, summary = prefab_ops.apply_airbases(prefab, {
        current_theatre    = 'Syria',
        override_coalition = 'RED',
    })
    check('apply_airbases with override returns ok', ok == true)
    check('apply called twice', #apply_calls == 2)
    check('first apply received RED coalition (override)',
          apply_calls[1] and apply_calls[1].w and apply_calls[1].w.coalition == 'RED',
          'got ' .. tostring(apply_calls[1] and apply_calls[1].w and apply_calls[1].w.coalition))
    check('second apply received RED coalition (override)',
          apply_calls[2] and apply_calls[2].w and apply_calls[2].w.coalition == 'RED',
          'got ' .. tostring(apply_calls[2] and apply_calls[2].w and apply_calls[2].w.coalition))
    check('source warehouse table not mutated', saved_warehouse.coalition == 'BLUE',
          'saved coalition was: ' .. tostring(saved_warehouse.coalition))
    check('summary applied == 2', summary.applied == 2)
end

if failures > 0 then
    print(string.format('%d failure(s)', failures))
    os.exit(1)
end
print('All prefab_ops airbases tests passed.')
