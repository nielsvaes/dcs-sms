-- Standalone test for me_hotkey_engine.lua. Pure logic with an injected fake
-- backend that records attach/detach. No dxgui, no registry — a tiny fake
-- actions list exercises the three cases: keyless, native-default, override.
package.path = '../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path
local E = require('dcs_sms_me.me_hotkey_engine')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

local function norm(k) if type(k) ~= 'string' then return nil end return k:lower() end

local function fake_backend()
    local live = {}   -- key -> token
    return {
        live = live,
        attach = function(key, fn) live[key] = fn; return { key = key } end,
        detach = function(key, token) live[key] = nil end,
        attached = function(key) return live[key] ~= nil end,
        count = function() local n = 0; for _ in pairs(live) do n = n + 1 end; return n end,
    }
end

local function fake_actions()
    return {
        { id='a1', label='A1', category='C', default_key='m', ed_key=nil, invoke=function() end }, -- keyless
        { id='a2', label='A2', category='C', default_key='a', ed_key='a', invoke=function() end }, -- native default
        { id='a3', label='A3', category='C', default_key='+', ed_key='+', invoke=function() end }, -- native default
    }
end

local function new_engine(overrides)
    local be = fake_backend()
    local eng = E.new({
        actions = fake_actions(), backend = be, overrides = overrides or {},
        ed_conflicts = { ['delete'] = 'Remove' }, normalize = norm,
    })
    return eng, be
end

-- apply: keyless attached, native-default NOT attached
do
    local eng, be = new_engine()
    eng:apply()
    check('keyless action attached on apply', be.attached('m'))
    check('native-default action a NOT attached', not be.attached('a'))
    check('native-default action + NOT attached', not be.attached('+'))
    check('only one attachment after apply', be.count() == 1)
end

-- is_modified / current_key / default_key
do
    local eng = new_engine()
    check('current_key defaults to default_key', eng:current_key('a2') == 'a')
    check('is_modified false at default', eng:is_modified('a2') == false)
end

-- override a native action: now attached at new key, modified true
do
    local eng, be = new_engine()
    eng:apply()
    eng:bind('a2', 'z')
    check('override native: new key attached', be.attached('z'))
    check('override native: ED key not attached', not be.attached('a'))
    check('override native: modified true', eng:is_modified('a2') == true)
    check('override native: current_key is z', eng:current_key('a2') == 'z')
end

-- reset restores default and detaches the override
do
    local eng, be = new_engine()
    eng:apply()
    eng:bind('a2', 'z')
    eng:reset('a2')
    check('reset: override key detached', not be.attached('z'))
    check('reset: modified false again', eng:is_modified('a2') == false)
end

-- bind to a key held by another managed action: moves it (prior holder unbound)
do
    local eng, be = new_engine()
    eng:apply()                 -- a1 at 'm'
    local r = eng:bind('a3', 'm')  -- take 'm' from a1
    check('move: new owner attached at m', be.attached('m'))
    check('move: prior holder a1 unbound', eng:current_key('a1') == nil)
    check('move: a1 now modified', eng:is_modified('a1') == true)
    check('move: displaced reported', r and r.displaced and r.displaced.id == 'a1')
end

-- bind to an ED-owned key reports the conflict label
do
    local eng = new_engine()
    local r = eng:bind('a1', 'delete')
    check('ed-conflict reported on bind', r and r.displaced and r.displaced.ed == 'Remove')
end

-- bind back to default clears the override (no delta)
do
    local eng = new_engine()
    eng:bind('a1', 'q')
    eng:bind('a1', 'm')   -- m is a1's default
    check('rebind to default clears override', eng:is_modified('a1') == false)
    check('overrides_delta empty after rebind-to-default', next(eng:overrides_delta()) == nil)
end

-- rows() reflects state in registry order
do
    local eng = new_engine()
    local rows = eng:rows()
    check('rows has one entry per action', #rows == 3)
    check('rows[1] is a1 with current m', rows[1].id == 'a1' and rows[1].current_key == 'm')
end

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All me_hotkey_engine tests passed.')
