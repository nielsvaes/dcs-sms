-- Test for applicability.lua — pure helper, no I/O.
package.path = '../?.lua;../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

local A = require('dcs_sms_me.applicability')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

-- Case 1: no applies_to (universal) — every entity counts as applicable.
do
    local u1, u2, u3 = {}, {}, {}
    local cats = { [u1] = 'plane', [u2] = 'vehicle', [u3] = 'ship' }
    local applicable, total = A.compute(nil, { u1, u2, u3 }, cats)
    check('universal: applicable=3', applicable == 3, 'got ' .. tostring(applicable))
    check('universal: total=3', total == 3, 'got ' .. tostring(total))
end

-- Case 2: planes-only applies_to with mixed selection.
do
    local u1, u2, u3, u4 = {}, {}, {}, {}
    local cats = { [u1] = 'plane', [u2] = 'vehicle', [u3] = 'plane', [u4] = 'ship' }
    local applicable, total = A.compute({ plane = true }, { u1, u2, u3, u4 }, cats)
    check('planes-only mixed: applicable=2', applicable == 2, 'got ' .. tostring(applicable))
    check('planes-only mixed: total=4', total == 4, 'got ' .. tostring(total))
end

-- Case 3: planes+helos applies_to.
do
    local u1, u2, u3 = {}, {}, {}
    local cats = { [u1] = 'plane', [u2] = 'helicopter', [u3] = 'vehicle' }
    local applicable, total = A.compute({ plane = true, helicopter = true }, { u1, u2, u3 }, cats)
    check('planes+helos: applicable=2', applicable == 2, 'got ' .. tostring(applicable))
    check('planes+helos: total=3', total == 3, 'got ' .. tostring(total))
end

-- Case 4: empty checked set.
do
    local applicable, total = A.compute({ plane = true }, {}, {})
    check('empty: applicable=0', applicable == 0)
    check('empty: total=0', total == 0)
end

-- Case 5: missing category in map defaults to 'unknown' — not applicable.
do
    local u1 = {}
    local applicable, total = A.compute({ plane = true }, { u1 }, {})
    check('missing cat: applicable=0', applicable == 0)
    check('missing cat: total=1', total == 1)
end

-- Case 6: nil categories table — treat as empty (defensive).
do
    local u1 = {}
    local applicable, total = A.compute({ plane = true }, { u1 }, nil)
    check('nil cats: applicable=0', applicable == 0)
    check('nil cats: total=1', total == 1)
end

-- Case 7: is_applicable convenience for a single entity.
do
    local u = {}
    local cats = { [u] = 'plane' }
    check('is_applicable: yes', A.is_applicable({ plane = true }, u, cats) == true)
    check('is_applicable: no (vehicle)', A.is_applicable({ plane = true }, u, { [u] = 'vehicle' }) == false)
    check('is_applicable: universal yes', A.is_applicable(nil, u, cats) == true)
end

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All applicability tests passed.')
