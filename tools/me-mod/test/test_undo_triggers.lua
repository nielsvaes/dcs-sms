-- test_undo_triggers.lua — Ctrl+Z removes imported triggers with the
-- rest of the placement (spec §3 Undo).
local here = arg and arg[0] and arg[0]:match('^(.*[\\/])') or './'
package.path = here .. '?.lua;' .. here .. '../lua/?.lua;' .. package.path

-- Minimal me_mission mock: undo's trigger removal only needs
-- Mission.mission.trigrules.
local fake_mission = { mission = { trigrules = {} } }
package.preload['me_mission'] = function() return fake_mission end

local undo = require('dcs_sms_me.undo')

local passed, failed, errors = 0, 0, {}
local function check(cond, name)
    if cond then passed = passed + 1
    else failed = failed + 1; errors[#errors + 1] = name end
end

local t1 = { comment = 'kept' }
local t2 = { comment = 'imported A' }
local t3 = { comment = 'imported B' }
fake_mission.mission.trigrules = { t1, t2, t3 }

-- A prefab record with no groups/zones/drawings but two trigger entries.
undo.record({ groups = {}, zones = {}, drawings = {} })
undo.add_triggers({ t2, t3 })

local ok = undo.undo()
check(ok == true or ok ~= nil, 'undo dispatched')
check(#fake_mission.mission.trigrules == 1
      and fake_mission.mission.trigrules[1] == t1,
      'imported triggers removed by identity, others kept')

-- add_triggers without a recorded slot is a safe no-op
undo.add_triggers({ t1 })
check(#fake_mission.mission.trigrules == 1, 'orphan add_triggers no-op')

print(string.format('test_undo_triggers: %d passed, %d failed', passed, failed))
for _, e in ipairs(errors) do print('  FAIL ' .. e) end
os.exit(failed == 0 and 0 or 1)
