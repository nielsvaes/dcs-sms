-- Standalone test for mass_edit_map_sync (pure compute functions).
-- No DCS stubs needed; the module is pure logic.
-- Run via: lua test_mass_edit_map_sync.lua  (cwd: tools/me-mod/test/)

package.path = '../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path
local sync = require('dcs_sms_me.mass_edit_map_sync')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

-- Helper: build a fake W with the fields compute_fetch reads.
local function make_W(pool)
    return {
        scope = 'group',
        pool = pool,
        checked = { group = {} },
        anchor  = { group = nil },
    }
end

-- ---------------------------------------------------------------------------
-- compute_fetch
-- ---------------------------------------------------------------------------

-- Case 1: snap.ok == false -> error result, W untouched.
do
    local g1 = { groupId = 1 }
    local W = make_W({ g1 })
    W.checked.group[g1] = true  -- pre-existing check
    W.anchor.group = g1

    local snap = { ok = false, error = 'simulated' }
    local r = sync.compute_fetch(W, snap)

    check('fetch err: ok=false',                  r.ok == false)
    check('fetch err: toast mentions error',      r.toast and r.toast:find('simulated', 1, true) ~= nil)
    check('fetch err: sev=err',                   r.sev == 'err')
    check('fetch err: W.checked untouched',       W.checked.group[g1] == true)
    check('fetch err: W.anchor untouched',        W.anchor.group == g1)
end

-- Case 2: snap.ok=true but groups empty -> warn toast, W unchanged.
do
    local g1 = { groupId = 1 }
    local W = make_W({ g1 })
    W.checked.group[g1] = true
    W.anchor.group = g1

    local snap = { ok = true, groups = {} }
    local r = sync.compute_fetch(W, snap)

    check('fetch empty: ok=true',                 r.ok == true)
    check('fetch empty: empty=true',              r.empty == true)
    check('fetch empty: toast = Map selection empty', r.toast == 'Map selection empty')
    check('fetch empty: sev=warn',                r.sev == 'warn')
    check('fetch empty: W.checked untouched (no wipe on empty)',
          W.checked.group[g1] == true,
          'must not clear user selection on empty map')
    check('fetch empty: W.anchor untouched',      W.anchor.group == g1)
end

-- Case 3: snap groups all in pool -> replace, anchor cleared, count toast.
do
    local g1 = { groupId = 1 }
    local g2 = { groupId = 2 }
    local g3 = { groupId = 3 }
    local W = make_W({ g1, g2, g3 })
    -- Pre-existing: only g3 checked; will be replaced by {g1, g2}.
    W.checked.group[g3] = true
    W.anchor.group = g3

    local snap = { ok = true, groups = { g1, g2 } }
    local r = sync.compute_fetch(W, snap)

    check('fetch all-hit: ok=true',               r.ok == true)
    check('fetch all-hit: count=2',               r.count == 2)
    check('fetch all-hit: missed=0',              (r.missed or 0) == 0)
    check('fetch all-hit: g1 checked',            W.checked.group[g1] == true)
    check('fetch all-hit: g2 checked',            W.checked.group[g2] == true)
    check('fetch all-hit: g3 unchecked (replaced)',
          W.checked.group[g3] == nil)
    check('fetch all-hit: anchor cleared',        W.anchor.group == nil)
    check('fetch all-hit: toast = "Fetched 2 groups from map"',
          r.toast == 'Fetched 2 groups from map')
    check('fetch all-hit: sev=info',              r.sev == 'info')
end

-- Case 4: snap groups partially out-of-pool -> partial check + warn toast.
do
    local g1 = { groupId = 1 }
    local g2 = { groupId = 2 }
    local g_orphan = { groupId = 99 }
    local W = make_W({ g1, g2 })  -- pool: g1, g2 (g_orphan not in pool)

    local snap = { ok = true, groups = { g1, g_orphan } }
    local r = sync.compute_fetch(W, snap)

    check('fetch partial: ok=true',               r.ok == true)
    check('fetch partial: count=1',               r.count == 1)
    check('fetch partial: missed=1',              r.missed == 1)
    check('fetch partial: g1 checked',            W.checked.group[g1] == true)
    check('fetch partial: g2 unchecked',          W.checked.group[g2] == nil)
    check('fetch partial: orphan not checked',    W.checked.group[g_orphan] == nil)
    check('fetch partial: anchor cleared',        W.anchor.group == nil)
    check('fetch partial: toast mentions both numbers',
          r.toast == 'Fetched 1; 1 map groups not in current pool',
          'got: ' .. tostring(r.toast))
    check('fetch partial: sev=warn',              r.sev == 'warn')
end

-- ---------------------------------------------------------------------------
-- compute_fetch with scope='static' — identical mechanism, but the static
-- check-bucket (statics are single-unit groups; the marquee returns them as
-- groups, exactly like the group scope).
-- ---------------------------------------------------------------------------

local function make_W_static(pool)
    return {
        scope = 'static',
        pool = pool,
        checked = { static = {} },
        anchor  = { static = nil },
    }
end

-- Default scope is still 'group' (backward compat: existing callers pass no scope).
do
    local g1 = { groupId = 1 }
    local W = make_W({ g1 })
    local r = sync.compute_fetch(W, { ok = true, groups = { g1 } })  -- no scope arg
    check('default scope: writes group bucket',   W.checked.group[g1] == true)
    check('default scope: groups toast',          r.toast == 'Fetched 1 groups from map')
end

-- Static all-hit: writes W.checked.static, statics toast, group bucket untouched.
do
    local s1 = { groupId = 1 }
    local s2 = { groupId = 2 }
    local W = make_W_static({ s1, s2 })
    W.checked.static[s2] = true  -- some stale prior check; replaced wholesale
    W.anchor.static = s2
    local snap = { ok = true, groups = { s1, s2 } }
    local r = sync.compute_fetch(W, snap, 'static')

    check('static fetch: ok=true',                r.ok == true)
    check('static fetch: count=2',                r.count == 2)
    check('static fetch: s1 checked in static bucket', W.checked.static[s1] == true)
    check('static fetch: s2 checked in static bucket', W.checked.static[s2] == true)
    check('static fetch: anchor.static cleared',  W.anchor.static == nil)
    check('static fetch: toast = "Fetched 2 statics from map"',
          r.toast == 'Fetched 2 statics from map', 'got: ' .. tostring(r.toast))
    check('static fetch: sev=info',               r.sev == 'info')
    check('static fetch: group bucket untouched',  W.checked.group == nil)
end

-- Static empty: must not wipe existing static checks (mirror of group empty).
do
    local s1 = { groupId = 1 }
    local W = make_W_static({ s1 })
    W.checked.static[s1] = true
    W.anchor.static = s1
    local r = sync.compute_fetch(W, { ok = true, groups = {} }, 'static')
    check('static empty: empty=true',             r.empty == true)
    check('static empty: check preserved (no wipe)', W.checked.static[s1] == true)
    check('static empty: anchor preserved',       W.anchor.static == s1)
end

-- Static partial: a non-static (out-of-pool) selection counts as missed.
do
    local s1 = { groupId = 1 }
    local orphan = { groupId = 99 }
    local W = make_W_static({ s1 })
    local r = sync.compute_fetch(W, { ok = true, groups = { s1, orphan } }, 'static')
    check('static partial: count=1',              r.count == 1)
    check('static partial: missed=1',             r.missed == 1)
    check('static partial: s1 checked',           W.checked.static[s1] == true)
    check('static partial: orphan not checked',   W.checked.static[orphan] == nil)
    check('static partial: sev=warn',             r.sev == 'warn')
end

if failures > 0 then
    print(string.format('%d failure(s)', failures))
    os.exit(1)
end
print('All mass_edit_map_sync tests passed.')
