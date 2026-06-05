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

-- Like fake_backend but counts attach/detach calls per key, so a test can prove
-- a re-apply does NOT re-register an unchanged binding.
local function counting_backend()
    local live, attaches, detaches = {}, {}, {}
    return {
        live = live,
        attach = function(key, fn) live[key] = fn; attaches[key] = (attaches[key] or 0) + 1; return { key = key } end,
        detach = function(key, token) live[key] = nil; detaches[key] = (detaches[key] or 0) + 1 end,
        attached = function(key) return live[key] ~= nil end,
        n_attach = function(key) return attaches[key] or 0 end,
        n_detach = function(key) return detaches[key] or 0 end,
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

-- colliding overrides (corrupt config): two ids on the same key must not cross-detach.
-- Registry-earlier id (a2) wins; resetting the winner must NOT kill the key for a3.
do
    local eng, be = new_engine({ a2 = 'y', a3 = 'y' })
    eng:apply()
    -- a1 stays at 'm'; the colliding pair must yield exactly ONE owner at 'y'
    check('collision: y attached after apply', be.attached('y'))
    check('collision: total attachments are m + one y', be.count() == 2)
    -- registry order a1,a2,a3 -> a2 is the winner that owns the backend key
    check('collision: winner a2 is live owner', eng._live.a2 ~= nil)
    check('collision: loser a3 not live', eng._live.a3 == nil)
    -- reset the winner away; a3 still wants 'y', so 'y' must stay wired
    eng:reset('a2')
    check('collision: y still attached after winner reset', be.attached('y'))
end

-- empty default_key is treated as unbound (used by keyless user scripts)
do
    local be = fake_backend()
    local eng = E.new({
        actions = {
            { id='sx', label='ScriptX', category='Scripts', default_key='', ed_key=nil, script=true, invoke=function() end },
        },
        backend = be, overrides = {}, ed_conflicts = {}, normalize = norm,
    })
    eng:apply()
    check('empty default_key -> current_key nil', eng:current_key('sx') == nil)
    check('empty default_key -> not modified', eng:is_modified('sx') == false)
    check('empty default_key -> nothing attached', be.count() == 0)
    local rows = eng:rows()
    check('rows pass through script flag', rows[1].script == true)
end

-- set_actions: reconcile in place WITHOUT re-registering unchanged keys.
-- Regression: scripts_changed() used to REBUILD the engine on every save, which
-- re-attached every hotkey onto the shared toolbar window (the old engine's
-- detach tokens were thrown away) -> all hotkeys broke. set_actions + apply must
-- only touch what actually changed.
do
    local be = counting_backend()
    local builtin = { id='b1', label='B', category='C', default_key='m', ed_key=nil, invoke=function() end }
    local s1 = { id='script.1', label='S1', category='Scripts', default_key='k', ed_key=nil, script=true, invoke=function() end }
    local eng = E.new({ actions = { builtin, s1 }, backend = be, overrides = {}, ed_conflicts = {}, normalize = norm })
    eng:apply()
    check('set_actions: m attached initially', be.attached('m'))
    check('set_actions: k attached initially', be.attached('k'))
    check('set_actions: m attached exactly once', be.n_attach('m') == 1)

    -- add a second script -> only its key should be touched
    local s2 = { id='script.2', label='S2', category='Scripts', default_key='j', ed_key=nil, script=true, invoke=function() end }
    eng:set_actions({ builtin, s1, s2 })
    eng:apply()
    check('set_actions: added script j attached', be.attached('j'))
    check('set_actions: m NOT re-attached', be.n_attach('m') == 1)
    check('set_actions: k NOT re-attached', be.n_attach('k') == 1)
    check('set_actions: m never detached', be.n_detach('m') == 0)

    -- remove a script -> its key detaches, others untouched
    eng:set_actions({ builtin, s2 })
    eng:apply()
    check('set_actions: removed script k detached', not be.attached('k'))
    check('set_actions: k detached exactly once', be.n_detach('k') == 1)
    check('set_actions: m still attached once', be.attached('m') and be.n_attach('m') == 1)
    check('set_actions: j still attached', be.attached('j'))
end

-- set_actions preserves existing overrides (the override map is not discarded).
do
    local be = counting_backend()
    local builtin = { id='b1', label='B', category='C', default_key='m', ed_key=nil, invoke=function() end }
    local eng = E.new({ actions = { builtin }, backend = be, overrides = {}, ed_conflicts = {}, normalize = norm })
    eng:apply()
    eng:bind('b1', 'z')
    local s1 = { id='script.1', label='S1', category='Scripts', default_key='k', ed_key=nil, script=true, invoke=function() end }
    eng:set_actions({ builtin, s1 })
    eng:apply()
    check('set_actions preserves override: still at z', eng:current_key('b1') == 'z')
    check('set_actions preserves override: default m not attached', not be.attached('m'))
    check('set_actions preserves override: z not re-attached', be.n_attach('z') == 1)
end

-- Editing a script's CODE (same key) takes effect on the already-attached
-- binding: the live closure late-binds to the CURRENT action by id, so no
-- detach/reattach is needed and it never runs stale code.
do
    local be = fake_backend()   -- stores the actual fn in live[key]
    local ran = {}
    local s_old = { id='script.1', label='S', category='Scripts', default_key='k', ed_key=nil, script=true,
                    invoke=function() ran.which = 'old' end }
    local eng = E.new({ actions = { s_old }, backend = be, overrides = {}, ed_conflicts = {}, normalize = norm })
    eng:apply()
    local live_fn = be.live['k']
    check('code-edit: script bound at k', type(live_fn) == 'function')

    local s_new = { id='script.1', label='S', category='Scripts', default_key='k', ed_key=nil, script=true,
                    invoke=function() ran.which = 'new' end }
    eng:set_actions({ s_new })
    eng:apply()
    check('code-edit: same closure stays attached', be.live['k'] == live_fn)
    live_fn()  -- simulate the hotkey firing
    check('code-edit: live binding runs the EDITED code', ran.which == 'new')
end

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All me_hotkey_engine tests passed.')
