-- Standalone test for mass_edit_registry.lua. Structural validation only —
-- every entry has the required keys, operations exist in transforms,
-- applies_to values are valid, no duplicate ids.

package.path = '../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

-- The registry uses `weapons_db` lazily inside some writers. Tests don't
-- exercise writers so we don't need to stub it; just guard against the
-- live ME globals.
package.preload['me_mission']    = function() return {} end
package.preload['me_loadoututils'] = function() return {} end

local registry  = require('dcs_sms_me.mass_edit_registry')
local transforms = require('dcs_sms_me.mass_edit_transforms')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

local VALID_SCOPES   = { group = true, unit = true, waypoint = true, zone = true, drawing = true }
local VALID_CATEGORIES = { plane = true, helicopter = true, vehicle = true, ship = true, static = true, ['*'] = true }
local VALID_CONTROLS = { string = true, number = true, enum = true, color = true, toggle = true }

-- Every entry has the required keys.
for i, e in ipairs(registry) do
    local tag = 'entry #' .. i .. ' ' .. tostring(e.id or '?')
    check(tag .. ': has id (string)',         type(e.id) == 'string' and e.id ~= '')
    check(tag .. ': has scope (valid)',       VALID_SCOPES[e.scope] == true)
    check(tag .. ': has label (string)',      type(e.label) == 'string' and e.label ~= '')
    check(tag .. ': has category (string)',   type(e.category) == 'string')
    check(tag .. ': has control.kind',
          type(e.control) == 'table' and VALID_CONTROLS[e.control.kind] == true)
    check(tag .. ': has operations (array)',
          type(e.operations) == 'table' and #e.operations > 0)
    check(tag .. ': has applies_to (array)',
          type(e.applies_to) == 'table' and #e.applies_to > 0)
    check(tag .. ': has reader (function)',   type(e.reader) == 'function')
    check(tag .. ': has writer (function)',   type(e.writer) == 'function')
    if e.preflight ~= nil then
        check(tag .. ': preflight is function', type(e.preflight) == 'function')
    end
    for _, op in ipairs(e.operations) do
        check(tag .. ': operation ' .. op .. ' exists in transforms',
              type(transforms[op]) == 'function')
    end
    for _, cat in ipairs(e.applies_to) do
        check(tag .. ': applies_to ' .. cat .. ' is valid',
              VALID_CATEGORIES[cat] == true)
    end
end

-- No duplicate ids.
do
    local seen = {}
    local duped = false
    for _, e in ipairs(registry) do
        if seen[e.id] then duped = true; break end
        seen[e.id] = true
    end
    check('no duplicate ids', not duped)
end

-- v1 seed list expected count: 21 entries.
check('v1 seed list has 21 entries', #registry == 21,
      'got ' .. tostring(#registry))

-- All five scopes are represented.
do
    local scopes_seen = {}
    for _, e in ipairs(registry) do scopes_seen[e.scope] = true end
    for s, _ in pairs(VALID_SCOPES) do
        check('scope present: ' .. s, scopes_seen[s] == true)
    end
end

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All mass_edit_registry structural tests passed.')
